#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 팀핑 플러그인 — 팀핑 연결 토큰과 서버 주소를 찾는다(훅들이 함께 쓴다).
#
# 찾는 순서(먼저 찾은 것을 쓴다 = 프로젝트 설정이 개인 설정보다 앞선다):
#   ① $CLAUDE_PROJECT_DIR/.mcp.json   프로젝트 설정
#   ② ./.mcp.json                     현재 폴더
#   ③ ~/.claude.json                  사용자 설정 — .projects["<프로젝트>"].mcpServers 먼저, 없으면 최상위 .mcpServers
#
# 출력: 훅에게만 `TEAMPING_TOKEN=…`·`TEAMPING_BASE=…` 두 줄을 넘긴다. 못 찾으면 아무것도 출력하지 않고,
#       그때 훅은 조용히 끝난다 — 훅은 사용자 작업을 막지 않는다.
#       ⚠️ 이 스크립트를 터미널에서 직접 실행하면 토큰이 화면에 찍힌다. 직접 실행하지 마세요.
#
# 필요한 것: node(Claude Code 와 함께 설치됨). jq 는 필요 없다.
#
# 캐시: 훅이 도구를 쓸 때마다 불리므로, 찾은 결과를 프로젝트별로 저장해 두고 다시 쓴다.
#   · 위치: ${XDG_CACHE_HOME:-~/.cache}/teamping/tok/ (폴더 0700 · 파일 0600 — 본인만 읽는다)
#   · 설정 파일이 캐시보다 새로우면(토큰을 바꾸거나 지우면) 즉시 다시 찾는다.
#   · 설정 파일이 모두 없으면 캐시를 쓰지 않는다.
#   · 파일 첫 줄에 주인(프로젝트 경로)을 적어 두고 대조한다 — 다른 프로젝트의 토큰을 주지 않는다.
#   · 캐시 파일에는 토큰이 들어 있다. 지워도 안전하다(다음 실행에 다시 만든다).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

TEAMPING_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

# ── 캐시 경로: 프로젝트마다 따로 둔다(워크스페이스마다 다른 토큰을 쓸 수 있다).
_cache_dir="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/teamping/tok"
_safe="${TEAMPING_PROJECT_DIR//\//_}"
_safe="${_safe//[^A-Za-z0-9._-]/_}"
# 경로가 길면 끝 200자만 쓴다.
if [ "${#_safe}" -gt 200 ]; then _safe="${_safe: -200}"; fi
_cache="$_cache_dir/$_safe"
_owner_line="TEAMPING_PROJECT=$TEAMPING_PROJECT_DIR"

# ── 캐시 확인: 설정 파일 중 하나라도 캐시보다 새로우면 다시 찾는다.
if [ -f "$_cache" ] && [ -r "$_cache" ]; then
  _stale=0
  _found_src=0
  _line=""
  for _src in "$TEAMPING_PROJECT_DIR/.mcp.json" "$PWD/.mcp.json" "${HOME:-}/.claude.json"; do
    if [ -e "$_src" ]; then
      _found_src=1
      if [ "$_src" -nt "$_cache" ]; then _stale=1; break; fi
    fi
  done
  # 찾을 설정 파일이 하나도 없으면(연결을 끊었으면) 캐시를 쓰지 않는다.
  [ "$_found_src" -eq 0 ] && _stale=1
  if [ "$_stale" -eq 0 ]; then
    # 끝 개행이 없는 마지막 줄도 읽는다.
    _first=1
    _owner=""
    _body=""
    while IFS= read -r _line || [ -n "$_line" ]; do
      if [ "$_first" -eq 1 ]; then _owner="$_line"; _first=0; else _body="$_body$_line
"; fi
    done < "$_cache"
    # 주인이 다르면(파일 이름이 겹친 다른 프로젝트) 캐시를 쓰지 않고 다시 찾는다.
    if [ "$_owner" = "$_owner_line" ]; then
      printf '%s' "$_body"
      exit 0
    fi
  fi
fi

command -v node >/dev/null 2>&1 || exit 0

_out="$(
TEAMPING_PROJECT_DIR="$TEAMPING_PROJECT_DIR" \
TEAMPING_HOME="${HOME:-}" \
node --input-type=module -e '
const fs = await import("node:fs");
const path = await import("node:path");

const projectDir = process.env.TEAMPING_PROJECT_DIR ?? process.cwd();
const home = process.env.TEAMPING_HOME ?? "";

const read = (p) => { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return null; } };

/** mcpServers 트리에서 teamping 항목을 꺼낸다. .mcp.json과 ~/.claude.json이 같은 모양이라 함수 하나면 된다. */
const pick = (node) => {
  const srv = node?.mcpServers?.teamping;
  if (!srv) return null;
  const token = String(srv?.headers?.Authorization ?? "").replace(/^Bearer\s+/, "").trim();
  if (!token) return null;
  const base = String(srv?.url ?? "https://teamping.dev/mcp").replace(/\/mcp$/, "");
  return { token, base };
};

const candidates = [];
candidates.push(() => pick(read(path.join(projectDir, ".mcp.json"))));
candidates.push(() => pick(read(path.resolve(".mcp.json"))));
if (home) {
  const user = read(path.join(home, ".claude.json"));
  // 프로젝트별 등록이 먼저다 — 워크스페이스마다 다른 토큰을 쓸 수 있다.
  candidates.push(() => pick(user?.projects?.[projectDir]));
  candidates.push(() => pick(user));
}

for (const get of candidates) {
  const found = get();
  if (found) {
    process.stdout.write(`TEAMPING_TOKEN=${found.token}\nTEAMPING_BASE=${found.base}\n`);
    break;
  }
}
'
)"

# ── 캐시 기록. 못 찾은 결과(빈 값)도 적어 둔다.
#    첫 줄에 주인(프로젝트 경로)을 적는다. 임시 파일에 쓴 뒤 rename 해서 반쪽 파일이 안 생긴다.
#    폴더 0700 · 파일 0600(umask 077).
if (umask 077; mkdir -p "$_cache_dir") 2>/dev/null; then
  # 이미 있는 캐시 폴더도 본인만 읽을 수 있게 권한을 맞춘다.
  chmod 700 "$_cache_dir" "${_cache_dir%/*}" 2>/dev/null || true
  # 비정상 종료로 남은 임시 파일을 치운다.
  find "$_cache_dir" -type f -name '*.[0-9]*' -mmin +5 -delete 2>/dev/null || true
  _tmp="$_cache.$$"
  # set -C(noclobber): 이미 있는 파일·심볼릭 링크를 덮어쓰지 않는다. 최종 반영은 mv(rename)다.
  if (set -C; umask 077; printf '%s\n%s\n' "$_owner_line" "$_out" > "$_tmp") 2>/dev/null; then
    mv -f "$_tmp" "$_cache" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
  else
    rm -f "$_tmp" 2>/dev/null
  fi
fi

printf '%s\n' "$_out"
exit 0
