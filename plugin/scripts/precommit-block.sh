#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 팀핑 — 커밋 전 확인 블록을 만들고 관리하는 함수 모음.
#
# 처음 설치(`install-precommit.sh`)와 세션 시작 때의 경로 맞추기(`session-context.sh`)가
#   이 파일을 `.` 으로 읽어 같은 함수를 쓴다.
#
# 경로를 맞추는 이유: 심긴 경로는 플러그인 캐시의 판 번호 폴더(…/teamping/<판>/scripts)다.
#   새 판을 받으면 옛 폴더가 지워질 수 있어, 세션을 열 때 블록이 지금 판을 가리키게 고친다.
# ─────────────────────────────────────────────────────────────────────────────

TEAMPING_PRECOMMIT_BEGIN="# >>> teamping precommit"
TEAMPING_PRECOMMIT_END="# <<< teamping precommit"

# 블록 본문(시작·끝 표식 포함)을 찍는다. $1 = precommit-lock.sh 가 있는 폴더(절대경로).
# 플러그인이 지워져도 커밋이 막히지 않게, 파일이 있고 실행 가능할 때만 부른다.
# 경로는 큰따옴표 안에 그대로 들어가므로 `"`·`$`·백틱·역슬래시·개행이 든 경로는 받지 않는다
#   (아무것도 찍지 않고 1 — 설치는 멈추고, 경로 맞추기는 손대지 않는다).
teamping_precommit_path_ok() {
  case "$1" in
    "" | *'"'* | *'$'* | *'`'* | *'\'* | *"
"*) return 1 ;;
  esac
  return 0
}

teamping_precommit_block() {
  teamping_precommit_path_ok "$1" || return 1
  printf '%s\n' "$TEAMPING_PRECOMMIT_BEGIN"
  # `|| exit $?` — 블록이 기존 훅 앞에 들어가므로, 막기로 설정했으면(blockOnConflict) 여기서 끝나야 한다.
  #   `-x` 가 참일 때만 부르므로 플러그인이 없으면 그냥 지나간다.
  printf 'if [ -x "%s/precommit-lock.sh" ]; then "%s/precommit-lock.sh" || exit $?; fi\n' "$1" "$1"
  printf '%s\n' "$TEAMPING_PRECOMMIT_END"
}

# 이 레포의 pre-commit 파일 경로(절대 · 링크를 풀지 않은 이름). 못 구하면 빈 문자열. $1 = 레포 안의 아무 폴더.
#   `--git-path hooks/pre-commit` 은 링크를 풀어 실제 파일을 돌려주므로 링크 훅을 알아보지 못한다.
#   그래서 공통 git 폴더(worktree 도 같은 곳) + 고정 이름으로 만든다.
#   core.hooksPath 를 쓰는 레포는 상태가 custom 이라 이 경로를 쓰지 않는다.
teamping_precommit_hook_file() {
  local common
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  [ -n "$common" ] && printf '%s/hooks/pre-commit\n' "$common"
  return 0
}

# 이 파일에 우리 블록이 있나 — 표식 줄이 정확히 그 줄이어야 한다(경로 맞추기의 awk 와 같은 기준).
teamping_precommit_has_block() {
  [ -f "$1" ] && grep -qxF "$TEAMPING_PRECOMMIT_BEGIN" "$1" 2>/dev/null
}

# 우리가 손댈 수 있는 훅 파일인가 — 없거나, 링크가 아니고 sh 계열 셸 스크립트인 일반 파일.
#   링크(저장소의 scripts/pre-commit · 공용 dotfiles)는 이 기계 경로를 남의 파일에 쓰게 된다.
#   python 등 다른 언어 훅에 셸 블록을 넣으면 커밋이 깨진다.
teamping_precommit_file_ours() {
  local f="$1" first w
  local -a words
  [ -L "$f" ] && return 1
  [ -e "$f" ] || return 0
  [ -f "$f" ] && [ -r "$f" ] || return 1 # 읽을 수 없으면 판단 불가 → 남의 것으로 본다
  first="$(head -n 1 "$f" 2>/dev/null)"
  first="${first%$'\r'}"
  case "$first" in
    "#!"*) ;;
    *)
      # 셔뱅 없음 — git 은 sh 로 돌린다. 단 텍스트일 때만(바이너리 훅에는 넣지 않는다).
      # 빈 파일 · 공백·줄바꿈만 있는 파일도 sh 가 돌리는 빈 스크립트로 본다.
      [ "$(LC_ALL=C tr -d ' \t\r\n' < "$f" 2>/dev/null | wc -c | tr -d ' ')" = "0" ] && return 0
      LC_ALL=C grep -Iq . "$f" 2>/dev/null && return 0
      return 1
      ;;
  esac
  # 해석기 이름만 본다: `#!/bin/sh` · `#! /usr/bin/bash` · `#!/opt/homebrew/bin/bash` · `#!/usr/bin/env -S bash -e`.
  #   `read -a` 로 나눈다 — glob 확장도 없고 호출자의 셸 옵션(noglob)도 건드리지 않는다.
  read -r -a words <<< "${first#\#!}"
  for w in ${words[@]+"${words[@]}"}; do
    case "$w" in -*) continue ;; esac
    case "${w##*/}" in env) continue ;; esac
    case "${w##*/}" in sh | bash | dash | zsh | ksh) return 0 ;; esac
    return 1
  done
  return 1
}

