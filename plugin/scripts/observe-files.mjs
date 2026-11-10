// ─────────────────────────────────────────────────────────────────────────────
// 팀핑 플러그인 — git 저장소가 아닌 폴더에서 「이번 도구가 바꾼 파일」을 찾는다(고친 뒤 기록).
//
// git 을 안 쓰는 팀원(문서·디자인·기획 폴더)도 AI 가 고친 파일이 기록에 남게 한다.
//   · Edit·Write 류 → 도구가 준 그 파일 경로 하나(프로젝트 안일 때만)
//   · Bash         → 수정 시각: 도구가 시작한 때부터 끝난 때 사이에 바뀐 프로젝트 안 파일
//
// 데이터 경계(posttooluse-observe.sh 와 같다):
//   · 보내는 것은 **프로젝트 기준 상대경로**뿐이다. 파일 내용·명령 원문은 읽지도 보내지도 않는다(수정 시각만 본다).
//   · 프로젝트 밖 · 절대경로 · `..` 로 올라가는 경로는 절대 돌려주지 않는다.
//   · 홈 폴더 자체(또는 그 위 · `/`)나 홈 바로 아래 개인 폴더(문서·데스크톱·다운로드 · 클라우드 드라이브 뿌리)를
//     프로젝트로 열었으면 훑지 않는다 — 이 도구와 무관한 문서 이름이 나갈 수 있다. 그때도 Edit 류의 그 파일 경로는 싣는다.
//     홈은 환경 변수 하나에 기대지 않고 여러 곳(os.homedir · 사용자 정보 · HOME · USERPROFILE)에서 함께 본다.
//   · 시간 창은 도구가 돈 시간(최대 2분 — 넘으면 훑지 않는다)이고, 이 세션의 직전 도구가 끝난 뒤부터만 본다.
//   · 숨김 폴더·파일(`.git` · `.env` · `.DS_Store` …)과 의존성·빌드 폴더는 훑지 않는다. 심볼릭 링크는 따라가지 않는다.
//   · 상한: 찾은 파일 200개 · 0.5초 · 본 항목 2만 개 · 깊이 12. 넘으면 거기서 멈춘다(덜 적을 뿐 더 보내지 않는다).
// 아무것도 막지 않는다. 실패하면 빈 목록.
// ─────────────────────────────────────────────────────────────────────────────
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
// 개인 폴더·동기화 폴더 목록은 등록 판정(teamping-folders.mjs)과 같은 것을 쓴다 — 등록은 되는데 스캔은 거부하는 일이 없게.
import { PERSONAL, SYNC_ROOT } from "./teamping-folders.mjs";

/** 훑지 않는 폴더 이름(숨김 폴더는 이름 규칙으로 따로 거른다). */
export const SKIP_DIRS = new Set([
  "node_modules", "bower_components", "vendor", "venv", "env", "__pycache__", "site-packages",
  "dist", "build", "out", "target", "coverage", "tmp", "temp", "Library",
]);

export const LIMITS = Object.freeze({ maxFiles: 200, budgetMs: 500, maxEntries: 20000, maxDepth: 12 });

const realish = (p) => {
  try { return fs.realpathSync.native(p); } catch { return path.resolve(p); }
};

/** 홈 바로 아래의 개인 폴더 — 여기를 통째로 프로젝트로 열었으면 훑지 않는다(이 도구와 무관한 문서가 많다). */

/** 홈 폴더 후보 — 환경 변수 하나에 기대지 않는다(HOME 이 비거나 다를 수 있다: sudo · 컨테이너 · env -i). */
function homeCandidates(given) {
  const out = new Set();
  const add = (h) => { if (typeof h === "string" && h && path.isAbsolute(h)) out.add(realish(h)); };
  add(given);
  try { add(os.homedir()); } catch { /* 없음 */ }
  try { add(os.userInfo().homedir); } catch { /* 없음 */ }
  add(process.env.HOME);
  add(process.env.USERPROFILE);
  return [...out];
}

