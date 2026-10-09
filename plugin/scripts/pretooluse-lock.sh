#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 팀핑 플러그인 — 편집 전 훅(파일 잠금).
#
# Edit/Write(그리고 파일을 바꾸는 Bash 명령) 직전에 팀핑에 묻는다. 다른 사람이 그 파일을 잡고 있으면
# 편집을 막고(permissionDecision:"deny") 그 이유를 AI 에게 전달한다 — AI 가 스스로 다른 길을 찾는다.
#
# 서버가 응답하지 않거나 오류이거나, 토큰이 없으면 편집을 막지 않는다(아무것도 출력하지 않고 exit 0).
#
# 필요한 것: Node(Claude Code 가 이미 요구한다). jq 는 필요 없다.
#
# 파일 경로는 레포 기준 상대경로로 바꿔 보낸다 — 사람마다 홈 폴더가 달라도 같은 파일로 만난다.
# 레포는 git remote origin 주소(없으면 폴더 이름)로 알린다. 팀핑에 연결되지 않은 레포면 서버가 통과시키고 안내만 한다.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# 자동화 세기(TEAMPING_LEVEL) 해석:
#   · lv0~lv3 이면 그대로
#   · 플러그인으로 실행 중인데(CLAUDE_PLUGIN_ROOT 있음) 값이 비었거나 치환되지 않은 템플릿이면 → 기본값 lv2
#     (CLI 로 설치하면 옵션을 묻지 않아 값이 비어 있을 수 있다)
#   · 플러그인이 아니면(훅을 직접 건 경우) → lv1 — 지정하지 않은 자동화는 켜지 않는다
LEVEL="${TEAMPING_LEVEL-}"
case "$LEVEL" in
  lv0 | lv1 | lv2 | lv3) ;;
  *) [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && LEVEL="lv2" || LEVEL="lv1" ;;
esac
case "$LEVEL" in
  lv0 | lv1) exit 0 ;; # 끔·수동은 편집에 개입하지 않는다
esac

command -v node >/dev/null 2>&1 || exit 0

# Bash 명령도 파일을 바꿀 수 있으므로 잠금 대상이다.
# Bash 는 가장 자주 불리는 도구라, 파일을 바꿀 리 없는 명령은 node 를 띄우기 전에 bash 내장만으로 먼저 거른다.
# 이 거름은 속도를 위한 것일 뿐이고 쓰기 여부의 판정은 bash-write-targets.mjs 가 한다. 애매하면 판정기로 넘긴다.
if [ -t 0 ]; then INPUT=""; else INPUT="$(cat)"; fi
case "$INPUT" in
  *'"tool_name":"Bash"'* | *'"tool_name": "Bash"'*)
    # 명령 문자열만 떼어낸다. 떼지 못하면 판정기로 넘긴다(느려질 뿐 놓치지 않는다).
    CMD=""
    case "$INPUT" in
      *'"command":"'*)  CMD="${INPUT#*'"command":"'}" ;;
      *'"command": "'*) CMD="${INPUT#*'"command": "'}" ;;
    esac
    if [ -n "$CMD" ]; then
      # tool_input 안에서 command 다음에 오는 필드까지만. 못 자르면 CMD가 길어질 뿐 판정은 안전하다.
      CMD="${CMD%%'","description"'*}"
      CMD="${CMD%%'", "description"'*}"
    fi
    if [ -n "$CMD" ]; then
      case "$CMD" in
        # 리다이렉션 · 히어독 · 알파벳이 하나라도 있으면 판정기로 넘긴다.
        *[\>]* | *'<<'* | *[A-Za-z]*) ;;
        *) exit 0 ;;
      esac
      # 확실한 조회 명령만 값싸게 떨군다(속도 최적화일 뿐 판정이 아니다).
      # `|`·`;`·`&` 로 나눈 모든 구간의 첫 단어가 조회 명령일 때만 떨군다 — 하나라도 모르는 이름이면 판정기로 넘긴다.
      case "$CMD" in
        # 리다이렉션·명령 치환(`$( )`·백틱)이 있으면 판정기로 — 치환 안은 독립된 명령이라 첫 단어로 판단할 수 없다.
        *[\>]* | *'<<'* | *'$('* | *'`'*) ;;
        *)
          _rest="$CMD"; _all_read=1
          while [ -n "$_rest" ]; do
            case "$_rest" in
              *"|"*) _seg="${_rest%%|*}"; _rest="${_rest#*|}" ;;
              *";"*) _seg="${_rest%%;*}"; _rest="${_rest#*;}" ;;
              *"&"*) _seg="${_rest%%&*}"; _rest="${_rest#*&}" ;;
              *)     _seg="$_rest"; _rest="" ;;
            esac
            # 첫 단어(앞 공백 제거). `git status` 처럼 두 단어인 것은 아래 목록이 함께 본다.
            while [ "${_seg# }" != "$_seg" ]; do _seg="${_seg# }"; done
            case "$_seg" in
              # 이름 그대로이거나 `이름 ` 뒤에 인자가 올 때만 받는다 — `headers.sh` 처럼 접두사만 같은 다른 명령은 판정기로 간다.
              git\ status*|git\ log*|git\ diff*|git\ show*|git\ branch*|git\ remote*|git\ rev-parse*|\
              ls|ls\ *|pwd|cat|cat\ *|head|head\ *|tail|tail\ *|wc|wc\ *|echo|echo\ *|\
              printf|printf\ *|which|which\ *|env|date|\
              grep|grep\ *|rg|rg\ *|ag|ag\ *|jq|jq\ *|sort|sort\ *|uniq|uniq\ *|cut|cut\ *|\
              tr|tr\ *|diff|diff\ *|file|file\ *|stat|stat\ *|du|du\ *|df|df\ *|ps|ps\ *|\
              uname|uname\ *|whoami|hostname|basename|basename\ *|dirname|dirname\ *|\
              realpath|realpath\ *|seq|seq\ *|true|false|sleep|sleep\ *|tree|tree\ *|\
              column|column\ *|nl|nl\ *|comm|comm\ *|paste|paste\ *|less|less\ *|more|more\ *|"") ;;
              *) _all_read=0; break ;;
            esac
          done
          [ "$_all_read" = "1" ] && exit 0
          ;;
      esac
    fi
    ;;
