#!/usr/bin/env bash
# 커밋 전 검사(pre-commit)를 이 레포에 설치한다.
#
# 설치가 별도인 이유: git 훅은 레포마다 로컬 파일(.git/hooks)이라, 커밋에 끼어드는 코드는
# 사용자가 직접 한 번 실행해 넣는다. 플러그인이 몰래 심지 않는다.
#
# 사용: bash plugin/scripts/install-precommit.sh
# 해제: .git/hooks/pre-commit 에서 우리 블록만 지우고 `git config teamping.precommit off`(세션 시작 안내도 멈춘다)
# 막기까지 하려면: git config teamping.blockOnConflict true   (기본은 경고만)
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 블록 모양·설치 상태 판정은 세션 시작 훅과 같은 함수(precommit-block.sh)를 쓴다.
. "$SELF_DIR/precommit-block.sh"
if ! teamping_precommit_path_ok "$SELF_DIR"; then
  echo "플러그인 폴더 경로에 셸 특수문자가 있어 설치하지 않았습니다. / Not installed: the plugin folder path contains shell-special characters."
  exit 1
fi

# core.hooksPath(husky 등)를 쓰는 레포는 건드리지 않는다 — 그 폴더는 저장소에 커밋돼 있을 수 있어,
#   이 기계의 절대경로가 팀 전체 훅 파일에 들어가게 된다. 넣을 줄만 보여 주고 직접 넣게 한다.
if [ -n "$(git config --get core.hooksPath 2>/dev/null || true)" ]; then
  echo "이 레포는 core.hooksPath 로 훅을 관리합니다 — 자동 설치하지 않았습니다. / This repo manages hooks via core.hooksPath — not installed automatically."
  echo "  넣을 줄 / line to add: $(teamping_precommit_block "$SELF_DIR" | sed -n 2p)"
  exit 1
fi

TARGET="$(teamping_precommit_hook_file "$ROOT")"
[ -n "$TARGET" ] || { echo "훅 경로를 찾지 못했습니다(git 2.31 이상 필요). / Could not resolve the hooks path (needs git 2.31+)."; exit 1; }

# 심볼릭 링크 훅·sh 가 아닌 훅은 건드리지 않는다 — 링크는 공용 파일에 이 기계 경로를 쓰게 되고,
#   python 등의 훅에 셸 블록을 넣으면 커밋이 깨진다. 넣을 줄만 보여 주고 직접 고르게 한다.
if ! teamping_precommit_file_ours "$TARGET"; then
  if teamping_precommit_has_block "$TARGET"; then
    # 예전 판이 넣어 둔 블록이 이미 있다 — 자동으로 고치지 않고 바꿀 줄을 알려 준다.
    echo "이 레포의 pre-commit(심볼릭 링크 또는 sh 가 아닌 훅)에 팀핑 블록이 이미 있지만 자동으로 고치지 않습니다 — 블록 안 줄을 이것으로 바꾸세요. / A Teamping block already exists in this pre-commit (symlink or non-sh hook) but won't be updated automatically — replace the line inside the block with:"
  else
    echo "이 레포의 pre-commit 은 심볼릭 링크이거나 sh 계열이 아닌 스크립트라 자동 설치하지 않았습니다. / The pre-commit hook here is a symlink or not a sh-family script — not installed automatically."
  fi
  echo "  넣을 줄 / line to add: $(teamping_precommit_block "$SELF_DIR" | sed -n 2p)"
  exit 1
fi
if [ -e "$TARGET" ] && [ ! -w "$TARGET" ]; then
  # 읽기 전용 훅 — 쓸 수 없으니 설치하지 않았다고 알린다.
  echo "pre-commit 파일에 쓸 수 없습니다(읽기 전용): $TARGET / The pre-commit file is read-only."
  exit 1
fi
mkdir -p "$(dirname "$TARGET")"

# 거절해 두었던 레포에서 다시 켜면 거절 표시를 지운다(이 레포 설정만 · 값이 여럿이어도).
#   전역 값이 남아 있어도 블록이 있으면 상태는 on 이다(상태 판정이 블록을 먼저 본다).
git config --local --unset-all teamping.precommit 2>/dev/null || true

if teamping_precommit_has_block "$TARGET"; then
  teamping_precommit_refresh "$TARGET" "$SELF_DIR"
  if teamping_precommit_is_current "$TARGET" "$SELF_DIR"; then
    echo "이미 설치돼 있습니다(경로를 지금 판으로 맞췄습니다): $TARGET / Already installed (path matches this version)."
    exit 0
  fi
  echo "이미 설치돼 있지만 경로를 지금 판으로 맞추지 못했습니다(파일 권한을 확인하세요): $TARGET / Already installed, but the path could not be updated (check file permissions)."
  exit 1
fi

# 블록은 첫 줄(셔뱅) 바로 아래에 넣는다 — 끝에 덧붙이면 `exec` 로 끝나는 훅(pre-commit 프레임워크·lefthook)에선
#   실행되지 않는다. 기존 훅의 나머지 줄은 바꾸지 않는다.
BLOCK_TEXT="$(teamping_precommit_block "$SELF_DIR")"
if [ ! -f "$TARGET" ]; then
  { printf '#!/usr/bin/env sh\n'; printf '%s\n' "$BLOCK_TEXT"; } > "$TARGET"
  chmod +x "$TARGET"
else
  TMP="$(mktemp "${TARGET}.tp.XXXXXX")"
  trap 'rm -f "$TMP"' EXIT
  cp -p "$TARGET" "$TMP"
  FIRST="$(head -n 1 "$TARGET")"
  case "$FIRST" in
    "#!"*)
      # 첫 줄을 printf 로 다시 쓴다 — 개행 없는 한 줄짜리 훅에서도 블록이 셔뱅 줄에 붙지 않게.
      { printf '%s\n' "$FIRST"; printf '%s\n' "$BLOCK_TEXT"; tail -n +2 "$TARGET"; } > "$TMP" || exit 1
      ;;
    *)
      # 셔뱅 없는 훅(git 은 sh 로 돌린다) · 빈 파일 — 맨 위에.
      { printf '%s\n' "$BLOCK_TEXT"; cat "$TARGET"; } > "$TMP" || exit 1
      ;;
  esac
  mv -f "$TMP" "$TARGET"
  chmod +x "$TARGET"
fi

echo "설치 완료 / Installed: $TARGET"
echo "  · 기본은 경고만 합니다(커밋은 통과). / Warn-only by default (commits go through)."
echo "  · 막으려면 / to block: git config teamping.blockOnConflict true"
echo "  · 끄려면 / to turn off: $TARGET 에서 teamping 블록을 지우고 git config teamping.precommit off"
