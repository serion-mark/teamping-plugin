#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 팀핑 플러그인 — 팀핑 연결 토큰과 서버 주소를 찾는다(훅들이 함께 쓴다).
#
# 찾는 순서(먼저 찾은 것을 쓴다 = 프로젝트 설정이 개인 설정보다 앞선다):
#   ① $CLAUDE_PROJECT_DIR/.mcp.json   프로젝트 설정
#   ② ./.mcp.json                     현재 폴더
#   ③ ~/.claude.json                  사용자 설정 — .projects["<프로젝트>"].mcpServers 먼저, 없으면 최상위 .mcpServers
#   ⓖ Grok Build 안이면(TEAMPING_AGENT=grok · grok-input.sh) **맨 먼저** ~/.grok/config.toml 의 [mcp_servers.teamping]
#      ($GROK_HOME 이 있으면 그 안 · grok-config.mjs) — Grok 에 넣은 열쇠가 그 Grok 작업의 열쇠다. 그 표가 있는데 못 읽으면 멈춘다.
#      표가 없으면 ③(사용자 본인의 ~/.claude.json)만 본다 — ⛔ Grok 에서는 레포 안 .mcp.json(①②)을 믿지 않는다.
#      캐시도 Claude 와 따로 둔다(파일 이름 끝 __grok) — 같은 폴더에서 Claude 와 Grok 이 서로의 열쇠를 쓰지 않게.
#
# ⭐ 0.2.35 — 로그인 연결: 처음 찾은 teamping 항목에 열쇠(Authorization)가 없고 주소가 `https://<호스트>/mcp` 모양이면
#   Claude Code 가 로그인(OAuth)으로 붙인 연결이다. 그 열쇠는 Claude Code 금고에 있어 훅이 못 쓴다 → 이 레포의 **자동 잠금 열쇠**
#   (~/.config/teamping/hookkey/<레포 키> · hook-key.mjs · 훅 문만 연다)를 쓴다. 거기서 멈춘다 — 아래 범위의 다른 회사 열쇠로 넘어가지 않는다.
#   열쇠 파일이 없으면 토큰 없이 `TEAMPING_KIND=oauth_nokey` 를 넘긴다(세션 시작 훅이 「자동 잠금 켜기」를 안내한다).
#   추가 줄(로그인 연결일 때만 · 복사형 열쇠는 예전 두 줄 그대로): TEAMPING_KIND=hook|oauth_nokey · TEAMPING_HOOK_FILE=<열쇠 파일 경로> · TEAMPING_HOOK_ORIGIN=<설정 주소의 origin>
#   ⛔ 로그인 갈래는 사용자 설정(~/.claude.json)의 항목만 — 레포 안 .mcp.json 의 열쇠 없는 항목은 예전처럼 건너뛴다.
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
_grok_cfg=""
if [ "${TEAMPING_AGENT:-}" = "grok" ]; then
  _safe="${_safe}__grok"
  _grok_cfg="${GROK_HOME:-${HOME:-}/.grok}/config.toml"
fi
_cache="$_cache_dir/$_safe"
_owner_line="TEAMPING_PROJECT=$TEAMPING_PROJECT_DIR"
# Grok 이면 주인 줄에 Grok 설정 경로와 있는지를 함께 적는다 — 그 파일을 지우거나 GROK_HOME 을 바꾸면 캐시를 버리게.
if [ -n "$_grok_cfg" ]; then
  if [ -e "$_grok_cfg" ]; then _owner_line="$_owner_line|GROK_CFG=$_grok_cfg|1"; else _owner_line="$_owner_line|GROK_CFG=$_grok_cfg|0"; fi
fi

