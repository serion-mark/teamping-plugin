#!/usr/bin/env bash
# 팀핑 플러그인 — SessionEnd 훅. 이 세션이 잡은 파일 락을 즉시 푼다.
# 안 풀어도 마지막 활동 30분 뒤에 자동 해제되지만, 그동안 동료가 막힌다. 끝냈으면 바로 놓아주는 게 맞다.
# fail-open 원칙 동일 — 어떤 실패도 조용히 exit 0(세션 종료를 막지 않는다).
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
case "$LEVEL" in lv0 | lv1) exit 0 ;; esac
command -v node >/dev/null 2>&1 || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
# ⭐ 토큰·서버주소는 공용 resolver가 찾는다(프로젝트 .mcp.json → user 레벨 ~/.claude.json).
# 레포마다 .mcp.json을 복사하지 않아도 되도록 넓혔다 — 토큰 하나로 붙였으면 훅도 그 토큰으로 돈다.
CREDS="$(bash "$(dirname "${BASH_SOURCE[0]}")/resolve-token.sh")"
TOKEN="$(printf '%s\n' "$CREDS" | sed -n 's/^TEAMPING_TOKEN=//p')"
BASE="$(printf '%s\n' "$CREDS" | sed -n 's/^TEAMPING_BASE=//p')"
[ -n "$TOKEN" ] || exit 0
export TEAMPING_TOKEN="$TOKEN" TEAMPING_BASE="$BASE"
. "$(dirname "$0")/window-id.sh" # 0.2.17 — 이 창의 식별자 · 서버가 이 창의 잠금만 푼다

node --input-type=module -e '
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
    // sent_at(0.2.16): 「보낸 시각」 — 같은 세션 id 로 재개(--resume)한 뒤 이 종료가 늦게·두 번 도착해도
    //   서버가 재개 후 잡은 락은 풀지 않게(서버는 이 값을 좁히는 데만 쓴다 · 옛 서버는 무시).
    body: JSON.stringify({ session_id: input.session_id, sent_at: new Date().toISOString(), window_id: process.env.TEAMPING_WINDOW_ID || undefined }),
    signal: AbortSignal.timeout(2000),
  });
} catch { /* 통과 */ }
process.exit(0);
'
exit 0