/** 프로젝트 폴더를 훑어도 되나 — 루트 · 홈 · 홈의 조상 · 홈 바로 아래 개인 폴더 · 클라우드 드라이브 뿌리는 안 된다. */
export function scanRootOk(projectDir, home) {
  if (typeof projectDir !== "string" || !path.isAbsolute(projectDir)) return false;
  // 맥의 데이터 볼륨 경로(`/System/Volumes/Data/…`)는 같은 폴더의 다른 이름이다 — realpath 가 풀지 않으므로 직접 벗긴다
  const dir = realish(projectDir).replace(/^\/System\/Volumes\/Data(?=\/)/, "");
  if (dir === path.parse(dir).root) return false;
  // 사용자 폴더 모양 자체(사용자 폴더들의 부모 바로 아래 · 관리자 홈) — 홈 변수가 틀려도 막는다
  const segs = dir.split(path.sep).filter(Boolean);
  if (segs.length <= 2 && /^(Users|home)$/.test(segs[0] ?? "")) return false;
  if (dir === "/root" || dir === "/var/root") return false;
  for (const h of homeCandidates(home)) {
    if (dir === h || h.startsWith(dir.endsWith(path.sep) ? dir : dir + path.sep)) return false; // 홈 · 그 위
    const rel = path.relative(h, dir);
    if (!rel || rel.startsWith("..") || path.isAbsolute(rel)) continue; // 이 홈 밖
    const parts = rel.split(path.sep);
    if (parts.length === 1 && PERSONAL.test(parts[0])) return false; // ~/Documents 같은 개인 폴더 뿌리
    if (parts.length === 2 && SYNC_ROOT.test(parts[0]) && PERSONAL.test(parts[1])) return false; // ~/OneDrive/Documents
    // ~/Library(맥 앱 자료) · iCloud · CloudStorage(구글 드라이브·원드라이브…)의 뿌리 — 드라이브 안 `My Drive` 같은 한 단계까지
    if (parts[0] === "Library" && parts.length <= (parts[1] === "CloudStorage" ? 4 : 3)) return false;
  }
  try { return fs.statSync(dir).isDirectory(); } catch { return false; }
}

/**
 * 도구가 준 파일 경로를 프로젝트 기준 상대경로로 — 프로젝트 밖이면 null.
 * 링크 경로(/tmp ↔ /private/tmp 같은)도 같은 폴더로 본다.
 */
export function relInProject(projectDir, file, cwd = null) {
  if (typeof projectDir !== "string" || !projectDir || typeof file !== "string" || !file) return null;
  if (file.includes("\0")) return null;
  const base = typeof cwd === "string" && path.isAbsolute(cwd) ? cwd : projectDir;
  const abs = path.isAbsolute(file) ? path.normalize(file) : path.resolve(base, file);
  const tries = [[projectDir, abs]];
  // 파일이 지워졌어도 부모 폴더는 있을 수 있다 — 부모의 실제 경로 + 이름
  const realAbs = (() => {
    try { return fs.realpathSync.native(abs); } catch { /* 없음 */ }
    try { return path.join(fs.realpathSync.native(path.dirname(abs)), path.basename(abs)); } catch { return abs; }
  })();
  tries.push([realish(projectDir), realAbs]);
  for (const [root, p] of tries) {
    const rel = path.relative(root, p);
    if (!rel || rel === ".." || rel.startsWith(".." + path.sep) || path.isAbsolute(rel)) continue;
    return rel.split(path.sep).join("/");
  }
  return null;
}

/**
 * 수정 시각이 [since, until](ms) 안인 프로젝트 안 파일들. 상한을 넘으면 거기서 멈춘다.
 * @returns {{files: string[], truncated: boolean}}
 */