esac

# 진단 신호 — 기본은 꺼져 있다. TEAMPING_HOOK_TRACE 를 켜면 「사전 거름을 지났다」만 stderr 로 알린다(값은 싣지 않는다).
[ -n "${TEAMPING_HOOK_TRACE:-}" ] && printf 'GATE_PASSED\n' >&2

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

# 토큰·서버 주소는 resolve-token.sh 가 찾는다(프로젝트 .mcp.json → 사용자 ~/.claude.json).
# 플러그인은 토큰을 따로 저장하지 않는다.
CREDS="$(bash "$(dirname "${BASH_SOURCE[0]}")/resolve-token.sh")"
TOKEN="$(printf '%s\n' "$CREDS" | sed -n 's/^TEAMPING_TOKEN=//p')"
BASE="$(printf '%s\n' "$CREDS" | sed -n 's/^TEAMPING_BASE=//p')"
if [ -z "$TOKEN" ]; then
  # 연결 열쇠(토큰)가 없으면 서버에 물을 수 없으므로, 잠기지 않았다는 사실을 세션당 한 번 여기서 알린다.
  #    표식 파일은 임시 폴더($TMPDIR)에 세션 id 로만 만든다. 편집은 그대로 진행된다.
  _sid="$(printf '%s' "$INPUT" | node -e 'let r="";process.stdin.on("data",c=>r+=c).on("end",()=>{let s="nosess";try{s=String(JSON.parse(r).session_id||"nosess")}catch{}process.stdout.write(s.replace(/[^A-Za-z0-9_-]/g,"_"))})' 2>/dev/null || echo nosess)"
  _mark="${TMPDIR:-/tmp}/teamping-notice-${_sid}-no-token-env"
  if [ ! -e "$_mark" ]; then
    : > "$_mark" 2>/dev/null || true
    # i18n-exempt: 열쇠가 없으면 서버 문구를 받을 수 없어 셸이 직접 말한다(한/영).
    if [ "${TEAMPING_LANG:-ko}" = "en" ]; then
      printf '%s' '{"systemMessage":"⚠️ Teamping: this edit was not locked — no connection key found (the teamping entry in .mcp.json or ~/.claude.json). Issue a key on My page and connect."}'
    else
      # i18n-exempt: 열쇠가 없으면 서버 문구를 받을 수 없다 — 바로 위가 영문.
      printf '%s' '{"systemMessage":"⚠️ 팀핑: 이 편집은 잠기지 않았습니다 — 연결 열쇠(토큰)를 찾지 못했습니다(.mcp.json 또는 ~/.claude.json 의 teamping 항목). 마이페이지에서 열쇠를 받아 연결하세요."}'
    fi
  fi
  exit 0
