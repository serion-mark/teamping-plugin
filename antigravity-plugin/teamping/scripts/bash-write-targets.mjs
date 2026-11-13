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
 * ⭐ 원칙 둘(2026-11-10 개정 — 「파일 내용은 보내지 않는다」를 단서 없이 지키려고):
 *    ① **확실할 때만 heredoc 으로 본다.** heredoc 시작까지의 글자에 맥락을 바꾸는 글자
 *       (따옴표 · 백틱 · `$(`·`${` · `#` · 괄호·대괄호·중괄호 · 백슬래시)가 **하나도 없는** 단순한 모양만 —
 *       그 자리면 셸도 반드시 heredoc 으로 읽고, 끝 표식 줄도 정확히 정해진다. 단순 변수(`$HOME` · `$1`)는 맥락을 안 바꾼다.
 *    ② **애매하면 본문 자리부터 버린다.** heredoc 본문은 `<<` 가 있는 줄 **다음** 줄부터만 시작할 수 있다. 그래서 애매한 줄을
 *       만나면 그 줄부터 첫 `<<` 줄까지는 명령 자리라 그대로 보고(그 줄의 진짜 쓰기 대상은 잠근다), **그 다음 줄부터는 버린다**
 *       (본문일 수 있다 — 본문은 코드·글이라 경로로 나가면 내용이 샌다). 버렸으면 「모름」(grey) — 그 뒤의 쓰기는
 *       고친 뒤 기록(git status · 수정 시각)과 커밋 전 확인이 받는다. 덜 잠그는 쪽으로 틀리지만, 내용은 새지 않는다.
 *       `<<` 가 하나도 없으면 본문이 없으니 예전처럼 끝까지 본다. 한 줄 안의 산술(`$((1<<3))`)은 `<<` 로 치지 않는다.
 * 예외 하나: 커밋 메시지에 늘 쓰는 `… "$(cat <<'EOF'` ⏎ 본문 ⏎ `EOF` ⏎ `)"` 모양은 그 모양 그대로일 때만 인정한다.
 * 끝 표식 줄은 앞 탭(`<<-`)·끝 \r(Windows)을 빼고 비교. 끝 표식을 못 찾으면 셸처럼 명령 끝까지가 본문 — 버리고 unclosed.
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
      const inner = L.slice(i + 1, e);
      if (/[`\\]/.test(inner) || /\$(?![A-Za-z0-9_?#@*!$-])/.test(inner)) return null; // 단순 변수만 — $( ${ $[ 는 애매
      i = e;
      continue;
    }
    if (c === "#" && (i === 0 || /[\s;|&]/.test(L[i - 1]))) break; // 주석 — 줄 끝까지
    if (c === "$") {
      // 단순 변수(`$HOME` · `$1` · `$?`)는 맥락을 바꾸지 않는다. `$(` `${` `$[` `$'…'` `$"…"` 는 애매.
      const v = /^[A-Za-z_][A-Za-z0-9_]*|^[0-9?#@*!$-]/.exec(L.slice(i + 1));
      if (!v) return null;
      i += v[0].length;
      continue;
    }
    if (/[`\\(){}[\]]/.test(c)) return null;
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

/** heredoc 처럼 보이는 `<<`(히어스트링 `<<<` 은 아니다) — 이 줄 다음부터 본문일 수 있다. 한 줄 안에서 닫히는 산술은 뺀다. */
const HD_LIKE = /(^|[^<])<<(?!<)/;
// 따옴표·백슬래시·중괄호·`;`·`#` 가 든 것은 산술로 치지 않는다 — `'((' <<EOF '))'` 처럼 따옴표 속 괄호에 속아 `<<` 까지 걷지 않게
const ARITH = /\$?\(\([^()'"`\\{};#]*\)\)/g;
const hdLike = (line) => HD_LIKE.test(line.replace(ARITH, ""));

/** @returns {{text: string, unclosed: boolean, dropped: boolean}} */
export function heredocScan(command) {
  const lines = command.split("\n");
  const keep = [];
  let unclosed = false;
  let dropped = false;
  const findEnd = (from, end, tabs) => {
    for (let k = from; k < lines.length; k++) {
      let l = lines[k].replace(/\r$/, "");
      if (tabs) l = l.replace(/^\t+/, "");
      if (l === end) return k;
    }
    return -1;
  };
  // 줄 k 가 heredoc 을 열 수 있나 — 0 = 아니다 · n = 줄 k 부터 n 줄(끝 백슬래시 줄 이음으로 `<` ⏎ `\` ⏎ `<EOF` 처럼 이어진 것까지)
  const opensAt = (k) => {
    let joined = "";
    for (let j = k; j < lines.length; j++) {
      const l = lines[j].replace(/\r$/, "");
      const cont = /\\$/.test(l);
      joined += cont ? l.slice(0, -1) : l;
      if (hdLike(joined)) return j - k + 1;
      if (!cont) return 0;
    }
    return 0;
  };
  // 애매한 맥락의 나머지(②) — 첫 `<<` 줄까지는 그대로 보고, 그 다음 줄부터 버린다.
  const rest = (from) => {
    for (let k = from; k < lines.length; k++) {
      const o = opensAt(k);
      keep.push(...lines.slice(k, k + Math.max(o, 1)));
      if (o) { if (k + o < lines.length) dropped = true; return; }
    }
  };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const c = HD_COMMIT.exec(line);
    if (c && analyzeLine(c.groups.pre)?.hd === null) {
      const g = c.groups;
      const e = findEnd(i + 1, g.end, g.dash === "-");
      if (e < 0) { keep.push(g.pre); unclosed = true; dropped = i + 1 < lines.length; break; } // 끝까지가 메시지 — 버린다
      // 메시지(본문)는 i+1 ~ e-1 로 확실하다 — 걷는다. 그 뒤가 정해진 모양(`)"` + 확실한 꼬리)이 아니면 뒤는 애매한 맥락.
      const close = (lines[e + 1] ?? "").replace(/\r$/, "");
      const tail = close.slice(2);
      if (!close.startsWith(')"')) { keep.push(g.pre); rest(e + 1); break; }
      keep.push(g.pre + tail); // 메시지 자리는 비운다 — 남은 꼬리(리다이렉션 등)는 그대로 본다
      const ta = analyzeLine(tail);
      if (ta === null || ta.hd) {
        // 꼬리가 애매하거나 heredoc 을 연다 — 꼬리 줄이 `<<` 를 품으면 그 다음부터, 아니면 첫 `<<` 줄 다음부터 버린다
        if (hdLike(tail) || /\\$/.test(tail)) { if (e + 2 < lines.length) dropped = true; } else rest(e + 2);
        break;
      }
      i = e + 1;
      continue;
    }
    const a = analyzeLine(line);
    if (a === null) { rest(i); break; } // 애매 — ②
    keep.push(line);
    if (!a.hd) continue;
    const e = findEnd(i + 1, a.hd.end, a.hd.dash);
    if (e < 0) { unclosed = true; dropped = i + 1 < lines.length; break; } // 끝 표식이 없으면 셸처럼 끝까지가 본문 — 버린다
    i = e; // 본문과 끝 표식 줄을 건너뛴다
  }
  return { text: keep.join("\n"), unclosed, dropped };
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
  // 끝 표식을 못 찾은 heredoc · 애매해서 버린 뒤쪽 — 놓쳤을 수 있으니 「모름」으로 넘겨
  //   고친 뒤 기록과 커밋 전 확인이 받게 한다(이름 없는 셸 작업)
  let grey = hd.unclosed || hd.dropped;
  if (hd.unclosed) forms.add("닫히지 않은 heredoc");
  if (hd.dropped && !hd.unclosed) forms.add("애매한 heredoc(본문 버림)");

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
