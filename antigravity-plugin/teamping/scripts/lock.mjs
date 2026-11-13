#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
// 팀핑 Antigravity 조각 — 파일 잠금.
//
// Antigravity(Google Gemini 의 코딩 도구)의 AI 가 파일을 고치기 직전에 팀핑에 묻는다.
// 다른 사람이 잡고 있으면 편집을 막고 이유를 AI 에게 전한다. 판정은 서버만 한다.
//
// 막을 때만 결정을 낸다({"decision":"deny"}). 그 밖에는 **아무것도 출력하지 않고** 끝낸다 — 권한은 Antigravity 의 평소 규칙이 정한다.
//   ⛔ "allow" 를 내지 않는다: 웹 문서는 「다음 훅·기본 정책으로 넘긴다」, CLI 1.5.7 내장 문서는 「자동 허용」으로 읽혀
//      run_command 의 사람 승인을 건너뛸 수 있다. 어느 뜻이든 안전하게 — 결정을 내지 않는다.
//   ⛔ 빈 JSON({})도 내지 않는다: CLI 1.5.7 에서 {} 는 「pre-tool hook 이 거부」로 처리됐다(write_file·run_command 둘 다).
//      출력이 없으면 그대로 진행됐다(같은 판에서 확인). 그래서 「결정 없음」 = 빈 출력이다.
//
// 입력(Antigravity 1.5.7 에서 확인): conversationId · workspacePaths · cwd · toolCall{ name, args }.
//   편집 도구 write_file(args.Path · Content) · edit_file(args.Path · Target · Replacement) · 셸 run_command(args.CommandLine)
//   MCP 는 call_mcp_tool(args.ServerName · ToolName · Arguments). 대화 끝 이벤트는 없다 — 잠금은 30분 쉬면 풀린다.
// 훅은 플러그인 폴더에서 돈다 — 작업 폴더는 입력(workspacePaths · cwd)으로만 안다.
//
// 열쇠는 사용자가 MCP 연결에 넣은 것을 다시 쓴다 — 내 컴퓨터 전체 설정 두 곳만 읽는다(앞의 것이 먼저):
//   ~/.gemini/config/mcp_config.json(CLI · IDE 문서) → ~/.gemini/antigravity/mcp_config.json(앱 2.0.6 에서 확인).
// ⛔ 프로젝트의 .agents/mcp_config.json 은 읽지 않는다. 남의 레포에서 온 파일일 수 있다.
// 서버로 가는 것은 레포 기준 상대경로·도구 이름·대화 표식뿐이다. 명령 원문·파일 본문·이메일은 보내지 않는다.
// ─────────────────────────────────────────────────────────────────────────────
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const KIND = process.argv[2] ?? "";
const PASS = undefined; // 결정 없음 = 아무것도 출력하지 않는다(allow·{} 를 내지 않는다 — 위 머리말)
const TEAMPING = "https://teamping.dev";
const UUID = /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const SESSION = /^[A-Za-z0-9_-]{1,128}$/;
const SERVER_BUDGET_MS = 2000; // 한 번의 훅이 서버를 기다리는 시간 전부
const SESSION_IDLE_MS = 31 * 60 * 1000; // 서버가 세션을 닫는 30분 뒤 — 살아 있는 세션에 시작을 또 보내면 창이 둘로 세어진다
const PRE_FRESH_MS = 120 * 1000;
const REASON_MAX = 4000;
const LONG_REASON = "Teamping: a teammate's AI is working on this file. (팀핑: 다른 팀원의 AI 가 이 파일을 작업 중이에요.)";
// 편집 도구 — CLI 1.5.7 에서 확인한 이름(write_file · edit_file · 인자 Path) + 공식 hooks 문서의 이름(write_to_file · replace_file_content ·
//   multi_replace_file_content · 인자 TargetFile · 앱(IDE) 쪽으로 보인다 · 아직 직접 재지 못함). 둘 다 받는다 — 한쪽만 받으면 다른 쪽에서 잠금이 조용히 꺼진다.
const EDIT_TOOLS = new Set(["write_file", "edit_file", "write_to_file", "replace_file_content", "multi_replace_file_content"]);
const SHELL_TOOL = "run_command";
const CLAIM = /^(claim_work|claim_file|submit_manifest)$/;

