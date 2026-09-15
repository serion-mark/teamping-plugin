#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 팀핑 플러그인 — 토큰·서버주소 찾기(공용).
#
# ⭐ 왜 공용으로 뺐나: 훅 세 개가 각자 `.mcp.json`만 뒤지고 있었다. 그래서 팀핑을
#    **user 레벨(~/.claude.json)에 한 번 등록한 사용자**는 훅이 토큰을 못 찾아 조용히 통과했고,
#    "붙이려면 레포마다 .mcp.json을 복사해야 한다"는 수작업이 생겼다(실사용에서 지적됨).
#    토큰 하나로 붙였으면 훅도 그 토큰으로 동작해야 한다 — 찾는 곳을 여기 한 곳에서 넓힌다.
#
# 찾는 순서(먼저 찾은 것을 쓴다 = 프로젝트 설정이 개인 설정을 이긴다):
#   ① $CLAUDE_PROJECT_DIR/.mcp.json   프로젝트 전용(팀이 공유하는 설정)
#   ② ./.mcp.json                     훅 cwd
#   ③ ~/.claude.json                  user 레벨 — .projects["<프로젝트>"].mcpServers 먼저, 없으면 최상위 .mcpServers
#
# 출력: TEAMPING_TOKEN·TEAMPING_BASE를 stdout에 `KEY=값` 두 줄로. 못 찾으면 아무것도 출력하지 않는다.
# 호출부는 값이 비면 조용히 exit 0 한다(fail-open 원칙 — 훅은 사람 작업을 막지 않는다).
#
# 의존: node만(Claude Code 필수 요건). jq 불필요 — 훅마다 의존이 달라 낮은 쪽에 맞춘다.
#
# ⭐ 캐시가 있는 이유(실측): 이 스크립트는 훅 5개가 **동기 구간에서** 부른다.
#    node를 새로 띄워 JSON 두어 개를 읽는 데 **p95 48.6ms**가 든다(20회 표본, median 47.4ms).
#    Bash 한 번 = PostToolUse만 = 약 60ms, Edit 한 번 = Pre+Post = node를 두 번 = 약 100ms.
#    Phase 16 게이트가 허용한 값은 **+5ms**였다 — 재보니 12배를 넘었고, 그동안 아무도 안 쟀다.
#    캐시 히트 경로는 프로세스를 **하나도** 띄우지 않는다(전부 bash 내장) → 47ms → ~0ms.
#
# 무효화는 TTL이 아니라 **mtime**이다. 이게 TTL보다 정확하다:
#   · 토큰이 소스에서 지워지면 그 파일 mtime이 새로워져 캐시가 즉시 죽는다.
#   · 소스가 그대로면 캐시 값 == 소스 값이므로 낡을 수가 없다(추가 위험 0).
#   · 못 찾은 결과(빈 값)도 캐시한다 — 안 그러면 미등록 사용자가 매 도구 호출마다 48ms를 낸다.
#   ⚠️ 한계: 소스 파일이 **삭제**되면 비교 대상이 사라져 캐시가 남는다. 그 경우 캐시된 토큰은
#      서버가 거부하고 훅은 조용히 통과한다(fail-open) — 사람 작업을 막지 않는다는 원칙 그대로.
#
# ⚠️ 캐시 파일은 토큰 평문을 담는다. 원본(.mcp.json·~/.claude.json)도 평문이라 새 노출면은
#    아니지만, **원본보다 엄격하게** 둔다: umask 077(파일 0600·디렉토리 0700) + 원자적 rename.
#
# ⭐⭐ 캐시 **파일 안에 주인(프로젝트 경로)을 적고 대조**하는 이유 — 적대검증 BLOCK:
#    파일명은 경로의 비허용 문자를 `_`로 바꿔 만든다. 그런데 그러면 리터럴 `_`와 구분이 사라져
#    **서로 다른 프로젝트가 같은 캐시 파일을 쓴다.** 공격이 아니라 평범한 상황에서 터진다:
#      `~/My Project` 와 `~/My_Project` → 둘 다 `_My_Project` (실측 재현: 후자가 전자의 토큰을 받음)
#    그러면 프로젝트B의 훅이 **프로젝트A의 org·토큰으로 조용히 동작한다**(org 격리 불변식 붕괴).
#    `.mcp.json`은 평소에 mtime이 안 바뀌므로 위의 staleness 검사로는 영영 안 걸린다.
#    ⚠️ 파일명을 해시로 바꾸는 해법은 **쓰지 않았다** — 해시엔 프로세스가 필요해서
#       캐시 히트가 다시 느려지고, 이 변경의 목적(프로세스 0개)이 사라진다.
#    대신 첫 줄에 주인을 적고 대조한다. 충돌하면 **틀린 토큰을 주는 대신 그냥 캐시 미스**가 되어
#    node로 폴백한다 — 정확성은 100%, 손해는 그 드문 경우의 속도뿐이다.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

TEAMPING_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

# ── 캐시 경로: 프로젝트마다 다르다(사람이 워크스페이스마다 다른 토큰을 쓸 수 있다·아래 ⚠️와 같은 이유)
_cache_dir="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/teamping/tok"
_safe="${TEAMPING_PROJECT_DIR//\//_}"
_safe="${_safe//[^A-Za-z0-9._-]/_}"
# ⚠️ `${_safe: -200}` 을 바로 쓰면 안 된다 — 문자열이 200자보다 **짧으면 빈 문자열**이 나오고,
#    그러면 캐시 경로가 디렉토리 자신이 돼 read가 "Is a directory"로 죽는다(실측).
if [ "${#_safe}" -gt 200 ]; then _safe="${_safe: -200}"; fi
_cache="$_cache_dir/$_safe"
_owner_line="TEAMPING_PROJECT=$TEAMPING_PROJECT_DIR"