fi

# 레포 식별자 — git이 없거나 remote가 없으면 디렉토리명으로 폴백
REPO_KEY="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || true)"
[ -n "$REPO_KEY" ] || REPO_KEY="$(basename "$PROJECT_DIR")"

export TEAMPING_TOKEN="$TOKEN" TEAMPING_BASE="$BASE" TEAMPING_PROJECT_DIR="$PROJECT_DIR" TEAMPING_REPO_KEY="$REPO_KEY"
. "$(dirname "$0")/window-id.sh" # 이 창의 식별자(TEAMPING_WINDOW_ID) — 서버가 이 창의 잠금만 풀게
# Bash 명령에서 쓰기 대상 파일을 뽑는 판정기.
export TEAMPING_EXTRACTOR="$(dirname "${BASH_SOURCE[0]}")/bash-write-targets.mjs"
export TEAMPING_TREES="$(dirname "${BASH_SOURCE[0]}")/repo-trees.mjs" # 같은 레포의 작업 폴더(git worktree) 목록

printf '%s' "$INPUT" | node --input-type=module -e '
const fs = await import("node:fs");
const path = await import("node:path");

// 어떤 예외도 통과로 끝낸다 — 이 훅이 사람 작업을 막는 일은 없어야 한다.
const passThrough = () => process.exit(0);

let raw = "";
try { for await (const chunk of process.stdin) raw += chunk; } catch { passThrough(); }

let input;
try { input = JSON.parse(raw); } catch { passThrough(); }

const projectDir = process.env.TEAMPING_PROJECT_DIR;

// 같은 레포의 다른 작업 폴더(git worktree)에서 고친 파일도 잠근다. 목록은 git 에게 묻고(repo-trees.mjs),
//    이름은 레포 기준 상대경로라 어느 폴더에서 고쳐도 같은 파일로 만난다.
//    git 이나 모듈이 없으면 세션 폴더 안의 파일만 본다.
let trees;
const repoTrees = async () => {
  if (trees !== undefined) return trees;
  try {
    const m = await import(process.env.TEAMPING_TREES);
    const info = m.listRepoTrees(projectDir, { timeout: 1500 }); // 서버 문의(2초)보다 짧게 끊는다
    trees = info ? { m, info } : null;
  } catch { trees = null; }
  return trees;
};

// 프로젝트 기준 상대경로로 바꾼다. 프로젝트 밖 파일이면 팀 자산이 아니므로 관여하지 않는다.
// ⚠️ Bash는 다른 디렉토리에서 돌 수 있으므로 훅이 준 cwd를 기준으로 먼저 절대화한다.
const toRel = (p, cwd) => {
  if (typeof p !== "string" || !p) return null;
  if (trees) {
    try { return trees.m.resolveInTrees(p, trees.info, cwd)?.rel ?? null; } catch { return null; }
  }
  const abs = path.isAbsolute(p) ? p : path.resolve(cwd || projectDir, p);
  const rel = path.relative(projectDir, abs);
  if (!rel || rel.startsWith("..") || path.isAbsolute(rel)) return null;
  return rel.split(path.sep).join("/");
};

