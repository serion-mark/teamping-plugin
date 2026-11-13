// ─────────────────────────────────────────────────────────────────────────────
// 팀핑 플러그인 — 이 레포의 작업 폴더(git worktree)가 어디어디인지 git 에게 묻는다.
//
// 세션을 연 폴더(CLAUDE_PROJECT_DIR)뿐 아니라 같은 레포의 다른 작업 폴더에서 고친 파일·커밋도
// 같은 프로젝트로 본다. 어느 작업 폴더에서 고쳐도 같은 파일은 **같은 이름**(예: `app/x.ts`)으로 잠긴다.
//
//   ① 목록은 `git worktree list` 가 알려 준다 — 같은 레포의 작업 폴더만 나오므로 다른 레포의 파일 이름은 섞이지 않는다.
//   ② 한 번 부르면 모든 작업 폴더의 HEAD 도 함께 온다.
//   ③ 경로는 그것이 들어 있는 **가장 깊은** 작업 폴더에 속한다(작업 폴더 안에 작업 폴더가 있을 때).
//   ④ 이름은 그 작업 폴더 안의 「프로젝트 자리」 기준 상대경로다(세션 폴더가 레포의 하위 폴더 `sub/` 면
//      다른 작업 폴더에서도 `<작업폴더>/sub/` 기준).
//   ⑤ git 이 없거나 실패하면 null — 훅은 세션 폴더만 보는 방식으로 돌아간다. 이 모듈은 아무것도 막지 않는다.
// ─────────────────────────────────────────────────────────────────────────────
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

// 작업 폴더가 아주 많아도 훅 비용이 커지지 않게 상한을 둔다.
export const MAX_TREES = 32;

const SHA = /^[0-9a-f]{40}$/;

// 존재하는 가장 깊은 조상까지 실제 경로로 바꾸고 나머지를 붙인다.
// macOS 의 /tmp → /private/tmp 처럼 같은 곳이 두 이름을 가질 수 있어 맞춘다.
// 아직 없는 파일(새로 만들 파일)도 부모 폴더까지는 실제 경로로 맞춘다.
export function realish(p) {
  const abs = path.resolve(p);
  const tail = [];
  let cur = abs;
  for (let i = 0; i < 512; i++) {
    try {
      return path.join(fs.realpathSync.native(cur), ...tail);
    } catch { /* 아직 없다 — 한 칸 위로 */ }
    const parent = path.dirname(cur);
    if (parent === cur) return abs;
    tail.unshift(path.basename(cur));
    cur = parent;
  }
  return abs;
}

// `git worktree list --porcelain -z` 출력을 읽는다(순수 함수).
//   반환: [{ root, head }] (root = 실제 경로 · head = 40자 또는 null)
//   빼는 것: bare 저장소 · prunable(폴더가 사라진 기록) · 경로가 절대경로가 아닌 것.
export function parseWorktreeList(out) {
  const trees = [];
  let cur = null;
  const flush = () => {
    if (cur && cur.root && !cur.bare && !cur.prunable) trees.push({ root: cur.root, head: cur.head });
    cur = null;
  };
  for (const line of String(out ?? "").split("\0")) {
    if (line === "") { flush(); continue; }
    if (line.startsWith("worktree ")) {
      flush();
      const p = line.slice("worktree ".length);
      cur = { root: path.isAbsolute(p) ? p : null, head: null, bare: false, prunable: false };
    } else if (!cur) {
      continue;
    } else if (line.startsWith("HEAD ")) {
      const h = line.slice(5).trim();
      cur.head = SHA.test(h) ? h : null;
    } else if (line === "bare") {
      cur.bare = true;
    } else if (line === "prunable" || line.startsWith("prunable ")) {
      cur.prunable = true;
    }
  }
  flush();
  return trees;
}

