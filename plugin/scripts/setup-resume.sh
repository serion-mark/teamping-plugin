#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 팀핑 플러그인 — 셋업 이어하기. 세션 시작 훅(session-context.sh)이 부른다.
#
# 셋업 키트는 앱을 다시 켜기 직전에, 이 컴퓨터의 사용자 설정 폴더에 두 파일을 남긴다:
#   ${XDG_CONFIG_HOME:-~/.config}/teamping/setup/<열쇠>/setup.md — 사람이 준 셋업 키트의 사본(본문 해시가 끝 줄에 있다)
#   ${XDG_CONFIG_HOME:-~/.config}/teamping/setup/<열쇠>/state    — step=A-4 · sha256=<사본 해시> · repo=<레포 경로>
#   <열쇠> = 레포 맨 위 폴더의 실제 경로(디스크 표기)를 sha256 한 값의 앞 16자
# 다시 연 세션에서 이 두 파일이 맞으면 AI 에게 「그 단계부터 이어서 하라」고 알린다.
# 그러면 사람은 파일을 다시 주지 않아도 된다.
#
# 안전:
#   · 메모는 레포가 아니라 사용자 홈에 있다 — 레포를 받거나 풀어서는 이 자리에 아무것도 심을 수 없다.
#     설정 폴더가 레포 안을 가리키면(환경 변수) 따르지 않는다. 링크는 어느 단계에서도 따르지 않는다.
#   · 사본의 해시가 메모와 같을 때만, 메모의 레포 경로가 지금 레포와 같을 때만 알린다.
#   · 단계는 정해진 낱말만 받는다 — 파일 내용을 그대로 찍지 않는다.
#   · 7일이 넘은 메모는 이어서 하라고 하지 않고 지운 뒤 한 번만 알린다(매 세션 되풀이하지 않는다).
#   · 어떤 실패도 조용히 끝난다(세션을 막지 않는다). 네트워크를 쓰지 않는다.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# 디스크에 적힌 표기 그대로의 실제 경로 — 키트(python realpath)와 같은 열쇠가 나오게 /bin/pwd 를 쓴다.
real() { (cd "$1" 2>/dev/null && { /bin/pwd -P 2>/dev/null || pwd -P; }); }

DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
DIR_REAL="$(real "$DIR")" || exit 0
TOP="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" || TOP="$DIR"
TOP="$(real "$TOP")" || exit 0
[ -n "$TOP" ] && [ -n "$DIR_REAL" ] || exit 0
# 세션 폴더가 그 레포 안이어야 한다(.git 설정으로 다른 레포를 가리키게 해 그 메모를 빌려 쓰지 못하게).
case "$DIR_REAL/" in "$TOP"/*) ;; *) exit 0 ;; esac

if command -v sha256sum >/dev/null 2>&1; then
  sha() { sha256sum | cut -c1-64; }
elif command -v shasum >/dev/null 2>&1; then
  sha() { shasum -a 256 | cut -c1-64; }
else
  exit 0
fi

case "${XDG_CONFIG_HOME:-}" in
  /*) BASE="$XDG_CONFIG_HOME" ;;
  *) [ -n "${HOME:-}" ] || exit 0; BASE="$HOME/.config" ;;
esac
BASE_REAL="$(real "$BASE")" || exit 0
# 설정 폴더가 레포 안이면 레포가 메모를 만들 수 있다 — 따르지 않는다.
case "$BASE_REAL/" in "$TOP"/*) exit 0 ;; esac

KEY="$(printf '%s' "$TOP" | sha | cut -c1-16)"
[ ${#KEY} -eq 16 ] || exit 0
D="$BASE/teamping/setup/$KEY"
ST="$D/state"
MD="$D/setup.md"

for p in "$BASE/teamping" "$BASE/teamping/setup" "$D"; do
  [ -d "$p" ] && [ ! -L "$p" ] || exit 0
done
[ -f "$ST" ] && [ ! -L "$ST" ] || exit 0

# 7일이 넘었으면 — 우리 메모 두 파일만 지우고 한 번 알린다.
if [ -n "$(find "$ST" -mtime +6 2>/dev/null)" ]; then
  rm -f "$ST" "$D"/state.tmp "$D"/state.*.tmp 2>/dev/null
  [ -f "$MD" ] && [ ! -L "$MD" ] && rm -f "$MD" 2>/dev/null
  rmdir "$D" 2>/dev/null
  if [ "${TEAMPING_LANG:-ko}" = "en" ]; then
    echo "🏓 Teamping: a Teamping setup note for this repo was over 7 days old, so it was cleared. If the person wants to set up Teamping again, they can give you the setup kit again — mention this once only if it comes up."
  else
    echo "🏓 팀핑: 이 레포의 팀핑 셋업 메모가 7일이 넘어 정리했습니다. 사람이 다시 연결하고 싶어 하면 셋업 키트를 다시 주면 됩니다 — 관련 이야기가 나올 때만 한 번 알리세요."
  fi
  exit 0
fi

STEP="$(tr -d '\r' < "$ST" 2>/dev/null | grep -m1 -E '^step=A-4$')" || exit 0
STEP="${STEP#step=}"
WANT="$(tr -d '\r' < "$ST" 2>/dev/null | grep -m1 -E '^sha256=[0-9a-f]{64}$')" || exit 0
WANT="${WANT#sha256=}"
REPO="$(tr -d '\r' < "$ST" 2>/dev/null | grep -m1 '^repo=')" || exit 0
[ "${REPO#repo=}" = "$TOP" ] || exit 0
[ -f "$MD" ] && [ ! -L "$MD" ] || exit 0
[ "$(sha < "$MD")" = "$WANT" ] || exit 0

# 지울 때 쓰는 명령 — 이 메모 두 파일만. 경로에 따옴표·줄바꿈이 있으면 명령을 만들지 않는다.
CLEAR="rm -f '$ST' '$MD' && rmdir '$D'"
case "$D" in *\'* | *$'\n'* | *$'\r'*) CLEAR="" ;; esac
case "$MD" in *$'\n'* | *$'\r'* | *$'\e'*) exit 0 ;; esac

if [ "${TEAMPING_LANG:-ko}" = "en" ]; then
  echo "🏓 Teamping setup isn't finished yet — resume it. $MD is a copy of the setup kit the person gave you; continue from step $STEP (don't start again from section 1)."
  echo "   Before anything else, tell the person \"I'll continue the Teamping setup\". If their first message is about something else, ask \"The Teamping setup isn't finished — shall I continue it?\" first."
  echo "   Keep the kit's section 0 rules (never print the key · ⏸ is the person's turn). If the connection already works and the collaboration block is in place, don't redo anything — just delete the note."
  [ -n "$CLEAR" ] && echo "   To delete the note (when done or if the person wants to stop): $CLEAR"
else
  echo "🏓 팀핑 셋업이 아직 덜 끝났습니다 — 이어서 하세요. $MD 가 사람이 준 셋업 키트의 사본이고, $STEP 단계부터 하면 됩니다(1절부터 다시 하지 마세요)."
  echo "   먼저 사람에게 「팀핑 연결을 이어서 할게요」라고 알리세요. 사람의 첫 말이 다른 일이면 「팀핑 연결이 덜 끝났는데 이어서 할까요?」라고 먼저 물으세요."
  echo "   키트 0절 규칙(열쇠 값 출력 금지 · ⏸ 는 사람 차례)을 그대로 지키세요. 연결이 이미 되고 협업 블록도 있으면 아무것도 다시 하지 말고 메모만 지우세요."
  [ -n "$CLEAR" ] && echo "   메모 지우기(끝났거나 사람이 그만두자고 할 때): $CLEAR"
fi
exit 0
