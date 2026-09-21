#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 팀핑 플러그인 — PreToolUse 훅(파일 락).
#
# 무엇: Edit/Write 직전에 팀핑에 물어본다. 다른 사람이 그 파일을 잡고 있으면
#       permissionDecision:"deny" + 사유를 돌려주고, 그 사유가 에이전트 컨텍스트로
#       들어가 AI가 스스로 "다른 사람이 작업 중이네요, 우회할게요"라고 말한다.
#
# ⭐ fail-open이 제1원칙: 서버가 죽든 토큰이 없든 jq가 없든 **무조건 통과시킨다.**
#    팀 도구가 개인 작업을 막는 순간 그 도구는 삭제된다. 그래서 이 스크립트의
#    모든 실패 경로는 "아무것도 출력하지 않고 exit 0"이다(= Claude Code는 그대로 진행).
#
# 의존성: Node만(Claude Code 필수 요건이라 항상 있다). jq 불필요.
#
# ⭐ 경로 정규화: tool_input.file_path는 **절대경로**로 온다. 그대로 보내면
#    사람마다 홈 디렉터리가 달라 절대경로 문자열이 서로 다르고, 그래서 충돌이
#    영원히 감지되지 않는다. CLAUDE_PROJECT_DIR 기준 상대경로로 바꿔 보낸다.
#
# 레포 식별: git remote origin URL → 없으면 디렉토리 basename. 서버가 정규화해
#    채널을 찾는다. 매핑이 없으면 서버가 그냥 allow하고 "등록할까요" 신호만 남긴다.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# ⭐ 레벨 해석(실설치에서 잡음). 세 경우를 갈라야 한다:
#   · 값이 있으면 그대로(lv0~lv3)
#   · **비었거나 치환되지 않은 템플릿**(`${CLAUDE_PLUGIN_OPTION_...}`)이면 → 플러그인이 선언한 기본값 lv2.
#     CLI 설치(`claude plugin install`)는 옵션을 묻지 않아 값이 안 채워질 수 있는데, 그걸 lv1(조용)로 읽으면
#     **설치했는데 아무 일도 안 일어나는** 상태가 된다 — 우리가 없애려던 바로 그 증상이다.
#   · 아예 없으면(손으로 훅을 건 경우) lv1 — 명시하지 않은 자동화는 켜지 않는다.
LEVEL="${TEAMPING_LEVEL-}"
# ⭐ 플러그인으로 실행 중인지는 CLAUDE_PLUGIN_ROOT로 안다(플러그인 훅에만 주어진다).
#    플러그인인데 레벨이 비었거나·안 넘어왔거나·템플릿이 그대로면 → 선언된 기본값 lv2.
#    (CLI 설치는 userConfig를 묻지 않아 값이 없을 수 있다. 그걸 조용함으로 읽으면
#     "설치했는데 아무 일도 안 일어남" = 없애려던 그 증상이 된다.)
#    플러그인이 아니면(손으로 훅을 건 경우) 명시하지 않은 자동화는 켜지 않는다 → lv1.
case "$LEVEL" in
  lv0 | lv1 | lv2 | lv3) ;;
  *) [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && LEVEL="lv2" || LEVEL="lv1" ;;
esac
case "$LEVEL" in
  lv0 | lv1) exit 0 ;; # 끔·수동은 편집에 개입하지 않는다
esac

command -v node >/dev/null 2>&1 || exit 0