let answered = false;
function answer(out) {
  if (answered) return;
  answered = true;
  if (out === undefined) return; // 결정 없음 — 빈 출력(이 줄이 없어도 stringify(undefined) 가 catch 로 빠져 같지만 우연에 기대지 않는다)
  try { process.stdout.write(JSON.stringify(out)); } catch { /* 끝낸다 */ }
}
function finish(out) {
  answer(out);
  process.exit(0);
}
// Antigravity 가 끊기 전에 스스로 끝낸다. 마지막까지 답이 없으면 통과다.
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

// 작업 폴더 = workspacePaths(절대경로만). cwd 는 AI 의 터미널 위치일 수 있어(하위 폴더) 뿌리로 쓰지 않는다 —
//   뿌리가 하위 폴더가 되면 src/a.ts 가 a.ts 로 잠겨 남의 파일과 키가 섞인다. workspacePaths 가 없을 때만 cwd 를 쓴다.
//   어느 쪽이든 git 레포면 레포 맨 위로 올린다(계약 §2 「레포 루트 기준 상대경로」).
function rootsOf(input) {
  let list = Array.isArray(input.workspacePaths) ? input.workspacePaths.filter((r) => typeof r === "string" && path.isAbsolute(r)) : [];
  if (!list.length && typeof input.cwd === "string" && path.isAbsolute(input.cwd)) list = [input.cwd];
  return list;
}

function toplevel(dir) {
  try {
    const top = execFileSync("git", ["-C", dir, "rev-parse", "--show-toplevel"], {
      encoding: "utf8", timeout: 1000, stdio: ["ignore", "pipe", "ignore"], env: gitEnv(),
    }).trim();
    return top && path.isAbsolute(top) ? top : dir;
  } catch {
    return dir;
  }
}

// 사용자 셸의 GIT_DIR 류가 판정을 남의 저장소로 바꾸지 않게 뺀다(Claude 쪽 repo-key.sh 와 같다)
function gitEnv() {
  return Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^GIT_(DIR|WORK_TREE|INDEX_FILE|COMMON_DIR)$/.test(k)));
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return null; }
}

// 내 컴퓨터 전체 MCP 설정 — CLI(·IDE 문서)의 자리 다음 앱의 자리. **teamping 항목이 있는 첫 곳**에서 멈춘다:
//   그 항목에 열쇠가 없으면(간편 연결) 잠그지 않는다 — 뒤 자리의 열쇠로 넘어가면 MCP 가 연결된 프로젝트와 다른 프로젝트로 잠근다.
const KEY_FILES = [
  [".gemini", "config", "mcp_config.json"],
  [".gemini", "antigravity", "mcp_config.json"],
];

function findKey() {
  for (const parts of KEY_FILES) {
    const config = readJson(path.join(os.homedir(), ...parts));
    const servers = config?.mcpServers;
    if (servers && typeof servers === "object" && Object.hasOwn(servers, "teamping")) return keyIn(config);
  }
  return null;
}

