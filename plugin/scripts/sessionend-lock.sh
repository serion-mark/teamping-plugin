#!/usr/bin/env bash
# 팀핑 플러그인 — SessionEnd 훅. 이 세션이 잡은 파일 잠금을 바로 푼다.
# 풀지 않아도 마지막 활동 30분 뒤에 자동으로 풀리지만, 그동안 동료가 그 파일을 못 고친다.
# 어떤 실패도 조용히 exit 0 — 세션 종료를 막지 않는다.
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
case "$LEVEL" in lv0 | lv1) exit 0 ;; esac
command -v node >/dev/null 2>&1 || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

# 이 창 몫으로 맡아 둔 팀핑 연락과 기다리는 훅의 차례 표시를 지운다 — 뒤에서 기다리던 훅이 다음 확인 때 조용히 끝난다.
#   (이미 보여 준 id 기록은 남긴다 — 같은 대화를 이어 열면 같은 줄을 다시 넣지 않게.)
INPUT="$(cat)"
. "$(dirname "${BASH_SOURCE[0]}")/inbox-pending.sh"
teamping_inbox_forget "$INPUT"
# 토큰·서버 주소는 resolve-token.sh 가 찾는다(프로젝트 .mcp.json → 사용자 ~/.claude.json).
# 팀핑 MCP 를 한 번 연결해 두면 훅도 같은 토큰을 쓴다 — 레포마다 따로 설정할 필요가 없다.
CREDS="$(bash "$(dirname "${BASH_SOURCE[0]}")/resolve-token.sh")"
TOKEN="$(printf '%s\n' "$CREDS" | sed -n 's/^TEAMPING_TOKEN=//p')"
BASE="$(printf '%s\n' "$CREDS" | sed -n 's/^TEAMPING_BASE=//p')"
[ -n "$TOKEN" ] || exit 0
export TEAMPING_TOKEN="$TOKEN" TEAMPING_BASE="$BASE"
. "$(dirname "$0")/window-id.sh" # 이 창의 식별자 — 서버가 이 창의 잠금만 푼다

printf '%s' "$INPUT" | node --input-type=module -e '
const fs = await import("node:fs");
let raw = ""; try { for await (const c of process.stdin) raw += c; } catch { process.exit(0); }
let input; try { input = JSON.parse(raw); } catch { process.exit(0); }
if (!input?.session_id) process.exit(0);
const token = process.env.TEAMPING_TOKEN ?? "";
const base = process.env.TEAMPING_BASE || "https://teamping.dev";
if (!token) process.exit(0);
try {
  await fetch(`${base}/api/hooks/sessionend`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    // sent_at: 보낸 시각. 같은 대화를 이어 연(--resume) 뒤 이 종료 알림이 늦게 도착해도
    //   이어 연 뒤에 잡은 잠금은 풀리지 않게 한다.
    body: JSON.stringify({ session_id: input.session_id, sent_at: new Date().toISOString(), window_id: process.env.TEAMPING_WINDOW_ID || undefined }),
    signal: AbortSignal.timeout(2000),
  });
} catch { /* 통과 */ }
process.exit(0);
'
exit 0