# ── 캐시 히트: 소스 셋 중 하나라도 캐시보다 새로우면 무효. 여기까지 프로세스 0개.
#    `-f` 를 쓴다 — `-r` 은 디렉토리에도 참이다(위 함정의 짝).
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
  # ⚠️ 소스가 **하나도 없으면** 캐시를 안 쓴다 — 사용자가 .mcp.json을 지워 연결을 끊었는데
  #    캐시된 토큰이 계속 나가는 것을 막는다(적대검증 WARN: 삭제엔 비교 대상이 없어 안 걸렸다).
  [ "$_found_src" -eq 0 ] && _stale=1
  if [ "$_stale" -eq 0 ]; then
    # cat 대신 내장 read — 캐시 히트 경로에서 프로세스를 하나도 띄우지 않기 위해서다.
    # ⚠️ `|| [ -n "$_line" ]` 가 없으면 **끝 개행이 없는 마지막 줄이 통째로 사라진다**
    #    (read가 EOF에서 non-zero를 반환해 본문 실행 전에 루프가 끝난다). 아래 기록부가
    #    개행을 정규화하지만, 손으로 만든 캐시 파일에도 안전하도록 가드를 남긴다.
    _first=1
    _owner=""
    _body=""
    while IFS= read -r _line || [ -n "$_line" ]; do
      if [ "$_first" -eq 1 ]; then _owner="$_line"; _first=0; else _body="$_body$_line
"; fi
    done < "$_cache"
    # 주인이 다르면 파일명이 충돌한 것 — 남의 토큰을 주느니 아래로 떨어져 node로 다시 찾는다.
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
  // ⚠️ 프로젝트별 등록이 먼저다 — 같은 사람이 워크스페이스마다 다른 토큰을 쓸 수 있다.
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

# ── 캐시 기록. 빈 결과도 적는다(미등록 사용자가 매번 node를 띄우지 않게).
#    첫 줄에 **주인**을 적는다 — 파일명이 충돌해도 남의 토큰을 주지 않기 위해서다(위 ⭐⭐ 참조).
#    tmp+rename = 원자적. 훅 여럿이 동시에 끝나도 반쪽짜리 파일을 읽는 일이 없다.
#    `%s\n` 으로 끝 개행을 정규화한다(`$(...)`가 끝 개행을 먹으므로).
#    ⚠️ 정직하게: 개행 정규화는 위 `while read` 가드의 **이중 방어일 뿐**이고, 가드가 있으면
#       없어도 출력은 같다 — 뮤테이션으로 확인했다. 캐시 파일을 사람이나 다른 도구가
#       열어볼 때 온전한 텍스트 파일이게 하려고 남긴다.
#    ⚠️ `umask 077`이 mkdir도 감싼다 — 안 그러면 **디렉토리만 0755로 남아**(적대검증 WARN)
#       다른 로컬 사용자가 `ls`로 프로젝트 경로 목록(=조직·레포 구조 힌트)을 읽는다.
#       파일은 0600이라 토큰 자체는 안 새지만, 주석이 약속한 "원본보다 엄격"에 못 미친다.
if (umask 077; mkdir -p "$_cache_dir") 2>/dev/null; then
  # ⚠️⚠️ `umask 077 + mkdir -p` 만으로는 **이미 있는 디렉토리를 못 고친다** — mkdir는 기존
  #    디렉토리를 재chmod하지 않는다. 그래서 첫 판(umask만 넣은 것)은 **신규 설치만** 보호하고
  #    이미 팀핑을 쓰던 사람은 0755로 남았다(적대검증이 실제 머신에서 0755를 실측했고,
  #    내 회귀 ⑨는 매번 새 tmp에서 돌아 그 상황을 볼 수 없었다 — "고쳤다"와 "실제로 그런가"가
  #    벌어진 자리다). chmod는 idempotent하므로 기존 설치도 다음 실행에 자동 복구된다.
  chmod 700 "$_cache_dir" "${_cache_dir%/*}" 2>/dev/null || true
  # ⚠️ SIGKILL을 맞으면 `.<PID>` tmp가 0600으로 **영구 잔존**한다(적대검증 WARN·재현됨).
  #    무효화 로직은 최종 파일명만 보므로 아무도 안 치운다. `~/.cache`는 OS가 청소하지 않는다.
  #    여기는 이미 node를 띄우는 캐시 미스 경로라 find 한 번의 비용은 무의미하다.
  find "$_cache_dir" -type f -name '*.[0-9]*' -mmin +5 -delete 2>/dev/null || true
  _tmp="$_cache.$$"
  # ⚠️ `set -C`(noclobber)로 기존 파일·심볼릭 링크를 덮어쓰지 않는다. `$_tmp`는 PID 기반이라
  #    예측 가능하고, 셸 리다이렉션은 심링크를 **따라간다**(open(O_CREAT) 의미론) — 미리 심어둔
  #    링크로 토큰이 엉뚱한 파일에 쓰일 수 있다. 최종 목적지는 `mv`(rename)라 안전하다.
  if (set -C; umask 077; printf '%s\n%s\n' "$_owner_line" "$_out" > "$_tmp") 2>/dev/null; then
    mv -f "$_tmp" "$_cache" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
  else
    rm -f "$_tmp" 2>/dev/null
  fi
fi

printf '%s\n' "$_out"
exit 0