// 세션 폴더(projectDir)가 속한 레포의 작업 폴더 전부 + 「프로젝트 자리」(prefix).
//   반환: { trees: [{ id, head, forms }], prefix, home } 또는 null
//     · id    = 실제 경로(상태 파일 열쇠 · git -C 인자)
//     · forms = 그 작업 폴더 루트의 **이름들**(git 이 적은 이름 · 실제 경로 · 세션 폴더가 쓰는 이름) — 중복 제거
//     · home  = 세션 폴더가 들어 있는 작업 폴더
//   이름을 여럿 두는 이유: 같은 폴더가 /tmp 와 /private/tmp 처럼 두 이름으로 불릴 수 있고,
//   프로젝트 안의 심볼릭 링크 파일은 링크 이름 그대로 잠가야 하기 때문이다.
export function listRepoTrees(projectDir, { timeout = 3000 } = {}) {
  if (typeof projectDir !== "string" || !projectDir) return null;
  let out;
  try {
    out = execFileSync("git", ["-C", projectDir, "--no-optional-locks", "worktree", "list", "--porcelain", "-z"], {
      encoding: "utf8", timeout, maxBuffer: 1 << 20, stdio: ["ignore", "pipe", "ignore"],
    });
  } catch { return null; }
  const trees = [];
  for (const t of parseWorktreeList(out)) {
    let real;
    try {
      real = fs.realpathSync.native(t.root); // 폴더가 실제로 있어야 한다(지운 뒤 prune 안 한 기록은 버린다)
    } catch { continue; }
    if (trees.some((x) => x.forms.includes(real))) continue;
    trees.push({ id: real, head: t.head, forms: uniq([path.resolve(t.root), real, ...aliasesOf(real)]) });
  }
  const projLex = path.resolve(projectDir);
  const projReal = realish(projLex);
  let hit = null;
  let proj = null;
  for (const cand of uniq([projReal, projLex])) {
    hit = matchTree(cand, trees);
    if (hit) { proj = cand; break; }
  }
  if (!hit) return null; // 세션 폴더가 어느 작업 폴더에도 안 든다 = 이 목록을 믿을 근거가 없다
  // 상한은 세션 폴더를 찾은 뒤 건다 — 세션 폴더는 항상 목록에 남는다.
  if (trees.length > MAX_TREES) {
    const rest = trees.filter((t) => t !== hit.tree).slice(0, MAX_TREES - 1);
    trees.length = 0;
    trees.push(hit.tree, ...rest);
  }
  const prefixRel = path.relative(hit.form, proj);
  if (prefixRel.startsWith("..") || path.isAbsolute(prefixRel)) return null;
  const prefix = prefixRel ? prefixRel.split(path.sep).join("/") : "";
  // 세션 폴더가 쓰는 이름(CLAUDE_PROJECT_DIR 글자 그대로)에서 prefix 를 떼면 home 의 또 다른 이름이다.
  const upLex = prefix ? path.resolve(projLex, ...prefix.split("/").map(() => "..")) : projLex;
  hit.tree.forms = uniq([upLex, ...hit.tree.forms]);
  return { trees, prefix, home: hit.tree };
}

function uniq(a) {
  return [...new Set(a)];
}

// 파일 시스템 맨 위의 링크(macOS 의 /tmp → /private/tmp · /var → /private/var)로 부를 수 있는 다른 이름들.
//   명령에는 사람이 친 이름이 그대로 적히므로 그 이름으로도 알아본다. 맨 위 한 층만 본다.
let rootLinks;
function aliasesOf(real) {
  if (rootLinks === undefined) {
    rootLinks = [];
    try {
      const top = path.parse(real).root;
      for (const name of fs.readdirSync(top)) {
        const link = path.join(top, name);
        try {
          if (!fs.lstatSync(link).isSymbolicLink()) continue;
          const target = fs.realpathSync.native(link);
          if (target !== link) rootLinks.push([link, target]);
        } catch { /* 깨진 링크 — 건너뛴다 */ }
      }
    } catch { rootLinks = []; }
  }
  const out = [];
  for (const [link, target] of rootLinks) {
    if (real === target || real.startsWith(target + path.sep)) out.push(link + real.slice(target.length));
  }
  return out;
}