# ⭐⭐ Bash 경로 — 여기가 조율 문의 절반이었다.
#   실측(프로덕션 관측 32,285건): **파일 변경의 44.1%가 Bash 경유**였고, Bash가 바꾼 219개 파일 중
#   91개는 락 이력이 아예 없었다(102개가 .ts). 원인은 이 훅의 matcher가 Edit·Write뿐이었던 것.
#
# ⚠️ 지연: Bash는 가장 자주 불리는 도구다(같은 기간 Bash 19,596 vs Edit 3,066).
#   그래서 읽기 명령에는 node를 안 띄운다 — bash 내장만으로 먼저 거른다(프로세스 0개).
#
# ⛔⛔ 여기에 판정 목록을 **손으로 한 벌 더 두지 마라.** 초판이 그랬고, 그 사본이
#   **JSON 전문**에 글롭을 걸었다. 실제 훅 입력에는 `transcript_path`(= …/<세션>.jsonl)가
#   항상 들어 있어서 `*.js*` 가 **언제나** 걸렸다 — 즉 사전 필터가 **프로덕션에서 100% 무효**였고
#   (적대검증 실측: 읽기 명령 p95 90.9ms · node 항상 1개), 릴리스 노트의 "40.7%가 여기서 끝난다"는
#   실제로는 0%였다. 게다가 목록이 `mayWrite()`와 갈라져 `.bash`·`.zsh` 실행이 조용히 빠졌다.
#
# ⭐ 그래서 두 가지를 바꿨다:
#   ① 글롭을 **명령 문자열에만** 건다(봉투가 아니라). tool_input.command 를 bash 내장으로 떼어낸다.
#   ② 목록은 아주 성긴 **한 글자 신호**만 본다 — 확실한 판정은 `mayWrite()` 하나뿐이고,
#      여기서는 "그럴 리 없는 것"만 떨군다. 애매하면 통과시켜 판정기가 보게 한다(미탐 0 방향).
if [ -t 0 ]; then INPUT=""; else INPUT="$(cat)"; fi
case "$INPUT" in
  *'"tool_name":"Bash"'* | *'"tool_name": "Bash"'*)
    # 명령 문자열만 떼어낸다. 떼지 못하면 **통과**시킨다(판정기가 본다) — 조용한 미탐보다 낫다.
    # ⚠️ 직렬화 표기 두 가지를 다 받는다. 실측상 Claude Code는 공백 없는 `"command":"` 로 보내지만,
    #    표기가 바뀌면 추출이 실패하고 그때는 **통과**한다(느려질 뿐, 놓치지 않는다 = 안전한 방향).
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
        # 성긴 신호: 리다이렉션 · 히어독 · 알파벳 명령 하나라도 있으면 판정기로 넘긴다.
        # (판정의 권위는 mayWrite() — 여기서 목록을 늘리지 마라.)
        *[\>]* | *'<<'* | *[A-Za-z]*) ;;
        *) exit 0 ;;
      esac
      # 확실히 아무 것도 아닌 조회 명령을 값싸게 떨군다. 이 목록은 **판정이 아니라 지연 최적화**이고,
      # 여기서 떨어진 것이 mayWrite()에서 true가 되면 규칙 잠금 시험이 운다.
      #
      # ⭐ **구간별로** 본다. 초판은 명령 전체에 글롭을 걸어 `echo *` 가 `echo x | tee log.txt` 를
      #    통째로 삼켰다 — 뒤 구간의 `tee` 가 조용히 사라졌다(규칙 시험이 즉시 잡았다).
      #    그래서 `|`·`;`·`&` 로 나눠 **모든 구간의 첫 단어가 조회 명령일 때만** 떨군다.
      #    하나라도 모르는 이름이면 판정기로 넘긴다(미탐 0 방향).
      case "$CMD" in
        # 리다이렉션·명령치환이 있으면 무조건 판정기로 — 값싼 목록은 **단순한 한 줄**에만 쓴다.
        # ⚠️ `$( )`·백틱 안은 독립된 명령이라 첫 단어(`echo`)로 판단하면 안 뒤의 쓰기를 삼킨다:
        #    `echo $(sed -i '' s/a/b/ q.ts)` — 규칙 잠금 시험이 이 갈라짐을 잡았다(2차 교차검수 후).
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
              # ⚠️ 글롭에 **앵커가 없으면** 이름이 그 접두사로 시작하는 스크립트까지 삼킨다:
              #   `head*` 가 `headers.sh` 를, `tail*` 가 `tailwind.sh build` 를, `sort*` 가
              #   `sort-imports.py` 를 조회로 오인했다(2차 교차검수 실측 13건). 전부 `이름` 또는
              #   `이름<공백>*` 두 형태만 받는다 — 뒤에 다른 글자가 붙으면 다른 명령이다.
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

# 🔍 계약 시험용 신호 — 기본은 꺼져 있고(비용 0), 켜면 "게이트를 지났다"만 알린다.
#   왜 필요한가: 게이트 통과 여부는 밖에서 관측할 방법이 없었고, 그래서 사전 필터가
#   프로덕션에서 무효였던 것을 **시험이 영원히 못 봤다**. 값은 아무것도 싣지 않는다.
[ -n "${TEAMPING_HOOK_TRACE:-}" ] && printf 'GATE_PASSED\n' >&2

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

