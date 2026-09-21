#!/bin/bash
# 팀핑 플러그인 — 「이 창」의 식별자(0.2.17). 다른 훅 스크립트가 `. "$(dirname "$0")/window-id.sh"` 로 읽어 TEAMPING_WINDOW_ID 를 얻는다.
#
# 왜 있나: 같은 대화를 두 창에서 `--resume` 하면 session_id 가 같아 서버가 창을 못 갈랐다 — 창 A 를 닫으면 B 가 잡은 파일 잠금까지
#   조용히 풀렸다. 서버는 이제 「자기 창의 잠금만 푼다」. 그러려면 창마다 다른 값이 필요하다.
# 무엇으로 만드나(실측 · 2026-09-21): 훅 환경에 CLAUDE_PID(= 이 창의 클로드 프로세스)가 있다.
#   그 pid : 그 프로세스의 시작 시각 → 해시 16자. 같은 창의 Start·편집·End 가 같은 값을 내고, 창이 다르면(pid 재사용 뒤에도
#   시작 시각이 달라) 다른 값이다. 값에 사람·명령어·경로는 없다.
# ⛔ CLAUDE_PID 가 없으면 **빈 값**(서버가 창을 모르는 것으로 보고 전처럼 동작 = fail-open). $PPID 로 대신하지 않는다 — 러너가 훅을
#   어떻게 싸느냐에 따라 훅마다 다른 pid 가 나와(교차 검증 실측) Start·편집·End 가 서로 다른 창으로 보이고, 그러면 종료가 아무것도
#   못 풀어 전보다 나빠진다. 모르면 모른다고 보내는 쪽이 안전하다.
# 시각은 로케일·시간대에 안 흔들리게 C/UTC 로 읽는다(창이 살아 있는 동안 언어·DST 가 바뀌어도 같은 값). 기계 이름은 넣지 않는다 —
#   네트워크에 따라 바뀌는 값이고(맥은 DHCP 이름), 같은 대화를 두 기계에서 열 일은 없다(세션 기록이 기계 로컬).
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
