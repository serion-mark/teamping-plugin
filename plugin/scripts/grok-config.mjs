// 팀핑 플러그인 — Grok Build 설정(~/.grok/config.toml)에서 팀핑 열쇠를 읽는다(resolve-token.sh 가 Grok 안에서만 부른다).
//
// 받는 모양(grok 1.0.77 에서 확인 · docs.x.ai/build/settings/reference):
//   [mcp_servers.teamping]
//   url = "https://teamping.dev/mcp"
//   headers = { Authorization = "Bearer teamping_…" }      ← 연결 안내(/connect F)가 주는 모양
// 그리고 같은 뜻의 두 모양도 받는다: [mcp_servers.teamping.headers] 표의 Authorization · bearer_token_env_var = "환경변수 이름".
//
// TOML 전체를 해석하지 않는다 — 이 표의 이 칸들만, 한 줄짜리 따옴표 문자열만. 모르는 모양이면 null(다음 후보로 · 훅은 막지 않는다).
// ⛔ [mcp_servers.teamping] 표가 두 번이면(잘못된 TOML — Grok 도 못 읽는다) 믿지 않는다.
// ⛔ 열쇠·주소 값은 돌려줄 뿐 어디에도 찍지 않는다.

/** 한 줄짜리 따옴표 문자열 — 큰따옴표(이스케이프 없는 것) 또는 작은따옴표(리터럴). */
const STR = String.raw`(?:"([^"\\\n]*)"|'([^'\n]*)')`;
const TAIL = String.raw`\s*(?:#.*)?$`;

function value(line, key) {
  const m = new RegExp(String.raw`^${key}\s*=\s*${STR}${TAIL}`).exec(line);
  return m ? (m[1] ?? m[2]) : null;
}

/**
 * @param {string} text config.toml 원문
 * @param {Record<string, string | undefined>} env bearer_token_env_var 를 풀 환경
 * @returns {{ token: string, base: string } | null}
 */
export function grokKey(text, env = {}) {
  if (typeof text !== "string") return null;
  let table = "";
  let seen = 0;
  let url = null;
  let auth = null;
  let envName = null;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const head = /^\[\s*([^\[\]]+?)\s*\]\s*(?:#.*)?$/.exec(line);
    if (head) {
      table = head[1].replace(/\s+/g, "").replace(/"/g, "");
      if (table === "mcp_servers.teamping") seen++;
      continue;
    }
    if (line.startsWith("[")) {
      table = ""; // [[배열 표]] 등 — 이 표 밖
      continue;
    }
    if (table === "mcp_servers.teamping") {
      url ??= value(line, "url");
      envName ??= value(line, "bearer_token_env_var");
      // 인라인 표 — 다른 헤더가 함께 있어도 Authorization 만 찾는다.
      const inline = new RegExp(String.raw`^headers\s*=\s*\{(.*)\}${TAIL}`).exec(line);
      if (inline) {
        const m = new RegExp(String.raw`(?:^|,)\s*"?Authorization"?\s*=\s*${STR}\s*(?=,|$)`, "i").exec(inline[1].trim());
        if (m) auth ??= m[1] ?? m[2];
      }
    } else if (table === "mcp_servers.teamping.headers") {
      const m = new RegExp(String.raw`^"?Authorization"?\s*=\s*${STR}${TAIL}`, "i").exec(line);
      if (m) auth ??= m[1] ?? m[2];
    }
  }
  if (seen !== 1 || !url || !/^https?:\/\/[^\s"'<>]+$/i.test(url)) return null;
  let token = auth ? auth.replace(/^Bearer\s+/i, "").trim() : "";
  if (!token && envName && /^[A-Za-z_][A-Za-z0-9_]*$/.test(envName)) token = String(env[envName] ?? "").trim();
  if (!token || /\s/.test(token)) return null;
  return { token, base: url.replace(/\/mcp\/?$/, "") };
}

/** 키 한 칸의 이름 — 큰·작은따옴표를 벗긴다. */
const unq = (k) => k.trim().replace(/^"(.*)"$/, "$1").replace(/^'(.*)'$/, "$1");
/** 점으로 이은 키(따옴표 포함)를 칸으로 — `mcp_servers.'teamping'.url` → [mcp_servers, teamping, url]. */
function keyPath(raw) {
  const out = [];
  for (const m of raw.matchAll(/"[^"]*"|'[^']*'|[^.\s]+/g)) out.push(unq(m[0]));
  return out;
}

/**
 * 이 파일에 팀핑 서버 항목이 있나(열쇠를 읽었든 못 읽었든) — 있는데 grokKey 가 null 이면 부르는 쪽이 다른 열쇠로 넘어가지 않는다.
 * `mcp_servers` 아래의 `teamping` 칸만 본다(따옴표 키 · 표 머리 · [mcp_servers] 안의 키 · 점 키 · 인라인 표). 주석 줄은 안 본다.
 * 다른 서버 이름(teamping-local)·경로·주석에 든 낱말은 「있음」이 아니다.
 */
export function hasTeampingTable(text) {
  if (typeof text !== "string") return false;
  let table = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const head = /^\[\[?\s*(.+?)\s*\]\]?\s*(?:#.*)?$/.exec(line);
    if (head) {
      table = keyPath(head[1]);
      if (table[0] === "mcp_servers" && table[1] === "teamping") return true;
      continue;
    }
    const eq = line.indexOf("=");
    if (eq <= 0) continue;
    const key = [...table, ...keyPath(line.slice(0, eq))];
    if (key[0] === "mcp_servers" && key[1] === "teamping") return true;
    // 인라인 표: mcp_servers = { teamping = { … } } · [mcp_servers] 아래 다른 키의 인라인은 안 본다
    if (key.length === 1 && key[0] === "mcp_servers" && /[{,]\s*["']?teamping["']?\s*=/.test(line.slice(eq + 1))) return true;
  }
  return false;
}
