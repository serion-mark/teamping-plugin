#!/usr/bin/env bash
# 커밋 전 게이트를 이 레포에 설치한다 (강제 락 C).
#
# 왜 설치가 별도인가: git 훅은 레포마다 로컬 파일(.git/hooks)이라 플러그인이 자동으로 심을 수 없고,
# 심어서도 안 된다 — 남의 레포에 커밋을 막을 수 있는 코드를 몰래 넣는 셈이 된다. 사람이 한 번 누른다.
#
# 사용: bash plugin/scripts/install-precommit.sh
# 해제: rm .git/hooks/pre-commit  (또는 우리 블록만 지운다)
# 막기까지 하려면: git config teamping.blockOnConflict true   (기본은 경고만)
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOK_DIR="$(git rev-parse --git-path hooks)"
TARGET="$HOOK_DIR/pre-commit"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARK="# >>> teamping precommit"

mkdir -p "$HOOK_DIR"

if [ -f "$TARGET" ] && grep -q "$MARK" "$TARGET"; then
  echo "이미 설치돼 있습니다: $TARGET"
  exit 0
fi

# 기존 pre-commit이 있으면 **덮지 않고 덧붙인다** — 남의 훅을 지우는 건 우리 일이 아니다.
if [ ! -f "$TARGET" ]; then
  printf '#!/usr/bin/env sh\n' > "$TARGET"
fi
# ⛔⛔ `|| exit 1` 을 쓰지 마라 (적대검증 BLOCK — 실측 재현):
#   여기 심는 경로는 **플러그인 캐시의 절대경로**다. 플러그인을 지우거나 캐시를 정리하거나
#   실행권한이 사라지면, 그 레포의 **모든 커밋이** "No such file or directory"와 함께 막힌다.
#   precommit-lock.sh 본문은 fail-open을 제1원칙으로 지키는데(서버 다운·타임아웃 전부 통과),
#   그 원칙이 **설치 줄 한 개에서 뒤집혔다.** 팀 도구가 커밋을 벽돌로 만드는 건 가장 비싼 실패다.
#   그래서 파일이 있고 실행 가능할 때만 부르고, 아니면 조용히 넘어간다.
cat >> "$TARGET" <<EOF

$MARK
if [ -x "$SELF_DIR/precommit-lock.sh" ]; then "$SELF_DIR/precommit-lock.sh"; fi
# <<< teamping precommit
EOF
chmod +x "$TARGET"

echo "설치 완료: $TARGET"
echo "  · 기본은 경고만 합니다(커밋은 통과)."
echo "  · 막으려면: git config teamping.blockOnConflict true"
echo "  · 해제:     $TARGET 에서 teamping 블록을 지우세요"