// 경로가 들어 있는 **가장 깊은** 작업 폴더. 반환 { tree, form }(form = 맞은 루트 이름). 없으면 null.
export function matchTree(abs, trees) {
  let best = null;
  for (const tree of trees || []) {
    for (const form of tree.forms) {
      const rel = path.relative(form, abs);
      const inside = rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
      if (inside && (!best || form.length > best.form.length)) best = { tree, form };
    }
  }
  return best;
}

// 파일 경로 → { tree, rel } (rel = 그 작업 폴더의 프로젝트 자리 기준 · `/` 구분). 모르면 null.
//   어느 작업 폴더인가는 실제 경로로 판정하고, 이름은 같은 작업 폴더로 판정될 때 적힌 글자 그대로를 먼저 쓴다
//   (프로젝트 안의 심볼릭 링크 파일은 링크 이름으로 잠긴다). 그 작업 폴더의 프로젝트 자리 밖이면 null.
export function resolveInTrees(p, info, cwd) {
  if (typeof p !== "string" || !p || !info) return null;
  const homeBase = info.prefix ? path.join(info.home.forms[0], info.prefix) : info.home.forms[0];
  const abs = path.isAbsolute(p) ? path.resolve(p) : path.resolve(cwd || homeBase, p);
  const real = realish(abs);
  const lexHit = matchTree(abs, info.trees);
  const realHit = real === abs ? lexHit : matchTree(real, info.trees);
  let hit = null;
  let cand = null;
  if (lexHit && (!realHit || realHit.tree === lexHit.tree)) { hit = lexHit; cand = abs; }
  else if (realHit) { hit = realHit; cand = real; }
  if (!hit) return null;
  const base = info.prefix ? path.join(hit.form, info.prefix) : hit.form;
  const rel = path.relative(base, cand);
  if (!rel || rel.startsWith("..") || path.isAbsolute(rel)) return null;
  return { tree: hit.tree, rel: rel.split(path.sep).join("/") };
}

// 경로(파일 또는 폴더)가 들어 있는 작업 폴더. 절대경로만 받는다(모르면 null).
export function treeOf(p, info) {
  if (typeof p !== "string" || !p || !info || !path.isAbsolute(p)) return null;
  const abs = path.resolve(p);
  for (const cand of uniq([abs, realish(abs)])) {
    const hit = matchTree(cand, info.trees);
    if (hit) return hit.tree;
  }
  return null;
}

// 명령 글자에 **루트 경로가 통째로** 적힌 작업 폴더들(`git -C <폴더> commit` · `cd <폴더> && …`).
//   관계있는 폴더를 고르는 용도다 — 다른 창이 자기 작업 폴더에서 만든 커밋을 이 창의 것으로 보지 않게,
//   명령에 적힌 폴더만 고른다. 적히지 않았으면 고르지 않는다.
//   경로 앞뒤가 이름 글자(영숫자 . _ -)면 다른 폴더로 본다(`wt-a` 와 `wt-ab` 를 구분).
export function treesNamedIn(text, info) {
  const out = [];
  if (typeof text !== "string" || !text || !info) return out;
  // 같은 자리에서 더 긴 이름(= 더 깊은 폴더)이 맞으면 짧은 쪽은 그 자리를 잃는다.
  const hits = []; // { tree, at, len }
  for (const tree of info.trees) {
    for (const form of tree.forms) {
      if (form === path.parse(form).root) continue; // 루트(/) 자체는 모든 경로에 들어 있다
      for (let i = text.indexOf(form); i !== -1; i = text.indexOf(form, i + 1)) {
        const prev = i > 0 ? text[i - 1] : undefined;
        const next = text[i + form.length];
        const edgeL = prev === undefined || !/[A-Za-z0-9._-]/.test(prev); // `/b/a/wt` 안의 `/a/wt` 는 다른 폴더다
        const edgeR = next === undefined || !/[A-Za-z0-9._-]/.test(next);
        if (edgeL && edgeR) hits.push({ tree, at: i, len: form.length });
      }
    }
  }
  for (const h of hits) {
    const deeper = hits.some((o) => o.at === h.at && o.len > h.len && o.tree !== h.tree);
    if (!deeper && !out.includes(h.tree)) out.push(h.tree);
  }
  return out;
}
