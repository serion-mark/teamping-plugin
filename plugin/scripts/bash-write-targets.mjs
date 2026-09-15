// ─────────────────────────────────────────────────────────────────────────────
// 팀핑 — Bash 명령에서 **쓰기 대상 파일**을 뽑는다 (강제 락 A).
//
// 왜 이 파일이 있나 (실측):
//   파일 락은 `PreToolUse`가 `file_path`를 가진 도구(Edit·Write)를 볼 때만 걸렸다.
//   그런데 프로덕션 관측 32,285건에서 **파일 변경의 44.1%가 Bash 경유**였고,
//   Bash가 바꾼 219개 파일 중 **91개는 락 이력이 아예 없었다**(102개가 .ts).
//   조율 문이 절반쯤 열려 있었다는 뜻이다.
//
// ⭐ 데이터 경계 (이 설계의 제1 제약):
//   **명령 전문은 서버로 보내지 않는다.** 명령줄에는 토큰·비밀번호가 섞일 수 있고
//   (이 제품의 절대규칙), 우리가 고객에게 "무엇을 보내는지" 약속한 목록에도 없다.
//   그래서 추출은 **훅 안(고객 기계)에서** 하고, 서버로는 뽑힌 **경로만** 간다.
//
// ⭐⭐ 이 모듈이 돌려주는 것은 "대상 목록"이 아니라 **판정 상태**다 (적대검증 후 재설계).
//   초판은 대상만 돌려줬고, 그래서 **모르는 경우가 "아무것도 없음"과 구분되지 않았다.**
//   적대검증 3축이 그 길을 여섯 갈래 찾아냈다: find -exec · xargs · 확장자 없는 인터프리터
//   (bash/ruby/terraform) · curl -o · awk '{print > "f"}' · 변수 확장 `$OUT`.
//   전부 **조용히 통과**했다 — 주석은 "회색지대는 숨기지 않는다"고 말하는데 숨기고 있었다.
//
//   그래서 지금은 세 값을 함께 돌려준다:
//     · targets — **확실히** 이 파일을 쓴다(잠글 근거가 있다)
//     · grey    — 쓰기는 일어나는데 **대상을 특정할 수 없다**(실행 전 텍스트로는 원리적으로 불가)
//     · forms   — 무엇 때문에 그렇게 봤나(사람이 읽고 판단할 근거)
//   ⛔ grey를 "대상 없음 = 안전"으로 뭉개지 마라. 그게 초판의 병이었고, 그 구멍은
//     커밋 전 게이트(precommit-lock.sh)가 받는다.
//
// ⭐ 정밀도가 재현율보다 앞이다:
//   `grep foo app/src/x.ts > out.txt` 에서 잠가야 할 건 `out.txt`뿐이다. `x.ts`는 읽기만 한다.
//   읽는 파일까지 잠그면 남의 작업을 근거 없이 막게 되고, 그러면 이 도구는 삭제된다.
//   확실하지 않으면 **targets에 넣지 말고 grey로 넘긴다** — 틀린 락보다 정직한 모름이 낫다.
// ─────────────────────────────────────────────────────────────────────────────