function keyIn(config) {
  const server = config?.mcpServers?.teamping;
  if (server?.disabled === true) return null; // 꺼 둔 연결의 열쇠로는 잠그지 않는다
  const headers = server?.headers;
  if (!headers || typeof headers !== "object") return null; // 열쇠 없는 연결(간편 연결 OAuth)은 훅이 쓸 열쇠가 없다
  const name = Object.keys(headers).find((k) => k.toLowerCase() === "authorization");
  if (!name || typeof headers[name] !== "string") return null;
  const token = headers[name].replace(/^Bearer\s+/i, "").trim();
  if (!token || /\s/.test(token)) return null;
  const raw = typeof server.serverUrl === "string" ? server.serverUrl : server.url;
  let base = TEAMPING;
  if (raw !== undefined) {
    let u;
    try { u = new URL(raw); } catch { return null; }
    // 열쇠는 https 로만 — 평문 http 는 이 컴퓨터 안(127.0.0.1 · localhost · ::1)일 때만(로컬 개발)
    const local = u.hostname === "127.0.0.1" || u.hostname === "localhost" || u.hostname === "[::1]";
    if (!(u.protocol === "https:" || (u.protocol === "http:" && local))) return null;
    base = u.origin;
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

// 레포 표식과 경로의 기준 폴더. git 저장소면 origin(없으면 폴더 이름).
// git 없는 폴더는 사용자가 정해 둔 폴더만(teamping-folders.mjs · `dir:…`) — 아니면 null = 아무것도 안 보낸다.
async function repoOf(root) {
  try {
    const url = execFileSync("git", ["-C", root, "remote", "get-url", "origin"], {
      encoding: "utf8", timeout: 1000, stdio: ["ignore", "pipe", "ignore"], env: gitEnv(),
    }).trim();
    if (url) return { repo: cleanRepoUrl(url), root };
  } catch { /* 아래로 */ }
  try {
    const { resolveFolder } = await import("./teamping-folders.mjs");
    const r = resolveFolder(root);
    if (r.kind === "git") return { repo: path.basename(root), root };
    if (r.kind === "dir") return { repo: r.repoKey, root: r.root };
  } catch { /* 모르면 보내지 않는다 */ }
  return null;
}

function locale() {
  const set = process.env.TEAMPING_LANG;
  if (set === "ko" || set === "en") return set;
  try { return Intl.DateTimeFormat().resolvedOptions().locale.startsWith("ko") ? "ko" : "en"; } catch { return "en"; }
}

// 이 기계의 표식 폴더. 대화 표식은 해시로만 파일 이름에 들어간다.
function marks() {
  const dir = path.join(os.homedir(), ".cache", "teamping", "antigravity");
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  return dir;
}
function markFile(session, name) {
  const id = crypto.createHash("sha256").update(`${session}:${name}`).digest("hex").slice(0, 32);
  return path.join(marks(), id);
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
      redirect: "error", // 다른 곳으로 돌려보내도 따라가지 않는다 — 경로·레포 주소가 남의 서버로 가지 않게
      signal: AbortSignal.timeout(left),
    });
    return await res.json();
  } catch {
    return null;
  }
}

// 대화가 시작 신호 없이 이어져도(플러그인을 나중에 깐 경우) 자리가 있게 한다.
// 표식이 있고 30분 안에 움직였으면 다시 보내지 않는다. ⚠️ 살아 있는 세션에 또 보내면 창이 둘로 세어진다.
async function ensureSession(key, ctx) {
  const file = (() => { try { return markFile(ctx.session, "seat"); } catch { return null; } })();
  let fresh = false;
  try { fresh = !!file && Date.now() - fs.statSync(file).mtimeMs < SESSION_IDLE_MS; } catch { /* 표식 없음 */ }
  if (!fresh) {
    const r = await post(key, "sessionstart", { session_id: ctx.session, repo_key: ctx.repo, agent: "antigravity", window_id: ctx.window });
    if (!r?.ok) return; // 다음 편집이 다시 앉는다
  }
  try { if (file) fs.writeFileSync(file, "", { mode: 0o600 }); } catch { /* 다음에 다시 */ }
}

function args(input) {
  const a = input.toolCall?.args;
  return a && typeof a === "object" && !Array.isArray(a) ? a : {};
}
// 셸의 실행 폴더 — 없으면 undefined(cwd 로 푼다) · 절대경로가 아니면 null(어디서 도는지 모른다 → 잠그지 않는다)
function shellCwd(input) {
  if (input.toolCall?.name !== SHELL_TOOL) return undefined;
  const c = args(input).Cwd;
  if (typeof c !== "string" || !c) return undefined;
  return path.isAbsolute(c) ? c : null;
}

function editedFile(input) {
  const a = args(input);
  const p = typeof a.Path === "string" && a.Path ? a.Path : a.TargetFile;
  return typeof p === "string" && p ? p : null;
}

