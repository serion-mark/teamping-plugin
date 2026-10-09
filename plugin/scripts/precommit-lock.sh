#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 팀핑 — 커밋 전 확인.
#
# 커밋에 들어가는 파일(`git diff --cached`) 중 지금 다른 사람이 잡고 있는 파일이 있으면 알려 준다.
#   편집 전 잠금과 별개로, 커밋에 실제로 들어가는 파일을 한 번 더 확인한다.
#
# 기본은 경고만 하고 커밋은 통과한다. 막으려면 `git config teamping.blockOnConflict true`.
# 설치: bash plugin/scripts/install-precommit.sh (기존 pre-commit이 있으면 덮지 않고 덧붙인다)
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# 판단이 안 되면(node 없음 · 토큰 없음 · 서버 응답 없음 · 오류) 커밋을 막지 않는다.
command -v node >/dev/null 2>&1 || exit 0

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$PROJECT_DIR" ] || exit 0

# `core.quotePath` 기본값이면 한글·비ASCII 파일명이 "docs_\353\271\232…" 처럼 나와 잠긴 경로와 맞지 않는다.
#   명시적으로 끈다.
STAGED="$(git -c core.quotePath=false diff --cached --name-only --diff-filter=ACMRD 2>/dev/null)"
[ -n "$STAGED" ] || exit 0

CREDS="$(bash "$(dirname "${BASH_SOURCE[0]}")/resolve-token.sh")"
TOKEN="$(printf '%s\n' "$CREDS" | sed -n 's/^TEAMPING_TOKEN=//p')"
BASE="$(printf '%s\n' "$CREDS" | sed -n 's/^TEAMPING_BASE=//p')"
[ -n "$TOKEN" ] || exit 0

REPO_KEY="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || true)"
[ -n "$REPO_KEY" ] || REPO_KEY="$(basename "$PROJECT_DIR")"

BLOCK="$(git config --bool teamping.blockOnConflict 2>/dev/null || echo false)"

# 「막는다」는 신호 = 이번 실행마다 새로 만든 난수를 node 가 표준 출력에 찍는 것.
#    node 밖의 다른 무언가가 종료코드로 커밋을 막지 못하게 한다. 아래에서 막기 모드일 때만 본다.
NONCE="tp$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
[ "$NONCE" = "tp" ] && NONCE="tp$$${RANDOM:-0}$(date +%s)"
export TEAMPING_TOKEN="$TOKEN" TEAMPING_BASE="$BASE" TEAMPING_REPO_KEY="$REPO_KEY" \
       TEAMPING_STAGED="$STAGED" TEAMPING_BLOCK="$BLOCK" TEAMPING_NONCE="$NONCE"

SIGNAL="$(node --input-type=module -e '
const token = process.env.TEAMPING_TOKEN ?? "";
const base = process.env.TEAMPING_BASE || "https://teamping.dev";
// 파일 목록은 자르지 않고 그대로 보낸다 — 한도를 넘어 확인하지 못한 개수는 서버가 알려 준다.
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

// 아래 전체를 try 로 감싼다 — 서버 응답이 이상해도 오류로 커밋이 막히지 않게.
try {
// 파일 이름이 글자인 항목만 충돌로 센다.
const conflicts = (Array.isArray(data?.conflicts) ? data.conflicts : []).filter((c) => c && typeof c.file === "string" && c.file !== "");
// 확인하지 못한 파일이 있으면 그 사실부터 알린다.
const unchecked = Number(data?.unchecked) || 0;
if (unchecked > 0) {
  process.stderr.write(`\n⚠️ 팀핑 — 파일 ${unchecked}개는 확인하지 못했습니다(한 번에 볼 수 있는 한도를 넘었습니다).\n`);
}
if (!conflicts.length) process.exit(unchecked > 0 ? 0 : 0);

// 잡고 있는 사람 이름·사유는 사람이 쓴 값이고, 이 출력은 커밋을 실행한 AI 에게도 그대로 전달된다.
//   그래서 제어 문자·보이지 않는 글자·줄 구분자를 지우고 길이를 자른다.
const clean = (s) => { try { return String(s ?? "").replace(/[\p{C}\p{Zl}\p{Zp}]+/gu, " ").slice(0, 120); } catch { return "?"; } };
process.stderr.write("\n🔒 팀핑 — 지금 남이 잡고 있는 파일이 커밋에 들어 있습니다\n");
for (const c of conflicts) {
  process.stderr.write(`   · ${clean(c?.file)} — ${clean(c?.holder)}${c?.reason ? ` (${clean(c.reason)})` : ""}\n`);
}
process.stderr.write("\n   먼저 조율하거나, 그 파일을 이번 커밋에서 빼세요(git restore --staged <파일>).\n");
if (process.env.TEAMPING_BLOCK === "true") {
  // 「멈춥니다」 안내는 셸이 실제로 멈추기 직전에 찍는다.
  // 난수를 다 쓴 뒤에 끝낸다 — 바로 exit 하면 파이프에 쓰던 값이 사라질 수 있다.
  await new Promise((r) => process.stdout.write(String(process.env.TEAMPING_NONCE ?? ""), r));
  process.exit(0);
}
process.stderr.write("   (경고만 합니다. 막으려면: git config teamping.blockOnConflict true)\n\n");
process.exit(0);
} catch {
  process.exit(0);
}
')"
# 막기 모드(blockOnConflict=true)이고 node 가 이번 난수를 찍었을 때만 1. 그 밖에는(node 없음 · 오류 · 서버 이상)
#    커밋이 통과한다. 경고 모드는 막지 않는다.
#    끝부분 일치로 본다 — 난수는 node 가 마지막으로 쓰므로 앞에 다른 출력이 섞여도 된다.
if [ "$BLOCK" = "true" ]; then
  case "$SIGNAL" in
    *"$NONCE")
      printf '   ⛔ teamping.blockOnConflict=true 라 커밋을 멈춥니다.\n\n' >&2
      exit 1
      ;;
  esac
fi
exit 0