/** 쓰기가 일어날 수 있음을 알리는 형태들. 하나도 안 걸리면 네트워크도 타지 않는다. */
// ⚠️ git의 쓰기 하위명령을 빼먹지 마라 — 재작성 중에 실제로 빠뜨렸고, 옛 회귀가 잡았다
//    (`git checkout -- x.ts` 가 targets 0건이 됐다). 여기서 빠지면 판정기까지 도달조차 못 한다.
const WRITE_FORM =
  /(^|[^>&])>>?[^&]|&>|>&\s*[^0-9]|\btee\b|\bsed\b|\bcp\b|\bmv\b|\brm\b|\bmkdir\b|\btouch\b|\bln\b|\binstall\b|\bpatch\b|\bgit\s+(checkout|restore|apply|am|reset|stash|merge|rebase|pull|revert|clean|mv|rm)\b|<<\s*['"]?[A-Za-z_]/;

/**
 * 대상을 알 수 없는 채로 파일을 바꿀 수 있는 명령들 — 회색지대의 정체.
 *
 * ⚠️ 여기 있는 이름은 **반드시 mayWrite()도 통과시켜야 한다.** 초판은 그러지 않아서
 *    `bash x` · `ruby y` · `terraform apply` 가 사전 게이트에 먼저 막혀 이 분기까지
 *    **도달조차 못 했다**(적대검증: "OPAQUE는 죽은 코드"). 아래 OPAQUE_RUN이 그 다리다.
 */
const OPAQUE_NAMES = [
  "npm", "npx", "yarn", "pnpm", "make", "cargo", "go", "docker", "docker-compose",
  "bash", "sh", "zsh", "python", "python3", "ruby", "perl", "node", "deno", "bun",
  "gradle", "mvn", "ansible", "ansible-playbook", "terraform", "pulumi", "helm", "kubectl",
  // 대상을 인자로 받긴 하지만 형태가 제각각이라 확실히 뽑을 수 없는 것들(적대검증 WARN):
  "curl", "wget", "dd", "openssl", "awk", "gawk", "xargs", "find", "rsync", "tar", "unzip", "sponge",
];
const OPAQUE = new RegExp(`^(${OPAQUE_NAMES.join("|")})$|\\.(sh|bash|zsh|py|rb|pl|mjs|cjs|js)$`);
/** 위 이름·스크립트 실행이 명령 어딘가에 있으면 사전 게이트를 통과시킨다(= 판정기까지 간다). */
const OPAQUE_RUN = new RegExp(
  `(^|[\\s;|&(])(${OPAQUE_NAMES.join("|")})(\\s|$)|(^|[\\s;|&(])\\.{0,2}[\\w./-]*\\.(sh|bash|zsh|py|rb|pl|mjs|cjs|js)\\b`,
);

/** 쓰기 대상이 아닌 곳들 — 잠글 이유가 없다. */
const NOT_A_TARGET = /^(\/dev\/(null|stdout|stderr|tty)|&[0-9]|[0-9])$/;
/** 실행 시점에 정해지는 이름 — 지금 잠그면 엉뚱한 파일을 잠근다(적대검증 WARN-1). */
const RUNTIME_EXPANDED = /[$`*?[\]{}~]/;

/**
 * 명령을 **따옴표를 존중하며** 한 번에 훑어 구간과 토큰으로 나눈다.
 *
 * ⚠️ 초판은 `split(/[;|]/)` 이었다. 그래서 `find … -exec sed -i {} \;` 의 `\;` 와
 *    `a | xargs sed -i` 의 파이프에서 잘려 명령 이름이 `find`/`xargs`가 됐고,
 *    `echo x > "a|b.txt"` 는 따옴표 안에서 잘려 **없는 파일 'a'를 잠갔다**(적대검증 BLOCK-2·WARN-2).
 */
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
    // ⭐ `$( … )` · 백틱 안도 **독립된 명령**이다. 구간으로 안 나누면 head가 바깥 명령(`echo`)이 되어
    //    `echo $(sed -i '' s/a/b/ q.ts)` 가 "쓰기 없음"으로 보고된다(2차 교차검수 WARN-N6).
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

  const targets = new Set();
  const forms = new Set();
  let grey = false;

  /** 확실할 때만 잠근다. 실행 시점에 정해지는 이름이면 잠그지 말고 모름으로 넘긴다. */
  const addTarget = (raw) => {
    if (!raw || NOT_A_TARGET.test(raw)) return;
    if (RUNTIME_EXPANDED.test(raw)) { grey = true; forms.add("실행시점이름"); return; }
    // `dir/` 처럼 디렉토리로 끝나면 최종 파일 경로를 알 수 없다(적대검증 WARN-5).
    if (raw.endsWith("/")) { grey = true; forms.add("디렉토리대상"); return; }
    if (hasCd && !raw.startsWith("/")) { grey = true; forms.add("cd로 기준이 바뀜"); return; }
    targets.add(raw);
  };

  // ⭐⭐ `cd` 가 있으면 상대경로의 기준이 명령 안에서 바뀐다(훅은 훅 입력의 cwd만 안다).
  //   2차 교차검수 실측: `cd sub && sed -i "" s/a/b/ rel.ts` → 훅이 `rel.ts` 를 보내
  //   **진짜 파일(sub/rel.ts)은 안 잠기고 루트의 무관한 rel.ts가 잠겼다.** 이중 오류다 —
  //   "읽는 파일을 잠근다"보다 나쁜 "건드리지도 않은 파일 점유". 그래서 절대경로만 남기고
  //   상대경로는 모름으로 넘긴다.
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
    // ⚠️ 이걸 안 빼면 `tee -a out.log <<< hi` 에서 히어스트링 내용 `hi`를 파일로 잠근다
    //    (적대검증 WARN-3: 저장소에 실제로 그 이름의 파일이 있으면 무관한 동료가 막힌다).
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
        // ⚠️ 초판은 여기서 `slice(1)`을 또 해서 **첫 파일을 통째로 버렸다**(적대검증 BLOCK-3):
        //    `sed -i '' 's/a/b/' a.ts b.ts` → a.ts 미탐. 다중 파일 sed는 리팩터링의 대표 형태다.
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
        // ⭐ mv는 **원본도 파괴한다**(적대검증 WARN-4): 남이 편집 중인 파일을 옮기면
        //    아무 신호 없이 사라진다. 그래서 원본과 목적지를 함께 잠근다(cp와 다른 점).
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
          // ⚠️ 무엇이 바뀔지는 diff·상대 브랜치 안에 있다. `git apply patch.diff`의 patch.diff는
          //    **읽기 전용**이라 잠그면 오탐이다(적대검증 WARN-3).
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
 * 훅에서 쓰는 빠른 사전 게이트 — 쓰기 가능성이 하나도 없으면 아무 일도 하지 않는다.
 *
 * ⚠️ **이 함수가 유일한 판정 소스여야 한다.** 초판은 셸 스크립트에 같은 목록을 손으로 한 벌 더
 *    두었고(세 번째 사본), 그 사본이 JSON 전문에 글롭을 걸어 `transcript_path`의 `.jsonl` 에
 *    항상 걸렸다 — 즉 **프로덕션에서 사전 필터가 100% 무효**였다(적대검증 실측 p95 90.9ms).
 *    지금은 훅이 명령 문자열만 떼어 이 함수에 물어본다.
 */
export function mayWrite(command) {
  return typeof command === "string" && (WRITE_FORM.test(command) || OPAQUE_RUN.test(command));
}
