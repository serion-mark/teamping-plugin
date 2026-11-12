# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# 팀핑 플러그인 — Grok Build(xAI) 안에서 돌 때 알아보기. 훅 스크립트가 `.` 으로 불러 쓴다.
#
# Grok Build 는 Claude Code 플러그인을 그대로 읽어 이 훅들을 돌린다(grok 1.0.77 에서 확인).
#   · 입력 = Claude 모양 칸(session_id·tool_name·tool_input.file_path)에 Grok 모양 칸(hookEventName·sessionId·toolName)이 **함께** 온다
#   · 도구 이름이 다르다 — 새 파일 `write` · 고치기 `search_replace` · 셸 `run_terminal_command`(tool_input.command)
#   · 훅 환경에 GROK_HOOK_EVENT · GROK_SESSION_ID 가 있다
# 그래서 Grok 이면 도구 이름만 Claude 이름으로 바꿔 아래 판정을 그대로 쓰고, 기록 이름(agent)은 `grok` 으로 보낸다.
#
# ⛔ 판정은 둘 다 맞을 때만 — 환경(GROK_HOOK_EVENT) **그리고** 입력 최상위의 hookEventName 칸.
#    글자 검사만으로는 안 된다: Claude 가 쓰는 파일 내용에 "hookEventName" 이 들어 있을 수 있다(최상위인지는 node 가 본다).
#    환경만으로도 안 된다: Grok 의 셸 도구에서 띄운 다른 프로그램이 그 환경을 물려받을 수 있다.
# Claude Code 에선 GROK_HOOK_EVENT 가 없어 첫 줄에서 끝난다(node 를 띄우지 않는다 — 빠르기 그대로).
# ─────────────────────────────────────────────────────────────────────────────

# 이 파일이 있는 폴더 — 불러온 그 순간에 정해 둔다(나중에 cd 해도 grok-normalize.mjs 를 찾게).
#   서브셸 없이(문자열만) — Claude Code 에서도 모든 훅이 이 파일을 불러오므로 빠르기를 그대로 둔다.
_TEAMPING_GROK_DIR="${BASH_SOURCE[0]%/*}"
[ "$_TEAMPING_GROK_DIR" = "${BASH_SOURCE[0]}" ] && _TEAMPING_GROK_DIR="."
case "$_TEAMPING_GROK_DIR" in /*) ;; *) _TEAMPING_GROK_DIR="$PWD/$_TEAMPING_GROK_DIR" ;; esac

# teamping_grok_input — INPUT 이 Grok 의 훅 입력이면 도구 이름을 바꾼 INPUT 으로 갈아 끼우고 TEAMPING_AGENT=grok 을 내보낸다.
#   Grok 이 아니면 아무것도 바꾸지 않는다(TEAMPING_AGENT 도 지운다 — 바깥에서 물려받은 값을 믿지 않는다). 언제나 0 을 돌려준다.
teamping_grok_input() {
  unset TEAMPING_AGENT
  [ -n "${GROK_HOOK_EVENT:-}" ] || return 0
  case "$INPUT" in *'"hookEventName"'*) ;; *) return 0 ;; esac
  command -v node >/dev/null 2>&1 || return 0
  local _out
  [ -n "$_TEAMPING_GROK_DIR" ] || return 0
  _out="$(printf '%s' "$INPUT" | node "$_TEAMPING_GROK_DIR/grok-normalize.mjs" 2>/dev/null)" || return 0
  [ -n "$_out" ] || return 0
  INPUT="$_out"
  export TEAMPING_AGENT=grok
  return 0
}
