// ─────────────────────────────────────────────────────────────────────────────
// 팀핑 — Bash 명령에서 **쓰기 대상 파일**을 뽑는다.
//
// Edit·Write 처럼 Bash 명령으로 파일을 바꿀 때도 그 파일을 잠글 수 있게 한다.
//
// 데이터 경계:
//   **명령 전문은 서버로 보내지 않는다.** 명령줄에는 토큰·비밀번호가 섞일 수 있다.
//   추출은 내 컴퓨터(훅 안)에서 하고, 서버로는 뽑힌 **파일 경로만** 간다.
//
// 돌려주는 값:
//   · targets — 확실히 쓰는 파일(잠근다)
//   · grey    — 커밋 전 확인(precommit-lock.sh)이 이어서 보는 명령
//   · forms   — 그렇게 판단한 근거(명령 형태)
//
// 읽기만 하는 파일은 잠그지 않는다:
//   `grep foo app/src/x.ts > out.txt` 에서 잠그는 건 `out.txt` 뿐이다.
// ─────────────────────────────────────────────────────────────────────────────

/** 쓰기가 일어날 수 있음을 알리는 형태들. 하나도 안 걸리면 네트워크도 타지 않는다. */
// git 의 쓰기 하위 명령도 포함한다.
const WRITE_FORM =
  /(^|[^>&])>>?[^&]|&>|>&\s*[^0-9]|\btee\b|\bsed\b|\bcp\b|\bmv\b|\brm\b|\bmkdir\b|\btouch\b|\bln\b|\binstall\b|\bpatch\b|\bgit\s+(checkout|restore|apply|am|reset|stash|merge|rebase|pull|revert|clean|mv|rm)\b|<<\s*['"]?[A-Za-z_]/;

/**
 * 빌드·실행 도구들(grey) — 커밋 전 확인이 이어서 본다.
 * 여기 있는 이름은 mayWrite() 도 통과한다(OPAQUE_RUN).
 */
const OPAQUE_NAMES = [
  "npm", "npx", "yarn", "pnpm", "make", "cargo", "go", "docker", "docker-compose",
  "bash", "sh", "zsh", "python", "python3", "ruby", "perl", "node", "deno", "bun",
  "gradle", "mvn", "ansible", "ansible-playbook", "terraform", "pulumi", "helm", "kubectl",
  // 대상을 인자로 받지만 형태가 제각각이라 확실히 뽑을 수 없는 것들:
  "curl", "wget", "dd", "openssl", "awk", "gawk", "xargs", "find", "rsync", "tar", "unzip", "sponge",
];
const OPAQUE = new RegExp(`^(${OPAQUE_NAMES.join("|")})$|\\.(sh|bash|zsh|py|rb|pl|mjs|cjs|js)$`);
/** 위 이름·스크립트 실행이 명령 어딘가에 있으면 사전 게이트를 통과시킨다(= 판정기까지 간다). */
const OPAQUE_RUN = new RegExp(
  `(^|[\\s;|&(])(${OPAQUE_NAMES.join("|")})(\\s|$)|(^|[\\s;|&(])\\.{0,2}[\\w./-]*\\.(sh|bash|zsh|py|rb|pl|mjs|cjs|js)\\b`,
);

/** 쓰기 대상이 아닌 곳들 — 잠글 이유가 없다. */
const NOT_A_TARGET = /^(\/dev\/(null|stdout|stderr|tty)|&[0-9]|[0-9])$/;
/** 실행 시점에 정해지는 이름 — 지금 잠그면 엉뚱한 파일을 잠근다. */
const RUNTIME_EXPANDED = /[$`*?[\]{}~]/;

/**
 * 명령을 **따옴표를 존중하며** 한 번에 훑어 구간과 토큰으로 나눈다.
 * `;` `|` `&&` 와 `$( … )` · 백틱이 구간 경계다. 따옴표 안·이스케이프된 글자는 경계가 아니다.
 */
/**
 * heredoc 본문을 걷어낸다 — 본문은 명령이 아니라 **입력 데이터**다.
 * 본문 속 `=>`·`>=` 를 출력 기호로 읽으면 코드 조각이 「파일 경로」가 되어 서버로 간다.
 *
 * ⭐ 원칙: **확실할 때만 지운다.** 셸 문법 전체를 흉내 내면 맥락을 잘못 읽는 순간 진짜 쓰기 줄을 본문으로 지워
 *    잠금이 빠진다(가짜 경로보다 나쁜 방향). 그래서 heredoc 시작까지의 글자에 맥락을 바꾸는 글자
 *    (따옴표 · 백틱 · `$` · `#` · 괄호·대괄호·중괄호 · 백슬래시)가 **하나도 없는** 단순한 모양만 heredoc 으로 본다 —
 *    그 자리면 셸도 반드시 heredoc 으로 읽고, 끝 표식 줄도 정확히 정해진다. 애매한 모양을 만나면 그 뒤로는
 *    **아무것도 지우지 않는다**(지우기 전과 똑같이 동작 — 본문이 샐 수는 있어도 덜 잠그지 않는다).
 * 예외 하나: 커밋 메시지에 늘 쓰는 `… "$(cat <<'EOF'` ⏎ 본문 ⏎ `EOF` ⏎ `)"` 모양은 그 모양 그대로일 때만 인정한다.
 * 끝 표식 줄은 앞 탭(`<<-`)·끝 \r(Windows)을 빼고 비교. 끝 표식을 못 찾으면 원문 유지 + unclosed.
 */
export function stripHeredocBodies(command) {
  return heredocScan(command).text;
}

/**
 * 한 줄을 판정한다 — 이 줄이 끝났을 때 셸이 맨 바깥(명령) 맥락으로 돌아오는 게 **확실한가**, 그리고 heredoc 을 여는가.
 * 확실한 것만 인정: 한 줄 안에서 닫히는 '…' · "…"(안에 $·백틱·백슬래시가 없을 때) · 단어 첫머리 # 주석.
 * 그 밖의 맥락 글자($ · 백틱 · 백슬래시 · 괄호·대괄호·중괄호 · 줄을 넘는 따옴표)는 애매 → null.
 * @returns {null | {hd: null | {end: string, dash: boolean}}}
 */
function analyzeLine(line) {
  const L = line.replace(/\r$/, "");
  let hd = null;
  for (let i = 0; i < L.length; i++) {
    const c = L[i];
    if (c === "'") { const e = L.indexOf("'", i + 1); if (e < 0) return null; i = e; continue; }
    if (c === '"') {
      const e = L.indexOf('"', i + 1);
      if (e < 0) return null;
      if (/[$`\\]/.test(L.slice(i + 1, e))) return null;
      i = e;
      continue;
    }
    if (c === "#" && (i === 0 || /[\s;|&]/.test(L[i - 1]))) break; // 주석 — 줄 끝까지
    if (/[$`\\(){}[\]]/.test(c)) return null;
    if (c === "<" && L[i + 1] === "<") {
      if (L[i + 2] === "<") { i += 2; continue; } // <<< 히어스트링 — heredoc 아님
      if (hd) return null; // 한 줄에 heredoc 둘 — 애매
      let k = i + 2;
      const dash = L[k] === "-";
      if (dash) k++;
      while (L[k] === " " || L[k] === "\t") k++;
      const m = /^(['"]?)([A-Za-z0-9_.\-]+)\1(?=$|[\s;|&<>])/.exec(L.slice(k));
      if (!m) return null;
      hd = { end: m[2], dash };
      i = k + m[0].length - 1;
    }
  }
  return { hd };
}

// 커밋 메시지 모양 — `… -m "$(cat <<'EOF'` (앞부분은 analyzeLine 이 확실하다고 본 것만)
const HD_COMMIT = /^(?<pre>.*?)"\$\(cat[ \t]+<<(?<dash>-?)[ \t]*(?<q>['"]?)(?<end>[A-Za-z0-9_.\-]+)\k<q>[ \t]*\r?$/;

/** @returns {{text: string, unclosed: boolean}} */
export function heredocScan(command) {
  const lines = command.split("\n");
  const keep = [];
  let unclosed = false;
  const findEnd = (from, end, tabs) => {
    for (let k = from; k < lines.length; k++) {
      let l = lines[k].replace(/\r$/, "");
      if (tabs) l = l.replace(/^\t+/, "");
      if (l === end) return k;
    }
    return -1;
  };
  const rest = (i) => { keep.push(...lines.slice(i)); };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const c = HD_COMMIT.exec(line);
    if (c && analyzeLine(c.groups.pre)?.hd === null) {
      const g = c.groups;
      const e = findEnd(i + 1, g.end, g.dash === "-");
      const close = e < 0 ? "" : (lines[e + 1] ?? "").replace(/\r$/, "");
      const tail = close.slice(2);
      if (e < 0 || !close.startsWith(')"') || analyzeLine(tail)?.hd !== null) { if (e < 0) unclosed = true; rest(i); break; }
      keep.push(g.pre + tail); // 메시지 자리는 비운다 — 남은 꼬리(리다이렉션 등)는 그대로 본다
      i = e + 1;
      continue;
    }
    const a = analyzeLine(line);
    if (a === null) { rest(i); break; } // 애매 — 여기부터 원문 그대로(지우기 전과 똑같이)
    keep.push(line);
    if (!a.hd) continue;
    const e = findEnd(i + 1, a.hd.end, a.hd.dash);
    if (e < 0) { unclosed = true; rest(i + 1); break; } // 끝 표식을 못 찾음 — 원문 유지
    i = e; // 본문과 끝 표식 줄을 건너뛴다
  }
  return { text: keep.join("\n"), unclosed };
}

function scan(command) {
  const segments = [];
  let toks = [];
  let cur = "";
  let had = false; // 빈 따옴표('')도 토큰이다 — sed의 BSD -i '' 가 그렇다
  let quoted = false; // 이 토큰이 따옴표에서 왔나(구분자 판정에 쓰지 않기 위해)

  const pushTok = () => {
    if (had) toks.push({ v: cur, quoted });
    cur = "";
    had = false;
    quoted = false;
  };
  const pushSeg = () => {
    pushTok();
    if (toks.length) segments.push(toks);
    toks = [];
  };

  for (let i = 0; i < command.length; i++) {
    const c = command[i];
    if (c === "'" || c === '"') {
      const q = c;
      had = true;
      quoted = true;
      i++;
      for (; i < command.length && command[i] !== q; i++) {
        if (q === '"' && command[i] === "\\" && i + 1 < command.length) i++;
        cur += command[i];
      }
      continue;
    }
    if (c === "\\" && i + 1 < command.length) {
      // 이스케이프된 문자는 **글자 그대로**다 — `\;`가 구분자가 되면 find -exec가 잘린다.
      cur += command[++i];
      had = true;
      continue;
    }
    if (c === "\n" || c === ";") { pushSeg(); continue; }
    // `$( … )` · 백틱 안도 독립된 명령으로 본다.
    if (c === "`" || (c === "$" && command[i + 1] === "(")) {
      pushSeg();
      if (c === "$") i++; // `$(` 의 여는 괄호까지 건너뛴다
      continue;
    }
    if (c === ")") { pushSeg(); continue; }
    if (c === "|" || c === "&") {
      // `|` `||` `&&` 모두 구간 경계. 파이프 뒤 명령은 따로 본다(xargs가 여기서 살아난다).
      if (command[i + 1] === c) i++;
      pushSeg();
      continue;
    }
    if (/\s/.test(c)) { pushTok(); continue; }
    if (c === ">" || c === "<") {
      pushTok();
      let op = c;
      // `<<<`(히어스트링) · `<<`(히어독) · `>>`(덧붙이기)를 각각 온전히 집는다.
      while (command[i + 1] === c) { op += c; i++; }
      if (op === ">" && command[i + 1] === "|") i++; // `>|` 강제 덮어쓰기
      toks.push({ v: op, op: true });
      continue;
    }
    cur += c;
    had = true;
  }
  pushSeg();
  return segments;
}

const isFlag = (t) => t.v.startsWith("-") && !t.quoted;

/**
 * @param {string} command  Bash 도구가 실행하려는 명령 전문(훅 안에서만 다룬다)
 * @returns {{targets: string[], grey: boolean, forms: string[]}}
 */
export function extractWriteTargets(command) {
  if (typeof command !== "string" || !command) return { targets: [], grey: false, forms: [] };
  if (!mayWrite(command)) return { targets: [], grey: false, forms: [] };
  const hd = heredocScan(command); // 본문은 입력 데이터 — 명령으로 읽지 않는다
  command = hd.text;

  const targets = new Set();
  const forms = new Set();
  // 끝 표식을 못 찾은 heredoc 은 그 뒤를 본문으로 지웠다 — 놓쳤을 수 있으니 「모름」으로 넘겨 커밋 전 확인이 받게 한다
  let grey = hd.unclosed;
  if (hd.unclosed) forms.add("닫히지 않은 heredoc");

  /** 확실할 때만 잠근다. 실행 시점에 정해지는 이름이면 잠그지 말고 모름으로 넘긴다. */
  const addTarget = (raw) => {
    if (!raw || NOT_A_TARGET.test(raw)) return;
    if (RUNTIME_EXPANDED.test(raw)) { grey = true; forms.add("실행시점이름"); return; }
    // `dir/` 처럼 디렉토리로 끝나면 최종 파일 경로를 알 수 없다.
    if (raw.endsWith("/")) { grey = true; forms.add("디렉토리대상"); return; }
    if (hasCd && !raw.startsWith("/")) { grey = true; forms.add("cd로 기준이 바뀜"); return; }
    targets.add(raw);
  };

  // 명령 안에서 작업 폴더가 바뀌면 상대경로는 커밋 전 확인으로 넘긴다.
  const hasCd = /(^|[\s;|&(])cd\s/.test(command);

  for (const toks of scan(command)) {
    // ── ① 리다이렉션: `> 파일` `>> 파일` (`<`·`<<`·`<<<`는 읽기다) ──────────────
    for (let i = 0; i < toks.length; i++) {
      const t = toks[i];
      if (!t.op || (t.v !== ">" && t.v !== ">>")) continue;
      const next = toks[i + 1];
      if (!next || next.op) { grey = true; forms.add("리다이렉션(대상불명)"); continue; }
      if (NOT_A_TARGET.test(next.v)) { forms.add("리다이렉션(무해)"); continue; }
      addTarget(next.v);
      forms.add("리다이렉션");
    }

    // 명령 이름 — `VAR=값 cmd` 처럼 앞에 붙는 환경변수를 건너뛴다.
    let ci = 0;
    while (ci < toks.length && !toks[ci].op && /^[A-Za-z_][A-Za-z0-9_]*=/.test(toks[ci].v)) ci++;
    const head = toks[ci];
    if (!head || head.op) continue;
    const cmd = head.v.split("/").pop();

    // 연산자와 **그 뒤 토큰**은 인자 목록에서 뺀다.
    // `>`·`>>` 의 대상은 위에서 이미 처리했고, `<`·`<<`·`<<<` 뒤는 **입력**이지 파일 인자가 아니다.
    // 예: `tee -a out.log <<< hi` 의 `hi` 는 파일이 아니다.
    const redir = new Set();
    for (let i = 0; i < toks.length; i++) {
      if (toks[i].op && toks[i + 1]) redir.add(i + 1);
    }
    const args = toks.slice(ci + 1).filter((t, idx) => !t.op && !redir.has(ci + 1 + idx));
    const fileArgs = args.filter((t) => !isFlag(t)).map((t) => t.v);

    switch (cmd) {
      // ── ② 자리에서 고치는 것들: 파일 인자 **전부**가 대상 ────────────────────
      case "sed": {
        const inPlace = args.some((t) => /^-[a-zA-Z]*i/.test(t.v) || t.v === "--in-place");
        if (!inPlace) break; // -i 가 없으면 sed는 stdout으로만 쓴다
        forms.add("sed -i");
        // 스크립트(`s/a/b/` · `5,10p`)는 경로가 아니다. 그것만 걸러내고 **나머지는 전부** 대상이다.
        const files = fileArgs.filter((f) => f !== "" && !/^[sy]?[/;]/.test(f) && !/^\d+[,~]?\d*[a-z]/.test(f));
        if (files.length) for (const f of files) addTarget(f);
        else grey = true;
        break;
      }
      case "tee": {
        forms.add("tee");
        if (fileArgs.length) for (const f of fileArgs) addTarget(f);
        else grey = true; // stdout으로만 흘리는 tee
        break;
      }
      case "touch":
      case "mkdir": {
        forms.add(cmd);
        if (fileArgs.length) for (const f of fileArgs) addTarget(f);
        break;
      }
      case "rm": {
        forms.add("rm");
        if (fileArgs.length) for (const f of fileArgs) addTarget(f);
        break;
      }
      // ── ③ 목적지가 마지막 인자인 것들 ────────────────────────────────────────
      case "cp":
      case "ln":
      case "install": {
        forms.add(cmd);
        if (fileArgs.length >= 2) addTarget(fileArgs[fileArgs.length - 1]);
        else if (fileArgs.length) grey = true;
        break;
      }
      case "mv": {
        forms.add("mv");
        // mv 는 원본도 없앤다 — 원본과 목적지를 함께 잠근다(cp 와 다른 점).
        if (fileArgs.length >= 2) for (const f of fileArgs) addTarget(f);
        else if (fileArgs.length) grey = true;
        break;
      }
      case "patch": {
        forms.add("patch");
        const explicit = fileArgs.filter((f) => !f.endsWith(".diff") && !f.endsWith(".patch"));
        if (explicit.length) for (const f of explicit) addTarget(f);
        else grey = true; // 대상이 diff 안에 있다 — 텍스트로는 모른다
        break;
      }
      case "git": {
        const sub = fileArgs[0];
        if (!sub) break;
        if (/^(checkout|restore|reset|stash|revert|clean)$/.test(sub)) {
          forms.add(`git ${sub}`);
          const paths = fileArgs.slice(1).filter((f) => /[./]/.test(f));
          if (paths.length) for (const p of paths) addTarget(p);
          else grey = true;
        } else if (/^(merge|rebase|pull|apply|am)$/.test(sub)) {
          // 무엇이 바뀔지는 diff·상대 브랜치 안에 있다. `git apply patch.diff` 의 patch.diff 는 읽기만 한다.
          forms.add(`git ${sub}`);
          grey = true;
        } else if (/^(mv|rm)$/.test(sub)) {
          forms.add(`git ${sub}`);
          const paths = fileArgs.slice(1);
          if (paths.length) for (const p of paths) addTarget(p);
          else grey = true;
        }
        break;
      }
      default:
        // ── ④ 회색지대: 무엇을 쓸지 명령줄로는 알 수 없는 것들 ────────────────
        if (OPAQUE.test(cmd)) {
          forms.add(`불투명:${cmd}`);
          grey = true;
        }
        break;
    }
  }

  return { targets: [...targets], grey, forms: [...forms] };
}

/**
 * 빠른 사전 확인 — 쓰기 가능성이 하나도 없으면 아무 일도 하지 않는다.
 * 훅은 명령 문자열만 떼어 이 함수에 물어본다.
 */
export function mayWrite(command) {
  return typeof command === "string" && (WRITE_FORM.test(command) || OPAQUE_RUN.test(command));
}