# 이 레포의 커밋 전 확인 상태를 한 단어로 — off · on · declined · custom · none.
#   none     = git 레포가 아니거나 판단 불가(아무 말도 안 한다)
#   on       = 우리가 관리하는 훅 파일에 블록이 있다(→ 경로 맞추기). 거절 설정보다 먼저 본다.
#   custom   = 우리가 손대지 않는 훅(core.hooksPath · 링크 · sh 가 아닌 훅) — 묻지도 고치지도 않는다
#   declined = `git config teamping.precommit off`(불리언 false 면 무엇이든 · 대소문자 무관)
#   off      = 위 어느 것도 아님 → 켤지 물어볼 자리
# $1 = 레포 안의 폴더
teamping_precommit_state() {
  local dir="$1" file
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || { echo none; return; }
  [ -z "$(git -C "$dir" config --get core.hooksPath 2>/dev/null || true)" ] || { echo custom; return; }
  file="$(teamping_precommit_hook_file "$dir")"
  [ -n "$file" ] || { echo none; return; }
  teamping_precommit_file_ours "$file" || { echo custom; return; }
  teamping_precommit_has_block "$file" && { echo on; return; }
  [ "$(git -C "$dir" config --type=bool --get teamping.precommit 2>/dev/null || true)" = "false" ] && { echo declined; return; }
  echo off
}

# 심긴 블록이 가리키는 폴더가 $2 가 아니면 그 블록만 지금 판으로 바꿔 쓴다(블록 밖 남의 훅은 한 글자도 안 건드린다).
# $1 = pre-commit 파일 · $2 = 지금 판의 scripts 폴더. 실패하면 아무것도 바꾸지 않는다.
teamping_precommit_refresh() {
  local file="$1" dir="$2" want tmp
  [ -f "$file" ] && [ -w "$file" ] || return 0
  # 링크·다른 언어 훅은 우리 것이 아니다(상태 판정과 같은 함수).
  teamping_precommit_file_ours "$file" || return 0
  [ -x "$dir/precommit-lock.sh" ] || return 0 # 새 경로에 게이트가 없으면 고치지 않는다(더 나빠지지 않게)
  want="$(teamping_precommit_block "$dir")" || return 0
  # 이미 지금 판이면 쓰기 0
  if awk -v b="$TEAMPING_PRECOMMIT_BEGIN" -v e="$TEAMPING_PRECOMMIT_END" '
       $0 == b { on = 1 } on { print } $0 == e { exit }' "$file" 2>/dev/null | cmp -s - <(printf '%s\n' "$want"); then
    return 0
  fi
  # 같은 폴더의 임시 파일에 다 쓴 뒤 이름 바꾸기로 한 번에 바꾼다 — 덮어쓰다 중간에 실패해도
  #    빈 훅이 남지 않게. 권한은 `cp -p` 로 원본에서 옮긴다.
  tmp="$(mktemp "${file}.tp.XXXXXX" 2>/dev/null)" || return 0
  cp -p "$file" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  # 첫 블록만 바꾼다 — 끝 표식이 없으면(잘린 파일) 손대지 않는다.
  # 새 블록은 `-v` 가 아니라 환경변수로 넘긴다 — macOS awk 는 `-v` 값의 개행을 거부하고
  #    역슬래시를 이스케이프로 읽는다. ENVIRON 은 글자 그대로다.
  if TP_WANT="$want" awk -v b="$TEAMPING_PRECOMMIT_BEGIN" -v e="$TEAMPING_PRECOMMIT_END" '
       done == 0 && $0 == b { skipping = 1; next }
       skipping && $0 == e { print ENVIRON["TP_WANT"]; skipping = 0; done = 1; next }
       skipping { next }
       { print }
       END { if (skipping || !done) exit 3 }' "$file" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$file" 2>/dev/null || true
  fi
  rm -f "$tmp"
  return 0
}

# 이 파일의 첫 블록이 지금 판($2) 그대로인가 — 경로 맞추기가 실제로 됐는지 확인할 때 쓴다.
teamping_precommit_is_current() {
  local want
  want="$(teamping_precommit_block "$2")" || return 1
  awk -v b="$TEAMPING_PRECOMMIT_BEGIN" -v e="$TEAMPING_PRECOMMIT_END" '
    $0 == b { on = 1 } on { print } $0 == e { exit }' "$1" 2>/dev/null | cmp -s - <(printf '%s\n' "$want")
}