export function scanChangedSince(projectDir, since, until, opts = {}) {
  const lim = { ...LIMITS, ...opts };
  const now = typeof opts.now === "function" ? opts.now : Date.now;
  const out = { files: [], truncated: false };
  if (!Number.isFinite(since) || !Number.isFinite(until) || until < since) return out;
  if (!scanRootOk(projectDir, opts.home)) return out;
  const root = realish(projectDir);
  const started = now();
  let seen = 0;
  const stack = [[root, 0]];
  while (stack.length) {
    const [dir, depth] = stack.pop();
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { continue; }
    for (const e of entries) {
      if (++seen > lim.maxEntries || now() - started > lim.budgetMs) { out.truncated = true; return out; }
      const name = e.name;
      if (name.startsWith(".")) continue; // 숨김 — .git · .env · .DS_Store …
      if (e.isSymbolicLink()) continue;    // 링크는 따라가지 않는다(프로젝트 밖으로 나갈 수 있다)
      const full = path.join(dir, name);
      if (e.isDirectory()) {
        if (!SKIP_DIRS.has(name) && depth + 1 < lim.maxDepth) stack.push([full, depth + 1]);
        continue;
      }
      if (!e.isFile()) continue;
      let m;
      try { m = fs.lstatSync(full).mtimeMs; } catch { continue; }
      if (m < since || m > until) continue;
      const rel = path.relative(root, full);
      if (!rel || rel.startsWith("..") || path.isAbsolute(rel)) continue; // 이중 방어
      out.files.push(rel.split(path.sep).join("/"));
      if (out.files.length >= lim.maxFiles) { out.truncated = true; return out; }
    }
  }
  return out;
}

/** 이 세션에서 직전 도구가 끝난 시각(ms)을 읽고 지금 시각으로 바꿔 둔다 — 직전 도구가 바꾼 파일을 이번 몫으로 적지 않게. */
export function takeLastAt(file, now) {
  let last = null;
  try {
    const v = JSON.parse(fs.readFileSync(file, "utf8"))?.at;
    if (typeof v === "number" && Number.isFinite(v) && v <= now) last = v;
  } catch { /* 처음 */ }
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    const tmp = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify({ at: now }), { mode: 0o600 });
    fs.renameSync(tmp, file);
  } catch { /* 못 쓰면 다음에 창이 조금 넓을 뿐 */ }
  return last;
}

/** 편집 도구들 — 도구가 준 파일 경로 하나만 싣는다. */
const EDIT_TOOLS = /^(Edit|Write|MultiEdit|NotebookEdit)$/;
/** 이보다 오래 돈 Bash 는 훑지 않는다 — 창이 길면 이 도구와 무관한 변경(자동 저장·동기화)이 섞인다. */
export const MAX_SCAN_WINDOW_MS = 120_000;

/**
 * git 저장소가 아닌 프로젝트에서 이번 도구가 바꾼 파일.
 * @param {object} ev 훅 입력(PostToolUse) — tool_name · tool_input · duration_ms 만 본다
 * @param {number} hookAt 훅이 시작한 시각(ms)
 * @param {{lastAt?: number|null, home?: string}} opts lastAt = 이 세션의 직전 도구가 끝난 시각(이보다 앞은 안 본다)
 */
export function nonGitChanged(projectDir, ev, hookAt, opts = {}) {
  const tool = String(ev?.tool_name || "");
  const ti = ev?.tool_input && typeof ev.tool_input === "object" ? ev.tool_input : {};
  if (EDIT_TOOLS.test(tool)) {
    const f = typeof ti.file_path === "string" ? ti.file_path : ti.notebook_path;
    const rel = relInProject(projectDir, f, null);
    return rel ? [rel] : [];
  }
  if (tool !== "Bash") return [];
  // 도구가 돈 시간은 Claude Code 가 준다(duration_ms). 없거나(옛 판) 너무 길면 훑지 않는다 — 남의 변경을 이 도구 몫으로 적지 않게.
  const d = ev?.duration_ms;
  if (typeof d !== "number" || !Number.isFinite(d) || d < 0 || d > MAX_SCAN_WINDOW_MS) return [];
  const SLACK = 1000; // 훅이 늦게 뜬 만큼 · 파일 시스템 시각 정밀도 여유
  let since = hookAt - d - SLACK;
  const last = opts.lastAt;
  if (typeof last === "number" && Number.isFinite(last) && last > since && last <= hookAt) since = last;
  return scanChangedSince(projectDir, since, hookAt + SLACK, opts).files;
}
