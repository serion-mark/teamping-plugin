#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
// 팀핑 Cursor 조각 — 파일 잠금.
//
// Cursor AI 가 파일을 고치기 직전에 팀핑에 묻는다. 다른 사람이 잡고 있으면 편집을 막고 이유를 AI 에게 전한다.
// 판정은 서버만 한다.
//
// 어떤 실패도 편집을 막지 않는다. ⚠️ preToolUse 에서 exit 0 + 잘못된 JSON 은 Cursor 가 **막는다** —
//   그래서 무슨 일이 있어도 올바른 JSON 을 내고 끝난다.
//
// 열쇠는 사용자가 MCP 연결에 넣은 것을 다시 쓴다 — ~/.cursor/mcp.json 만 읽는다.
// ⛔ 프로젝트의 .cursor/mcp.json 은 읽지 않는다. 남의 레포에서 온 파일일 수 있고, Cursor 와 달리 훅은 승인을 받지 않는다.
// 서버로 가는 것은 레포 기준 상대경로·도구 이름·대화 id 뿐이다. 명령 원문·파일 본문·이메일은 보내지 않는다.
// ─────────────────────────────────────────────────────────────────────────────
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const KIND = process.argv[2] ?? "";
const ALLOW = { permission: "allow" };
const TEAMPING = "https://teamping.dev";
const UUID = /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const SESSION = /^[A-Za-z0-9_-]{1,128}$/;
const SERVER_BUDGET_MS = 2000; // 한 번의 훅이 서버를 기다리는 시간 전부 — 문이 둘이어도 합쳐서 이만큼이다
const SESSION_IDLE_MS = 31 * 60 * 1000; // 서버가 세션을 닫는 30분 뒤 — 살아 있는 세션에 시작을 또 보내면 창이 둘로 세어진다
const PRE_FRESH_MS = 120 * 1000;

let answered = false;
function answer(out) {
  if (answered) return;
  answered = true;
  const fallback = KIND === "preToolUse" ? ALLOW : {};
  try { process.stdout.write(JSON.stringify(out ?? fallback)); } catch { /* 끝낸다 */ }
}
function finish(out) {
  answer(out);
  process.exit(0);
}
// Cursor 가 끊기 전에 스스로 끝낸다. 마지막까지 답이 없으면 통과다.
setTimeout(() => finish(), 5000).unref();

async function readStdin() {
  try {
    let raw = "";
    for await (const chunk of process.stdin) raw += chunk;
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function rootsOf(input) {
  const list = Array.isArray(input.workspace_roots) ? input.workspace_roots.filter((r) => typeof r === "string" && r) : [];
  const project = process.env.CURSOR_PROJECT_DIR;
  if (project && !list.includes(project)) list.push(project);
  return list;
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return null; }
}

function findKey() {
  const config = readJson(path.join(os.homedir(), ".cursor", "mcp.json"));
  const server = config?.mcpServers?.teamping;
  const headers = server?.headers;
  if (!headers || typeof headers !== "object") return null;
  const name = Object.keys(headers).find((k) => k.toLowerCase() === "authorization");
  if (!name || typeof headers[name] !== "string") return null;
  const value = headers[name].replace(/\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}/g, (_, v) => process.env[v] ?? "");
  const token = value.replace(/^Bearer\s+/i, "").trim();
  if (!token) return null;
  let base = TEAMPING;
  if (server.url !== undefined) {
    try { base = new URL(server.url).origin; } catch { return null; }
    if (base === "null") return null;
  }
  return { token, base };
}