# .mcp.json에서 토큰·서버주소(세션 컨텍스트 훅과 동일한 출처 — 토큰을 따로 저장하지 않는다)
# ⭐ 토큰·서버주소는 공용 resolver가 찾는다(프로젝트 .mcp.json → user 레벨 ~/.claude.json).
# 레포마다 .mcp.json을 복사하지 않아도 되도록 넓혔다 — 토큰 하나로 붙였으면 훅도 그 토큰으로 돈다.
CREDS="$(bash "$(dirname "${BASH_SOURCE[0]}")/resolve-token.sh")"
TOKEN="$(printf '%s\n' "$CREDS" | sed -n 's/^TEAMPING_TOKEN=//p')"
BASE="$(printf '%s\n' "$CREDS" | sed -n 's/^TEAMPING_BASE=//p')"
if [ -z "$TOKEN" ]; then
  # ⭐ 22-1 「안 이어졌다」 ③ — 열쇠가 아예 없으면 서버에 못 물으니 여기서 세션당 한 번 말한다(전엔 말없이 통과).
  #    표식은 $TMPDIR(흔적 0) · 이름에 세션 id 만 · systemMessage 는 사람에게 보이는 줄이고 허용 결정은 그대로다.
  #    ⚠️ node 로 가기 전에 끝나므로 아래 JS 의 noticeOnce 가 아니라 여기에 있어야 한다(스텁 실측: JS 쪽은 죽은 코드였다).
  _sid="$(printf '%s' "$INPUT" | node -e 'let r="";process.stdin.on("data",c=>r+=c).on("end",()=>{let s="nosess";try{s=String(JSON.parse(r).session_id||"nosess")}catch{}process.stdout.write(s.replace(/[^A-Za-z0-9_-]/g,"_"))})' 2>/dev/null || echo nosess)"
  _mark="${TMPDIR:-/tmp}/teamping-notice-${_sid}-no-token-env"
  if [ ! -e "$_mark" ]; then
    : > "$_mark" 2>/dev/null || true
    # i18n-exempt: 열쇠가 없어 서버를 부를 수가 없다 — 이 자리만 셸이 스스로 말한다(영문 형제를 나란히 둔다).
    # ⛔ 여기는 **서버에 못 물어보는 유일한 자리**다 — 그래서 문구가 셸에 있다.
    #    그래도 언어는 가른다(원칙). 다른 모든 문장은 서버 사전에서 온다.
    if [ "${TEAMPING_LANG:-ko}" = "en" ]; then
      printf '%s' '{"systemMessage":"⚠️ Teamping: this edit was not locked — no connection key found (the teamping entry in .mcp.json or ~/.claude.json). Issue a key on My page and connect."}'
    else
      # i18n-exempt: 열쇠가 없어 서버를 부를 수가 없다 — 바로 위에 영문 형제가 있다.
      printf '%s' '{"systemMessage":"⚠️ 팀핑: 이 편집은 잠기지 않았습니다 — 연결 열쇠(토큰)를 찾지 못했습니다(.mcp.json 또는 ~/.claude.json 의 teamping 항목). 마이페이지에서 열쇠를 받아 연결하세요."}'
    fi
  fi
  exit 0
fi

# 레포 식별자 — git이 없거나 remote가 없으면 디렉토리명으로 폴백
REPO_KEY="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || true)"
[ -n "$REPO_KEY" ] || REPO_KEY="$(basename "$PROJECT_DIR")"

export TEAMPING_TOKEN="$TOKEN" TEAMPING_BASE="$BASE" TEAMPING_PROJECT_DIR="$PROJECT_DIR" TEAMPING_REPO_KEY="$REPO_KEY"
. "$(dirname "$0")/window-id.sh" # 0.2.17 — 이 창의 식별자(TEAMPING_WINDOW_ID) · 서버가 자기 창의 잠금만 풀게
# 추출기는 **파일로 따로** 둔다(인라인 복사본이 아니라) — 시험이 실제로 도는 그 코드를 재도록.
export TEAMPING_EXTRACTOR="$(dirname "${BASH_SOURCE[0]}")/bash-write-targets.mjs"

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

