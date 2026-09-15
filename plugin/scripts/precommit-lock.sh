#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 팀핑 — 커밋 전 게이트 (강제 락 C).
#
# 왜 이게 필요한가 (A만으로는 안 되는 이유):
#   편집 전 차단(A)은 명령 텍스트에서 대상을 뽑을 수 있을 때만 작동한다. 실측(로컬 트랜스크립트
#   1,880건): 경로를 뽑을 수 있는 것이 34.2%, **뽑을 수 없는 회색지대가 25.1%**다
#   (`npm run build` · `python3 fix.py` · `make` — 안에서 무엇을 쓰는지 실행 전엔 원리적으로 모른다).
#   그 25%를 실행 전에 막으면 4명령 중 1개가 걸려 도구가 삭제되고, 흘려보내면 지금까지의 착시다.
#
# ⭐ 그래서 **변경 파일이 확정되는 유일한 지점**에서 한 번 더 본다: 커밋 직전.
#   여기서는 추측이 없다 — `git diff --cached` 가 사실을 말한다.
#
# ⛔ 이것은 A의 대체가 아니라 뒤를 받치는 그물이다.
#   "편집 전 차단"은 이 제품이 파는 명제(헛일하기 전에 방향 맞추기)이고, 커밋 게이트는
#   그 명제가 닿지 못한 자리를 조용하지 않게 만드는 장치다. A를 이걸로 대체하지 마라.
#
# 기본은 **경고(통과)**다. 막으려면 `git config teamping.blockOnConflict true`.
#   왜 기본이 경고인가: 커밋을 막는 도구는 한 번 억울하게 막으면 그날로 제거된다.
#   먼저 보이게 하고, 팀이 원하면 이빨을 준다.
#
# 설치: bash plugin/scripts/install-precommit.sh (기존 pre-commit이 있으면 덮지 않고 덧붙인다)
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# fail-open — 어떤 이유로든 판단이 안 되면 커밋을 막지 않는다(락 훅과 같은 제1원칙).
command -v node >/dev/null 2>&1 || exit 0

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$PROJECT_DIR" ] || exit 0

# ⚠️ `core.quotePath` 기본값(true)이면 한글·비ASCII 파일명이 "docs_\353\271\232…" 로 나온다.
#   락 경로는 훅이 준 진짜 UTF-8이라 **절대 매칭되지 않는다** — 이 레포부터 한글 파일명 투성이다
#   (2차 교차검수 WARN-N9). 명시적으로 끈다.
STAGED="$(git -c core.quotePath=false diff --cached --name-only --diff-filter=ACMRD 2>/dev/null)"
[ -n "$STAGED" ] || exit 0

CREDS="$(bash "$(dirname "${BASH_SOURCE[0]}")/resolve-token.sh")"
TOKEN="$(printf '%s\n' "$CREDS" | sed -n 's/^TEAMPING_TOKEN=//p')"
BASE="$(printf '%s\n' "$CREDS" | sed -n 's/^TEAMPING_BASE=//p')"
[ -n "$TOKEN" ] || exit 0

REPO_KEY="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || true)"
[ -n "$REPO_KEY" ] || REPO_KEY="$(basename "$PROJECT_DIR")"

BLOCK="$(git config --bool teamping.blockOnConflict 2>/dev/null || echo false)"

export TEAMPING_TOKEN="$TOKEN" TEAMPING_BASE="$BASE" TEAMPING_REPO_KEY="$REPO_KEY" \
       TEAMPING_STAGED="$STAGED" TEAMPING_BLOCK="$BLOCK"

node --input-type=module -e '
const token = process.env.TEAMPING_TOKEN ?? "";
const base = process.env.TEAMPING_BASE || "https://teamping.dev";
// ⚠️ 여기서 미리 자르지 마라. 클라가 먼저 200개로 자르면 서버의 "확인 못 한 개수"가 **영원히 0**이 되어
//   절단이 조용해진다(2차 교차검수 BLOCK-N3). 자르는 것도 세는 것도 서버 한 곳에서 한다.
const files = (process.env.TEAMPING_STAGED ?? "").split("\n").map((s) => s.trim()).filter(Boolean);
if (!files.length || !token) process.exit(0);

let data;
try {
  const res = await fetch(`${base}/api/hooks/precommit`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({ file_paths: files, repo_key: process.env.TEAMPING_REPO_KEY }),
    signal: AbortSignal.timeout(3000),
  });
  data = await res.json();
} catch { process.exit(0); } // 서버가 없거나 느리면 커밋을 막지 않는다

const conflicts = Array.isArray(data?.conflicts) ? data.conflicts : [];
// ⭐ 확인하지 못한 파일이 있으면 **그 사실부터** 말한다. 조용한 절단은 "깨끗함"으로 오해된다.
const unchecked = Number(data?.unchecked) || 0;
if (unchecked > 0) {
  process.stderr.write(`\n⚠️ 팀핑 — 파일 ${unchecked}개는 확인하지 못했습니다(한 번에 볼 수 있는 한도를 넘었습니다).\n`);
}
if (!conflicts.length) process.exit(unchecked > 0 ? 0 : 0);

// ⚠️ 홀더 이름·사유는 사람이 쓴 값이다.
//   ⛔ 초판 주석은 "이 출력은 터미널로만 간다(에이전트 컨텍스트가 아님)"고 했는데 **틀렸다**:
//      커밋은 `git commit`을 Bash 도구로 실행하므로 이 stderr가 그대로 에이전트의 다음 턴에 들어간다
//      (적대검증이 실제 pre-commit 훅을 걸어 실증). 서버가 이미 소독해서 주지만
//      여기서도 한 번 더 지운다(심층방어) — \p{C}는 RTL override·zero-width·줄구분자까지 덮는다.
const clean = (s) => String(s ?? "").replace(/[\p{C}\p{Zl}\p{Zp}]+/gu, " ").slice(0, 120);
process.stderr.write("\n🔒 팀핑 — 지금 남이 잡고 있는 파일이 커밋에 들어 있습니다\n");
for (const c of conflicts) {
  process.stderr.write(`   · ${clean(c.file)} — ${clean(c.holder)}${c.reason ? ` (${clean(c.reason)})` : ""}\n`);
}
process.stderr.write("\n   먼저 조율하거나, 그 파일을 이번 커밋에서 빼세요(git restore --staged <파일>).\n");
if (process.env.TEAMPING_BLOCK === "true") {
  process.stderr.write("   ⛔ teamping.blockOnConflict=true 라 커밋을 멈춥니다.\n\n");
  process.exit(1);
}
process.stderr.write("   (경고만 합니다. 막으려면: git config teamping.blockOnConflict true)\n\n");
process.exit(0);
'
exit $?