function cleanRepoUrl(url) {
  const plain = url.split(/[?#]/)[0];
  const m = /^([a-z][a-z0-9+.-]*:\/\/)([^/]*@)?(.*)$/i.exec(plain);
  if (!m || !m[2]) return plain;
  if (/^ssh:/i.test(m[1]) && !m[2].includes(":")) return plain; // ssh 사용자 이름(git@)은 비밀이 아니다
  return m[1] + m[3];
}

function repoKey(root) {
  try {
    const url = execFileSync("git", ["-C", root, "remote", "get-url", "origin"], {
      encoding: "utf8", timeout: 1000, stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (url) return cleanRepoUrl(url);
  } catch { /* 폴더 이름으로 */ }
  return path.basename(root);
}

function locale() {
  const set = process.env.TEAMPING_LANG;
  if (set === "ko" || set === "en") return set;
  try { return Intl.DateTimeFormat().resolvedOptions().locale.startsWith("ko") ? "ko" : "en"; } catch { return "en"; }
}

// 이 기계의 표식 폴더. 대화 id 는 해시로만 파일 이름에 들어간다.
function marks() {
  const dir = path.join(os.homedir(), ".cache", "teamping", "cursor");
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  return dir;
}
function markFile(session, name) {
  const id = crypto.createHash("sha256").update(`${session}:${name}`).digest("hex").slice(0, 32);
  return path.join(marks(), id);
}
function once(session, name) {
  try {
    const file = markFile(session, name);
    if (fs.existsSync(file)) return false;
    fs.writeFileSync(file, "", { mode: 0o600 });
  } catch { /* 표식을 못 쓰면 매번 보이는 쪽이 낫다 */ }
  return true;
}

let serverDeadline = 0;

async function post(key, door, body) {
  const lang = locale();
  if (!serverDeadline) serverDeadline = Date.now() + SERVER_BUDGET_MS;
  const left = serverDeadline - Date.now();
  if (left <= 0) return null;
  try {
    const res = await fetch(`${key.base}/api/hooks/${door}`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${key.token}`, "accept-language": lang },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(left),
    });
    return await res.json();
  } catch {
    return null;
  }
}

// 대화가 시작 신호 없이 이어져도(다시 연 대화 · 플러그인을 나중에 깐 경우) 자리가 있게 한다.
// 표식이 있고 30분 안에 움직였으면 다시 보내지 않는다. ⚠️ 살아 있는 세션에 또 보내면 창이 둘로 세어진다.
async function ensureSession(key, ctx) {
  const file = (() => { try { return markFile(ctx.session, "seat"); } catch { return null; } })();
  let fresh = false;
  try { fresh = !!file && Date.now() - fs.statSync(file).mtimeMs < SESSION_IDLE_MS; } catch { /* 표식 없음 */ }
  if (!fresh) {
    const r = await post(key, "sessionstart", { session_id: ctx.session, repo_key: ctx.repo, agent: "cursor", window_id: ctx.window });
    if (!r?.ok) return; // 다음 편집이 다시 앉는다
  }
  try { if (file) fs.writeFileSync(file, "", { mode: 0o600 }); } catch { /* 다음에 다시 */ }
}

function editedFile(input) {
  const ti = input.tool_input;
  return ti?.file_path ?? ti?.path ?? ti?.target_file ?? input.file_path;
}

async function targets(input, root) {
  const tool = input.tool_name;
  const ti = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
  let files;
  let cwd = null;
  if (tool === "Shell") {
    if (typeof ti.command !== "string" || !ti.command) return [];
    const { extractWriteTargets } = await import("./bash-write-targets.mjs");
    files = extractWriteTargets(ti.command)?.targets ?? [];
    if (typeof ti.cwd === "string") cwd = ti.cwd;
  } else {
    const file = editedFile(input);
    files = typeof file === "string" && file ? [file] : [];
  }
  if (!files.length) return [];
  return relativeTo(root, files, cwd);
}

async function relativeTo(root, files, cwd) {
  let trees = null;
  try {
    const mod = await import("./repo-trees.mjs");
    const info = mod.listRepoTrees(root, { timeout: 1500 });
    if (info) trees = { mod, info };
  } catch { /* 세션 폴더만 본다 */ }
  const out = [];
  for (const file of files) {
    let rel = null;
    if (trees) {
      try { rel = trees.mod.resolveInTrees(file, trees.info, cwd)?.rel ?? null; } catch { rel = null; }
    } else {
      const abs = path.isAbsolute(file) ? file : path.resolve(cwd || root, file);
      const r = path.relative(root, abs);
      if (r && !r.startsWith("..") && !path.isAbsolute(r)) rel = r.split(path.sep).join("/");
    }
    if (rel) out.push(rel);
  }
  return out;
}

function rootFor(file, roots) {
  if (typeof file === "string" && path.isAbsolute(file)) {
    const hit = roots
      .filter((r) => file === r || file.startsWith(r.endsWith(path.sep) ? r : r + path.sep))
      .sort((a, b) => b.length - a.length)[0];
    if (hit) return hit;
  }
  return roots[0];
}

const NO_KEY = {
  // i18n-exempt: 열쇠가 없으면 서버 문구를 받을 수 없다 — 바로 아래가 영문.
  ko: "팀핑: 이 편집은 잠기지 않았습니다 — 연결 열쇠를 찾지 못했습니다(~/.cursor/mcp.json 의 teamping 항목). 마이페이지에서 열쇠를 받아 연결하세요.",
  en: "Teamping: this edit was not locked — no connection key found (the teamping entry in ~/.cursor/mcp.json). Issue a key on My page and connect.",
};
// 서버 문장은 넘기지 않는다 — 레포 주소가 섞일 수 있고 Cursor 의 user_message 는 AI 에게 간다. 이유 낱말로 고른 고정 문장만 쓴다.
const NOT_LOCKED = {
  // i18n-exempt: 서버 문장을 쓰지 않으려고 둔 고정 문구 — 바로 아래가 영문.
  ko: {
    "no-token": "팀핑: 이 편집은 잠기지 않았습니다 — 연결 열쇠가 무효입니다. 마이페이지에서 열쇠를 다시 받아 주세요.",
    "no-scope": "팀핑: 이 편집은 잠기지 않았습니다 — 이 열쇠로는 잠글 수 없습니다.",
    "no-channel-access": "팀핑: 이 편집은 잠기지 않았습니다 — 이 프로젝트에 접근할 수 없습니다.",
    "unmapped-repo": "팀핑: 이 편집은 잠기지 않았습니다 — 이 레포는 팀핑 프로젝트에 연결되어 있지 않습니다.",
    "rate-limited": "팀핑: 이 편집은 잠기지 않았습니다 — 요청이 너무 많습니다.",
    "lock-capped": "팀핑: 일부 파일이 잠기지 않았습니다 — 동시에 잡을 수 있는 수를 넘었습니다.",
    "lock-budget": "팀핑: 일부 파일이 잠기지 않았습니다 — 잠금 한도를 넘었습니다.",
  },
  en: {
    "no-token": "Teamping: this edit was not locked — the connection key is invalid. Get a new key on My page.",
    "no-scope": "Teamping: this edit was not locked — this key cannot take locks.",
    "no-channel-access": "Teamping: this edit was not locked — you cannot access this project.",
    "unmapped-repo": "Teamping: this edit was not locked — this repository is not connected to a Teamping project.",
    "rate-limited": "Teamping: this edit was not locked — too many requests.",
    "lock-capped": "Teamping: some files were not locked — the limit on held files was reached.",
    "lock-budget": "Teamping: some files were not locked — the lock limit was reached.",
  },
};
const UNCHECKED = {
  // i18n-exempt: 서버 응답의 숫자를 세는 자리 — 바로 아래가 영문.
  ko: (n) => `팀핑: 경로 ${n}개는 확인하지 못했습니다.`,
  en: (n) => `Teamping: ${n} path(s) could not be checked.`,
};

async function lockFiles(key, ctx, input, paths) {
  return post(key, "pretooluse", {
    session_id: ctx.session,
    window_id: ctx.window,
    agent: "cursor",
    locale: locale(),
    tool_name: typeof input.tool_name === "string" ? input.tool_name : "Write",
    file_path: paths[0],
    file_paths: paths,
    repo_key: ctx.repo,
  });
}

async function preToolUse(input, ctx, key) {
  const paths = await targets(input, ctx.root);
  if (!paths.length) return ALLOW;
  // 동시에 보낸다. 차례로 보내면 느린 서버에서 자리 잡기가 시간을 다 먹어 잠금 확인이 영영 안 나간다.
  // ⚠️ 자리 잡기를 먼저 건다 — 잠금이 먼저 닿으면 세션이 살아나 시작이 「창 하나 더」로 세어진다.
  const [, data] = await Promise.all([ensureSession(key, ctx), lockFiles(key, ctx, input, paths)]);
  if (data?.decision === "deny" && typeof data.reason === "string") {
    // 측정: AI 에게 가는 칸은 user_message 다. 판이 바뀔 때를 대비해 agent_message 에도 같은 문장을 넣는다.
    return { permission: "deny", user_message: data.reason, agent_message: data.reason };
  }
  if (typeof data?.file === "string") {
    try { fs.writeFileSync(markFile(ctx.session, "pre"), JSON.stringify(paths), { mode: 0o600 }); } catch { /* 편집 뒤 문이 한 번 더 물을 뿐이다 */ }
  }
  const notes = [];
  const texts = NOT_LOCKED[locale()];
  const why = typeof data?.why === "string" && Object.hasOwn(texts, data.why) ? texts[data.why] : undefined;
  if (why && once(ctx.session, `why:${data.why}`)) notes.push(why);
  if (Number(data?.truncated) > 0) notes.push(UNCHECKED[locale()](Number(data.truncated)));
  return notes.length ? { permission: "allow", user_message: notes.join("\n") } : ALLOW;
}

// 편집 전 문을 지나지 않은 도구로 고쳤어도 그 파일을 잠근다.
async function afterFileEdit(input, ctx, key) {
  const paths = await relativeTo(ctx.root, typeof input.file_path === "string" && input.file_path ? [input.file_path] : [], null);
  if (!paths.length) return;
  try {
    const file = markFile(ctx.session, "pre");
    const seen = JSON.parse(fs.readFileSync(file, "utf8"));
    if (Date.now() - fs.statSync(file).mtimeMs < PRE_FRESH_MS && paths.every((p) => seen.includes(p))) return;
  } catch { /* 표식 없음 — 묻는다 */ }
  await Promise.all([ensureSession(key, ctx), lockFiles(key, ctx, { tool_name: "Write" }, paths)]);
}

// 서버의 작업 집기 판정은 mcp__<서버>__<도구> 이름만 본다.
async function postToolUse(input, ctx, key) {
  const m = /^MCP:(claim_work|claim_file|submit_manifest)$/.exec(String(input.tool_name ?? ""));
  if (!m) return;
  await ensureSession(key, ctx);
  // submit_manifest 는 만든 카드의 id 가 결과 문장에 있다. 이 id 말고 결과는 읽지도 보내지도 않는다.
  const made = m[1] === "submit_manifest" && input.tool_input?.claim === "me"
    ? /\(id ([0-9a-f-]{36})\)/.exec(String(input.tool_output ?? ""))?.[1]
    : undefined;
  const id = m[1] === "submit_manifest" ? made : input.tool_input?.manifestId;
  await post(key, "observe", {
    session_id: ctx.session,
    window_id: ctx.window,
    agent: "cursor",
    tool_name: `mcp__teamping__${m[1]}`,
    repo_key: ctx.repo,
    changed: [],
    ...(typeof id === "string" && UUID.test(id) ? { claimed_manifest_id: id } : {}),
  });
}

async function sessionEnd(ctx, key) {
  try { fs.rmSync(markFile(ctx.session, "seat"), { force: true }); } catch { /* 지나간다 */ }
  await post(key, "sessionend", { session_id: ctx.session, window_id: ctx.window, sent_at: new Date().toISOString() });
}

async function main() {
  const level = process.env.TEAMPING_LEVEL;
  if (level === "lv0" || level === "lv1") return undefined;
  const input = await readStdin();
  if (!input) return undefined;
  const session = input.conversation_id ?? input.session_id;
  if (typeof session !== "string" || !SESSION.test(session)) return undefined;
  const roots = rootsOf(input);
  if (!roots.length) return undefined;
  const root = rootFor(editedFile(input) ?? input.tool_input?.cwd, roots);
  const key = findKey();
  if (!key) {
    if (KIND === "preToolUse" && once(session, "no-key")) return { permission: "allow", user_message: NO_KEY[locale()] };
    return undefined;
  }
  // 대화마다 고정된 값 — 시작이 두 번 가 창 수가 늘어도 종료가 이 창의 잠금을 풀 수 있다.
  const window = crypto.createHash("sha256").update(`cursor:${session}`).digest("hex").slice(0, 32);
  const ctx = { session, window, root, repo: repoKey(root) };
  switch (KIND) {
    case "sessionStart":
      // 앱을 켤 때 대화가 아닌 짧은 id 로 한 번 더 온다 — 그건 자리가 아니다.
      if (UUID.test(session)) await ensureSession(key, ctx);
      return undefined;
    case "preToolUse":
      return preToolUse(input, ctx, key);
    case "afterFileEdit":
      await afterFileEdit(input, ctx, key);
      return undefined;
    case "postToolUse":
      await postToolUse(input, ctx, key);
      return undefined;
    case "sessionEnd":
      await sessionEnd(ctx, key);
      return undefined;
    default:
      return undefined;
  }
}

main().then(finish, () => finish());