async function targets(input, root) {
  const tool = input.toolCall?.name;
  let files;
  let cwd = typeof input.cwd === "string" && path.isAbsolute(input.cwd) ? input.cwd : null; // 상대경로를 풀 때만 쓴다(뿌리가 아니다)
  if (tool === SHELL_TOOL) {
    const cmd = args(input).CommandLine;
    if (typeof cmd !== "string" || !cmd) return [];
    const { extractWriteTargets } = await import("./bash-write-targets.mjs");
    files = extractWriteTargets(cmd)?.targets ?? [];
    // 셸은 run_command 의 Cwd 에서 돈다(공식 문서의 인자) — 상대경로를 그 폴더 기준으로 푼다(절대경로일 때만 · 뿌리로는 쓰지 않는다)
    const sc = shellCwd(input);
    if (sc === null) return []; // 상대 Cwd — 잘못 풀어 엉뚱한 파일을 잠그느니 묻지 않는다
    if (sc) cwd = sc;
  } else if (EDIT_TOOLS.has(tool)) {
    const file = editedFile(input);
    files = file ? [file] : [];
  } else {
    return [];
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
      if (!rel) {
        try { rel = (await import("./teamping-folders.mjs")).relToRoot(root, file, cwd); } catch { rel = null; }
      }
    }
    if (rel) out.push(rel);
  }
  return out;
}

// 고친 파일(또는 셸의 실행 폴더)이 든 작업 폴더를 고르고, 그 하나만 레포 맨 위로 올린다(git 은 한 번 — 작업 폴더 수만큼 부르면 시간 상한을 넘긴다).
//   받은 표기로 먼저 맞추고, 안 맞으면 링크를 푼 표기(/var ↔ /private/var)로 한 번 더 맞춘다.
function rootFor(file, roots) {
  if (typeof file === "string" && path.isAbsolute(file)) {
    const pick = (list, f) => list
      .map((r, i) => ({ i, r }))
      .filter(({ r }) => f === r || f.startsWith(r.endsWith(path.sep) ? r : r + path.sep))
      .sort((a, b) => b.r.length - a.r.length)[0];
    const hit = pick(roots, file);
    if (hit) return toplevel(roots[hit.i]);
    const real = (p) => { try { return fs.realpathSync(p); } catch { return p; } };
    // 새 파일은 폴더도 아직 없을 수 있다 — 실제로 있는 가장 가까운 상위 폴더를 풀고 나머지를 붙인다(relToRoot 와 같은 방식)
    const realNearest = (p) => {
      const tail = [];
      let d = p;
      for (let i = 0; i < 256; i++) {
        try { return path.join(fs.realpathSync(d), ...tail); } catch { /* 위로 */ }
        const up = path.dirname(d);
        if (up === d) return p;
        tail.unshift(path.basename(d));
        d = up;
      }
      return p;
    };
    const fileReal = realNearest(file);
    const hit2 = pick(roots.map(real), fileReal);
    if (hit2) return toplevel(roots[hit2.i]);
  }
  return toplevel(roots[0]);
}

async function lockFiles(key, ctx, toolName, paths) {
  return post(key, "pretooluse", {
    session_id: ctx.session,
    window_id: ctx.window,
    agent: "antigravity",
    locale: locale(),
    tool_name: toolName,
    file_path: paths[0],
    file_paths: paths,
    repo_key: ctx.repo,
  });
}

async function preToolUse(input, ctx, key) {
  const paths = await targets(input, ctx.root);
  if (!paths.length) return PASS;
  // 동시에 보낸다(2초 예산 하나). ⚠️ 자리 잡기를 먼저 건다 — 잠금이 먼저 닿으면 시작이 「창 하나 더」로 세어진다.
  const [, data] = await Promise.all([ensureSession(key, ctx), lockFiles(key, ctx, String(input.toolCall?.name ?? "write_file"), paths)]);
  if (data?.decision === "deny" && typeof data.reason === "string") {
    // reason 은 서버가 소독하고 untrusted 표식으로 감싼 문장이다 — 고치지 않고 그대로 AI 에게 전한다.
    //   너무 긴 답은 잘린 JSON 이 되지 않게 고정 문장으로 바꾼다(자르면 untrusted 표식이 깨진다).
    return { decision: "deny", reason: data.reason.length <= REASON_MAX ? data.reason : LONG_REASON };
  }
  if (typeof data?.file === "string") {
    try { fs.writeFileSync(markFile(ctx.session, "pre"), JSON.stringify(paths), { mode: 0o600 }); } catch { /* 편집 뒤 문이 한 번 더 물을 뿐이다 */ }
  }
  return PASS;
}