# ── 캐시 확인: 설정 파일 중 하나라도 캐시보다 새로우면 다시 찾는다.
if [ -f "$_cache" ] && [ -r "$_cache" ]; then
  _stale=0
  _found_src=0
  _line=""
  for _src in "$TEAMPING_PROJECT_DIR/.mcp.json" "$PWD/.mcp.json" "${HOME:-}/.claude.json" ${_grok_cfg:+"$_grok_cfg"}; do
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
    # 로그인 연결(0.2.35) — 레포별 자동 잠금 열쇠 파일이 캐시 뒤에 생기거나·바뀌거나·지워졌으면 다시 찾는다.
    #   (설정 파일은 안 바뀌어도 열쇠 파일만 바뀐다 — 자동 잠금을 켜면 바로 다음 훅부터 쓰여야 한다.)
    _hf=""; _ht=0
    case "$_body" in *"TEAMPING_TOKEN="*) _ht=1 ;; esac
    while IFS= read -r _line; do
      case "$_line" in TEAMPING_HOOK_FILE=*) _hf="${_line#TEAMPING_HOOK_FILE=}" ;; esac
    done <<EOF_TP
$_body
EOF_TP
    if [ -n "$_hf" ]; then
      if [ -e "$_hf" ]; then
        # 파일이 캐시보다 새로울 때만(생김·바뀜). 「있는데 못 쓰는」 파일(서버 불일치 등) 때문에 훅마다 다시 찾지 않는다.
        #   같은 초(초 단위 시각)도 다시 찾는다 — 「캐시보다 옛것이 아니면」(그 초가 지나면 캐시가 더 새로워져 멈춘다).
        if ! [ "$_hf" -ot "$_cache" ]; then _owner=""; fi
      elif [ "$_ht" -eq 1 ]; then
        _owner=""
      fi
    fi
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
TEAMPING_GROK_CFG="$_grok_cfg" \
TEAMPING_GROKCFG_MJS="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/grok-config.mjs" \
TEAMPING_HOOKKEY_MJS="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/hook-key.mjs" \
node --input-type=module -e '
const fs = await import("node:fs");
const path = await import("node:path");

const projectDir = process.env.TEAMPING_PROJECT_DIR ?? process.cwd();
const home = process.env.TEAMPING_HOME ?? "";

const read = (p) => { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return null; } };

// 로그인 연결의 자동 잠금 열쇠(0.2.35) — 못 읽으면(옛 설치·node 판) 로그인 갈래만 꺼진다(열쇠 갈래는 그대로).
let hk = null;
try {
  const { pathToFileURL } = await import("node:url");
  hk = await import(pathToFileURL(process.env.TEAMPING_HOOKKEY_MJS ?? "").href);
} catch {
  hk = null;
}
/** mcpServers 트리에서 teamping 항목을 꺼낸다. .mcp.json과 ~/.claude.json이 같은 모양이라 함수 하나면 된다. */
const pick = (node, home = false) => {
  const srv = node?.mcpServers?.teamping;
  if (!srv) return null;
  const token = String(srv?.headers?.Authorization ?? "").replace(/^Bearer\s+/, "").trim();
  if (!token) {
    // 열쇠 없는 http 항목 + 팀핑 주소 모양 = 로그인 연결 — 여기서 멈춘다(다른 범위의 열쇠로 넘어가지 않는다).
    // ⛔ 사용자 설정(~/.claude.json · `claude mcp add` 의 local·user)에 있는 항목만 믿는다 — 레포 안 .mcp.json 은 남이 커밋할 수 있다
    //    (그 주소가 자동 잠금 받기의 전송처로 권해지거나 · 열쇠 없는 항목 하나로 사용자 설정의 열쇠를 막지 않게). 레포 쪽은 예전처럼 건너뛴다.
    const url = typeof srv?.url === "string" ? srv.url : "";
    if (home && hk && hk.isConfigUrl(url)) return { oauth: url };
    return null;
  }
  const base = String(srv?.url ?? "https://teamping.dev/mcp").replace(/\/mcp$/, "");
  return { token, base };
};
/** 로그인 연결 → 이 레포의 자동 잠금 열쇠. 값은 stdout(훅이 받는 파이프)으로만. */
const hookLines = (url) => {
  const origin = url.replace(/\/mcp\/?$/, "").toLowerCase(); // 받기 스크립트는 소문자 origin 만 받는다(계약 · 주소 모양은 isConfigUrl 이 이미 걸렀다)
  let repo = null;
  try {
    repo = hk.repoIdentity(projectDir);
  } catch {
    repo = null;
  }
  if (!repo) return `TEAMPING_KIND=oauth_nokey\nTEAMPING_HOOK_ORIGIN=${origin}\n`;
  const file = hk.keyFilePath(repo);
  const f = hk.readKey(repo);
  if (f && hk.sameHookServer(url, f.server)) {
    return `TEAMPING_TOKEN=${f.key}\nTEAMPING_BASE=${f.server}\nTEAMPING_KIND=hook\nTEAMPING_HOOK_FILE=${file}\n`;
  }
  return `TEAMPING_KIND=oauth_nokey\nTEAMPING_HOOK_FILE=${file}\nTEAMPING_HOOK_ORIGIN=${origin}\n`;
};

