#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 팀핑 플러그인 — 이 창(세션)에 온 팀핑 연락(답장 · 카드 의견 · 확인 등)을 AI 에게 전한다.
#
#   inbox-hook.sh stop    Stop 훅 — 맡아 둔 연락이 있으면 턴을 한 번만 붙잡아 읽게 한다
#   inbox-hook.sh wait    Stop 훅(asyncRewake) — 쉬는 동안 뒤에서 기다리다 연락이 오면 창을 깨운다
#   inbox-hook.sh prompt  UserPromptSubmit 훅 — 맡아 둔 연락을 입력 옆에 넣고, 서버에 한 번 묻는다(뒤에서)
#
# AI 에게 넣는 것은 서버가 만든 한 줄 문장뿐이다(본문 없음). 자동화 세기 lv2 · lv3 에서만 돈다.
# 서버가 응답하지 않거나 오류가 나도 사용자 작업을 막지 않는다 — 조용히 끝난다.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

MODE="${1-}"
LEVEL="${TEAMPING_LEVEL-}"
case "$LEVEL" in
  lv0 | lv1 | lv2 | lv3) ;;
  *) [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && LEVEL="lv2" || LEVEL="lv1" ;;
esac
case "$LEVEL" in lv0 | lv1) exit 0 ;; esac

command -v node >/dev/null 2>&1 || exit 0
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TEAMPING_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

INPUT="$(cat)"
[ -n "$INPUT" ] || exit 0
[ -n "${TEAMPING_HOOK_DEBUG:-}" ] && printf '%s' "$INPUT" | "$HERE/hook-debug.sh" 2>/dev/null

# 이 창 몫으로 맡아 둔 연락이 있나 — 없으면 node 를 띄우지 않는다(대부분의 턴이 여기서 끝난다).
. "$HERE/inbox-pending.sh"
has_pending() { teamping_inbox_has_pending "$INPUT"; }

creds() {
  local c
  c="$(bash "$HERE/resolve-token.sh")"
  TEAMPING_TOKEN="$(printf '%s\n' "$c" | sed -n 's/^TEAMPING_TOKEN=//p')"
  TEAMPING_BASE="$(printf '%s\n' "$c" | sed -n 's/^TEAMPING_BASE=//p')"
  [ -n "$TEAMPING_TOKEN" ] || return 1
  TEAMPING_REPO_KEY="$(git -C "$TEAMPING_PROJECT_DIR" remote get-url origin 2>/dev/null || true)"
  [ -n "$TEAMPING_REPO_KEY" ] || TEAMPING_REPO_KEY="$(basename "$TEAMPING_PROJECT_DIR")"
  export TEAMPING_TOKEN TEAMPING_BASE TEAMPING_REPO_KEY
}

case "$MODE" in
  stop)
    has_pending || exit 0
    printf '%s' "$INPUT" | node "$HERE/inbox-show.mjs" Stop 2>/dev/null
    exit 0
    ;;
  wait)
    creds || exit 0
    # 종료 코드 2 = 창을 깨운다(연락이 왔다). 그 밖에는 0.
    printf '%s' "$INPUT" | node "$HERE/inbox-wait.mjs" wait
    rc=$?
    [ "$rc" -eq 2 ] && exit 2
    exit 0
    ;;
  prompt)
    if has_pending; then printf '%s' "$INPUT" | node "$HERE/inbox-show.mjs" UserPromptSubmit 2>/dev/null; fi
    creds || exit 0
    # 뒤에서 한 번 묻는다 — 입력을 늦추지 않게. 받은 줄은 다음 도구 때 넣는다.
    printf '%s' "$INPUT" | nohup node "$HERE/inbox-wait.mjs" once >/dev/null 2>&1 &
    exit 0
    ;;
esac
exit 0