// 프로젝트 기준 상대경로로 바꾼다. 프로젝트 밖 파일이면 팀 자산이 아니므로 관여하지 않는다.
// ⚠️ Bash는 다른 디렉토리에서 돌 수 있으므로 훅이 준 cwd를 기준으로 먼저 절대화한다.
const toRel = (p, cwd) => {
  if (typeof p !== "string" || !p) return null;
  const abs = path.isAbsolute(p) ? p : path.resolve(cwd || projectDir, p);
  const rel = path.relative(projectDir, abs);
  if (!rel || rel.startsWith("..") || path.isAbsolute(rel)) return null;
  return rel.split(path.sep).join("/");
};

let paths = [];
if (input?.tool_name === "Bash") {
  // ⭐ 명령 전문은 **여기서만** 다룬다. 서버로 가는 것은 뽑힌 경로뿐이다(데이터 경계).
  const command = input?.tool_input?.command;
  if (typeof command !== "string" || !command) passThrough();
  let extract;
  try { ({ extractWriteTargets: extract } = await import(process.env.TEAMPING_EXTRACTOR)); } catch { passThrough(); }
  let out;
  try { out = extract(command); } catch { passThrough(); }
  paths = (out?.targets ?? []).map((t) => toRel(t, input?.cwd)).filter(Boolean);
  // 회색지대(out.grey)는 여기서 막지 않는다 — 무엇을 쓸지 모르는 채로 막으면 4명령 중 1개가 걸린다.
  // 그 구멍은 커밋 전 게이트(tools/precommit-lock.sh)가 받는다. ⛔ "대상 없음 = 안전"이 아니다.
  if (!paths.length) passThrough();
} else {
  const rel = toRel(input?.tool_input?.file_path, null);
  if (!rel) passThrough();
  paths = [rel];
}

const token = process.env.TEAMPING_TOKEN ?? "";
const base = process.env.TEAMPING_BASE || "https://teamping.dev";

// ⭐ 22-1 「안 이어졌다」 — 서버가 통과시킨 이유(notice)를 **세션당 한 번** 사람에게 보인다.
//    훅은 fail-open 이 맞지만 안 막았다는 사실은 보여야 한다(에릭 3부). 표식 파일 = 세션 id + 이유 → 같은 이유는 한 번만.
//    ⚠️ 표식은 $TMPDIR 에 둔다(사용자 홈·프로젝트에 흔적 0). 이름엔 세션 id 와 이유만 — 토큰·경로는 안 들어간다.
const os = await import("node:os"); // fs·path 는 위에서 이미 들여왔다 — 다시 선언하면 스크립트 전체가 조용히 죽는다(실측)
const noticeOnce = (why, text) => {
  if (!text) return;
  const sid = String(input?.session_id ?? "nosess").replace(/[^A-Za-z0-9_-]/g, "_");
  const mark = path.join(os.tmpdir(), `teamping-notice-${sid}-${String(why).replace(/[^A-Za-z0-9_-]/g, "_")}`);
  try { if (fs.existsSync(mark)) return; fs.writeFileSync(mark, ""); } catch { /* 표식을 못 쓰면 매번 보이는 쪽이 낫다 */ }
  // systemMessage = 사람에게 보이는 줄(모델 컨텍스트가 아니다). 허용 결정은 그대로다.
  process.stdout.write(JSON.stringify({ systemMessage: String(text) }));
};

if (!token) passThrough(); // 열쇠 없음은 위 bash 껍데기가 이미 말하고 끝냈다 — 여기는 도달하지 않는다

try {
  const res = await fetch(`${base}/api/hooks/pretooluse`, {
    method: "POST",
    // 22-1 — 언어를 보낸다(Opus 2차 R9: 안 보내니 서버의 en 문장이 플러그인 경로에선 도달 불가였다). TEAMPING_LANG 없으면 ko.
    headers: { "content-type": "application/json", authorization: `Bearer ${token}`, "accept-language": process.env.TEAMPING_LANG || "ko" },
    body: JSON.stringify({
      session_id: input.session_id,
      window_id: process.env.TEAMPING_WINDOW_ID || undefined, // 0.2.17 — 어느 창이 잡았나(옛 서버는 무시)
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
  // i18n-exempt: 서버 응답의 **숫자**를 세는 자리라 대응하는 서버 문장이 없다(영문 형제를 나란히 둔다).
  // ⭐ 서버가 "검사 못 한 경로가 있다"고 하면 숨기지 않는다 — 아무도 안 읽으면 그 필드는 죽은 코드다
  //   (2차 교차검수 BLOCK-N3: 커밋 메시지가 "고지한다"고 썼는데 읽는 쪽이 0곳이었다).
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
