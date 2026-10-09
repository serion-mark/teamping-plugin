#!/usr/bin/env bash
# 배포를 팀핑에 알린다 — 배포된 커밋에 연결된 작업 카드가 완료로 넘어간다.
#
# 커밋 목록을 보내는 이유: 작업 카드에 적힌 것은 그 작업의 커밋이고, 배포되는 것은 머지 커밋이다.
# 그래서 "이번 배포에 새로 들어온 커밋 전부"를 보낸다.
#
# 쓰는 법 — 배포 파이프라인 **마지막**에 한 줄. 레포 루트에서 실행해야 한다(git 정보를 읽는다).
#   bash "$(ls -d ~/.claude/plugins/cache/teamping/teamping/*/scripts)/notify-deploy.sh" "$PREV_SHA" || true
# 예)
#   · 서버 배포 스크립트: git reset 하기 전 HEAD를 PREV로 넘긴다
#   · GitHub Actions:     - run: bash plugin/scripts/notify-deploy.sh "${{ github.event.before }}" || true
#   · 그 외:              PREV를 모르면 인자 없이 불러도 된다(마지막 커밋 1개만 알린다)
#     · PREV_SHA = git reset 하기 **전**의 HEAD (없으면 마지막 1개 커밋만 보낸다)
#     · `|| true` — 이 알림이 실패해도 배포는 막지 않는다.
#
# 토큰: TEAMPING_TOKEN 환경변수, 없으면 ~/.teamping-token 파일.
# 토큰이 없거나 서버가 응답하지 않으면 아무것도 하지 않고 끝난다.
set -u

BASE="${TEAMPING_BASE:-https://teamping.dev}"
PREV="${1:-}"

# 토큰 찾는 순서: 환경변수 → 전용 파일 → 훅과 같은 탐색기(.mcp.json·~/.claude.json).
# 개발 머신에서 배포한다면 토큰을 따로 두지 않아도 된다.
TOKEN="${TEAMPING_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f "$HOME/.teamping-token" ]; then
  TOKEN="$(tr -d '[:space:]' < "$HOME/.teamping-token")"
fi
if [ -z "$TOKEN" ]; then
  _RESOLVER="$(dirname "${BASH_SOURCE[0]}")/resolve-token.sh"
  if [ -f "$_RESOLVER" ]; then
    _CREDS="$(bash "$_RESOLVER" 2>/dev/null || true)"
    TOKEN="$(printf '%s\n' "$_CREDS" | sed -n 's/^TEAMPING_TOKEN=//p')"
    _B="$(printf '%s\n' "$_CREDS" | sed -n 's/^TEAMPING_BASE=//p')"
    [ -n "$_B" ] && BASE="$_B"
  fi
fi
[ -n "$TOKEN" ] || exit 0

command -v git >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

NOW="$(git rev-parse HEAD 2>/dev/null)" || exit 0
[ -n "$NOW" ] || exit 0

# 레포 식별 — 락 훅과 같은 규칙(origin URL → 없으면 폴더명)이라 같은 채널로 간다.
REPO_KEY="$(git remote get-url origin 2>/dev/null || true)"
[ -n "$REPO_KEY" ] || REPO_KEY="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"

# 이번 배포에 새로 들어온 커밋들. PREV를 모르면 마지막 1개만.
if [ -n "$PREV" ] && git cat-file -e "${PREV}^{commit}" 2>/dev/null; then
  RANGE="${PREV}..${NOW}"
else
  RANGE="-1"
fi
SHAS="$(git log --format=%H "$RANGE" 2>/dev/null | head -200)"
[ -n "$SHAS" ] || exit 0

# JSON 배열 조립 — jq 없이 동작한다. sha는 git이 준 40자 hex라 이스케이프가 필요 없다.
COMMITS="$(printf '%s\n' "$SHAS" | sed 's/.*/"&"/' | paste -sd, -)"
# repo_key는 git remote 설정에서 오므로 따옴표·역슬래시가 섞일 수 있다 — JSON이 깨지지 않게 이스케이프.
REPO_JSON="$(printf '%s' "$REPO_KEY" | sed 's/\\/\\\\/g; s/"/\\"/g')"

# 토큰이 프로세스 목록(ps)에 보이지 않게 헤더를 파일로 넘긴다. 파일은 소유자만 읽고 끝나면 지운다.
HDR="$(mktemp)" || exit 0
trap 'rm -f "$HDR"' EXIT
chmod 600 "$HDR" 2>/dev/null || true
printf 'Authorization: Bearer %s\n' "$TOKEN" > "$HDR"

RESP="$(curl -s --max-time 5 -X POST \
  -H @"$HDR" -H "content-type: application/json" \
  -d "{\"repo_key\":\"$REPO_JSON\",\"deployed_sha\":\"$NOW\",\"commits\":[$COMMITS]}" \
  "$BASE/api/hooks/deployed" 2>/dev/null)" || exit 0

# 배포 로그에 서버 응답을 한 줄 남긴다.
echo "팀핑 배포 알림: ${RESP:-(응답 없음)}"
exit 0