const candidates = [];
const grokMode = Boolean(process.env.TEAMPING_GROK_CFG);
let grokStop = false;
// Grok Build 안이면(grok-config.mjs) — ①Grok 설정의 [mcp_servers.teamping] 이 그 Grok 작업의 열쇠다.
//   그 표가 있는데 열쇠를 못 읽으면 **멈춘다**(다른 열쇠로 넘어가면 엉뚱한 프로젝트에 잠기는데 아무도 모른다).
//   ②그 표가 없을 때만 사용자 본인의 Claude 설정(~/.claude.json)의 **이 폴더 항목** 또는 로그인 연결(레포별 자동 잠금 열쇠)로.
//   ⛔ ~/.claude.json 최상위의 복사 열쇠는 Grok 에서 쓰지 않는다 — 다른 회사의 열쇠일 수 있어 엉뚱한 곳에 조용히 잠긴다.
//   ⛔ 레포 안 .mcp.json 은 Grok 에서 믿지 않는다
//   (남이 커밋한 파일의 주소·열쇠로 경로가 새는 길 · 로그인 갈래와 같은 규칙).
if (grokMode) {
  let text = null;
  try { text = fs.readFileSync(process.env.TEAMPING_GROK_CFG, "utf8"); } catch (e) {
    text = null;
    // 파일은 있는데 못 읽는다(권한 · 폴더) — 무엇이 들었는지 모르니 넘어가지 않는다
    if (e && e.code !== "ENOENT" && e.code !== "ENOTDIR") grokStop = true;
  }
  if (text !== null) {
    try {
      const { pathToFileURL } = await import("node:url");
      const g = await import(pathToFileURL(process.env.TEAMPING_GROKCFG_MJS ?? "").href);
      const k = g.grokKey(text, process.env);
      if (k) candidates.push(() => k);
      // 팀핑 항목이 있는데 못 읽었다(낯선 모양 · 따옴표 키 · 인라인 표) — 넘어가지 않는다
      else if (g.hasTeampingTable(text)) grokStop = true;
    } catch {
      grokStop = true; // 읽기 모듈을 못 불렀다 — 그 파일에 무엇이 있는지 모르니 넘어가지 않는다
    }
  }
} else {
  candidates.push(() => pick(read(path.join(projectDir, ".mcp.json"))));
  candidates.push(() => pick(read(path.resolve(".mcp.json"))));
}
if (home && !grokStop) {
  const user = read(path.join(home, ".claude.json"));
  // 프로젝트별 등록이 먼저다 — 워크스페이스마다 다른 토큰을 쓸 수 있다.
  candidates.push(() => pick(user?.projects?.[projectDir], true));
  // Grok 에서는 최상위 항목 중 로그인 연결(레포별 자동 잠금 열쇠로 가는 것)만 — 최상위 복사 열쇠는 위 ⛔ 대로 안 쓴다.
  candidates.push(() => {
    const f = pick(user, true);
    return grokMode && f && f.oauth === undefined ? null : f;
  });
}
if (grokStop) candidates.length = 0;

for (const get of candidates) {
  const found = await get();
  if (found) {
    process.stdout.write(found.oauth !== undefined ? hookLines(found.oauth) : `TEAMPING_TOKEN=${found.token}\nTEAMPING_BASE=${found.base}\n`);
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
