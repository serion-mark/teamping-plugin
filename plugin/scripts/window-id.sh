#!/bin/bash
# 팀핑 플러그인 — 「이 창」의 식별자. 다른 훅 스크립트가 `. "$(dirname "$0")/window-id.sh"` 로 읽어 TEAMPING_WINDOW_ID 를 얻는다.
#
# 같은 대화를 두 창에서 이어 열어도(--resume) 창마다 다른 값이 나온다 — 한 창을 닫으면 그 창이 잡은 파일 잠금만 풀린다.
# 값은 이 창의 Claude Code 프로세스(CLAUDE_PID)와 그 시작 시각을 해시한 16자다. 사람·명령어·경로는 담기지 않는다.
# CLAUDE_PID 가 없으면 빈 값이다 — 그때 서버는 창을 구분하지 않고 동작한다.
# 시작 시각은 언어·시간대 설정에 흔들리지 않게 C/UTC 로 읽는다.
TEAMPING_WINDOW_ID=""
if [ -n "${CLAUDE_PID:-}" ]; then
  _tp_start="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$CLAUDE_PID" 2>/dev/null | tr -s ' ')"
  if [ -n "$_tp_start" ]; then
    _tp_raw="${CLAUDE_PID}:${_tp_start}"
    if command -v shasum >/dev/null 2>&1; then
      TEAMPING_WINDOW_ID="$(printf '%s' "$_tp_raw" | shasum -a 256 2>/dev/null | cut -c1-16)"
    elif command -v sha256sum >/dev/null 2>&1; then
      TEAMPING_WINDOW_ID="$(printf '%s' "$_tp_raw" | sha256sum 2>/dev/null | cut -c1-16)"
    fi
  fi
fi
export TEAMPING_WINDOW_ID