// 편집 뒤 — 고친 파일을 기록(observe)에 싣고, 편집 전 문을 지나지 않았으면 그때 잠근다. 실패한 도구는 건너뛴다.
async function afterEdit(input, ctx, key) {
  if (typeof input.error === "string" && input.error) return;
  const file = editedFile(input);
  const paths = file ? await relativeTo(ctx.root, [file], typeof input.cwd === "string" && path.isAbsolute(input.cwd) ? input.cwd : null) : [];
  if (!paths.length) return;
  let locked = false;
  try {
    const f = markFile(ctx.session, "pre");
    const seen = JSON.parse(fs.readFileSync(f, "utf8"));
    locked = Date.now() - fs.statSync(f).mtimeMs < PRE_FRESH_MS && paths.every((p) => seen.includes(p));
  } catch { /* 표식 없음 — 묻는다 */ }
  const seat = ensureSession(key, ctx);
  const lock = locked ? null : lockFiles(key, ctx, String(input.toolCall?.name ?? "write_file"), paths);
  const observe = post(key, "observe", {
    session_id: ctx.session,
    window_id: ctx.window,
    agent: "antigravity",
    tool_name: "Edit",
    repo_key: ctx.repo,
    changed: paths,
  });
  await Promise.all([seat, lock, observe]);
}

// 작업 집기 — 서버의 판정은 mcp__<서버>__<도구> 이름만 본다. 팀핑 서버로 부른 claim_work·claim_file 만 알린다.
// ⚠️ submit_manifest(claim:"me")로 만든 카드의 id 는 결과 문장에 있는데, PostToolUse 입력에 결과가 없어 알릴 수 없다.
async function afterMcp(input, ctx, key) {
  if (typeof input.error === "string" && input.error) return;
  const a = args(input);
  if (a.ServerName !== "teamping" || typeof a.ToolName !== "string" || !CLAIM.test(a.ToolName)) return;
  const inner = a.Arguments && typeof a.Arguments === "object" && !Array.isArray(a.Arguments) ? a.Arguments : {};
  const id = a.ToolName === "submit_manifest" ? undefined : inner.manifestId;
  await ensureSession(key, ctx);
  await post(key, "observe", {
    session_id: ctx.session,
    window_id: ctx.window,
    agent: "antigravity",
    tool_name: `mcp__teamping__${a.ToolName}`,
    repo_key: ctx.repo,
    changed: [],
    ...(typeof id === "string" && UUID.test(id) ? { claimed_manifest_id: id } : {}),
  });
}

async function main() {
  const level = process.env.TEAMPING_LEVEL;
  if (level === "lv0" || level === "lv1") return undefined;
  const input = await readStdin();
  if (!input) return undefined;
  const session = input.conversationId;
  if (typeof session !== "string" || !SESSION.test(session)) return undefined;
  const roots = rootsOf(input);
  if (!roots.length) return undefined;
  const root = rootFor(editedFile(input) ?? shellCwd(input) ?? input.cwd, roots); // 셸이면 실행 폴더가 든 작업 폴더
  const key = findKey();
  if (!key) return undefined; // 열쇠가 없으면 조용히 통과 — Antigravity 는 사람에게 보일 칸이 없다
  // 대화마다 고정된 값 — 종료 이벤트가 없어 30분 유휴로 풀리지만, 창 구분은 대화마다 같게.
  const window = crypto.createHash("sha256").update(`antigravity:${session}`).digest("hex").slice(0, 32);
  const where = await repoOf(root);
  if (!where) return undefined;
  const ctx = { session, window, root: where.root, repo: where.repo };
  switch (KIND) {
    case "sessionStart":
      await ensureSession(key, ctx);
      return undefined;
    case "preToolUse":
      return preToolUse(input, ctx, key);
    case "postToolUse": {
      const tool = input.toolCall?.name;
      if (EDIT_TOOLS.has(tool)) await afterEdit(input, ctx, key);
      else if (tool === "call_mcp_tool") await afterMcp(input, ctx, key);
      return undefined;
    }
    default:
      return undefined;
  }
}

main().then(finish, () => finish());