let paths = [];
if (input?.tool_name === "Bash") {
  // 명령 원문은 이 컴퓨터 안에서만 다룬다. 서버로 가는 것은 뽑힌 파일 경로뿐이다.
  const command = input?.tool_input?.command;
  if (typeof command !== "string" || !command) passThrough();
  let extract;
  try { ({ extractWriteTargets: extract } = await import(process.env.TEAMPING_EXTRACTOR)); } catch { passThrough(); }
  let out;
  try { out = extract(command); } catch { passThrough(); }
  if (!(out?.targets ?? []).length) passThrough(); // 쓰기 대상이 없으면 git 도 부르지 않는다
  await repoTrees();
  paths = (out?.targets ?? []).map((t) => toRel(t, input?.cwd)).filter(Boolean);
  // 여기서 경로를 정하지 못한 명령은 커밋 전 확인(켰다면)이 이어서 본다.
  if (!paths.length) passThrough();
} else {
  if (typeof input?.tool_input?.file_path !== "string" || !input.tool_input.file_path) passThrough();
  await repoTrees();
  const rel = toRel(input?.tool_input?.file_path, null);
  if (!rel) passThrough();
  paths = [rel];
}

const token = process.env.TEAMPING_TOKEN ?? "";
const base = process.env.TEAMPING_BASE || "https://teamping.dev";

// 서버가 통과시키면서 잠그지 않은 이유(notice)를 알려 오면 세션당 한 번 사람에게 보인다.
//    표식 파일은 임시 폴더에 세션 id 와 이유로만 만든다 — 토큰·경로는 들어가지 않는다.
const os = await import("node:os"); // fs·path 는 위에서 이미 들여왔다
const noticeOnce = (why, text) => {
  if (!text) return;
  const sid = String(input?.session_id ?? "nosess").replace(/[^A-Za-z0-9_-]/g, "_");
  const mark = path.join(os.tmpdir(), `teamping-notice-${sid}-${String(why).replace(/[^A-Za-z0-9_-]/g, "_")}`);
  try { if (fs.existsSync(mark)) return; fs.writeFileSync(mark, ""); } catch { /* 표식을 못 쓰면 매번 보이는 쪽이 낫다 */ }
  // systemMessage = 사람에게 보이는 줄(모델 컨텍스트가 아니다). 허용 결정은 그대로다.
  process.stdout.write(JSON.stringify({ systemMessage: String(text) }));
};

if (!token) passThrough(); // 열쇠가 없는 경우는 위 셸 부분에서 이미 끝났다

try {
  const res = await fetch(`${base}/api/hooks/pretooluse`, {
    method: "POST",
    // 응답 문구의 언어(TEAMPING_LANG · 없으면 ko).
    headers: { "content-type": "application/json", authorization: `Bearer ${token}`, "accept-language": process.env.TEAMPING_LANG || "ko" },
    body: JSON.stringify({
      session_id: input.session_id,
      window_id: process.env.TEAMPING_WINDOW_ID || undefined, // 어느 창이 잡았나
      agent: "claude-code",
      locale: process.env.TEAMPING_LANG || "ko",
      tool_name: input.tool_name,
      file_path: paths[0],       // 옛 서버와도 말이 통하게 첫 경로는 그대로 둔다
      file_paths: paths,         // Bash 한 줄이 여러 파일을 쓴다
      repo_key: process.env.TEAMPING_REPO_KEY,
    }),
    signal: AbortSignal.timeout(2000),
  });
  const data = await res.json();
  // 서버가 「검사하지 못한 경로가 있다」고 알려 오면 그 개수를 알린다.
  if (Number(data?.truncated) > 0) {
    process.stderr.write(
      (process.env.TEAMPING_LANG || "ko") === "en"
        ? `Teamping: ${data.truncated} path(s) could not be checked (the pre-commit gate will look again).\n`
        // i18n-exempt: 서버 응답의 숫자를 세는 자리라 대응하는 서버 문장이 없다 — 바로 위에 영문 형제가 있다.
        : `팀핑: 경로 ${data.truncated}개는 확인하지 못했습니다(커밋 전 게이트가 다시 봅니다).\n`,
    );
  }
  if (data?.decision === "deny" && typeof data.reason === "string") {
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: data.reason,
      },
    }));
  } else if (typeof data?.notice === "string" && data.notice) {
    // 통과인데 서버가 「왜 안 잠갔나」를 말했다(레포 미연결 · 볼 수 없는 프로젝트 · 열쇠 무효/권한 없음 · 요청 과다) → 한 번 보인다.
    noticeOnce(data?.why ?? "allow", data.notice);
  }
} catch { /* 서버 미응답·타임아웃 → 통과 */ }
process.exit(0);
'
exit 0
