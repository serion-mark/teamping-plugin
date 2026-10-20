// ─────────────────────────────────────────────────────────────────────────────
// 팀핑 플러그인 — 이 창(세션)에 온 팀핑 연락을 이 기계에 잠깐 맡아 두는 곳.
//
// 팀핑 서버는 이 창에 온 연락(답장 · 카드 의견 · 확인 등)을 정해진 틀의 한 줄 문장으로 준다. 본문은 주지 않는다 —
// AI 는 그 문장이 알려 주는 도구(list_channel_messages · get_manifest)로 본문을 읽는다.
// ⛔ 이 플러그인은 아래 TEMPLATES 틀과 **글자까지 맞는 줄만** AI 에게 넣는다. 틀 밖의 줄은 버린다 —
//    훅이 넣는 줄은 감싸지지 않고 AI 문맥에 들어가므로, 서버 주소가 바뀌어도 임의의 문장이 들어가지 않게.
//
// 이 기계에 두는 것(전부 ~/.config/teamping/inbox/ · 폴더 0700 · 파일 0600 · 창마다 따로):
//   <창>.<세션>.pending.json  서버에서 받았지만 아직 AI 에게 보여 주지 않은 줄(보여 주면 지운다 · 10분 지나면 버린다 —
//                              아직 유효하면 서버가 다시 준다)
//   <창>.state.json           이미 보여 준 id(같은 줄을 두 번 넣지 않게) · 서버에 「받았다」고 아직 못 알린 id ·
//                              깨운 시각(쉬는 창을 너무 자주 깨우지 않게) · 서버가 이 기능을 꺼 둔 동안 쉬는 시각
//   <창>.<세션>.wait           쉬는 창을 기다리는 훅의 차례 표시(새 차례가 오면 옛 것은 조용히 끝난다 · 창을 닫으면 지운다)
// 파일 이름의 <세션> 은 훅이 node 를 띄우기 전에 「이 창 몫이 있나」를 셸에서 바로 보려고 붙인다.
// ─────────────────────────────────────────────────────────────────────────────
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";

// 서버의 id 검사와 같이 대소문자를 가리지 않는다(어긋나면 그 줄을 「받았다」로 못 보내 서버에 박힌다).
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
/** 세션 id 로 받는 모양 — 파일 이름에 들어가므로 이 밖의 글자는 받지 않는다(그때는 아무것도 안 한다). */
export const SESSION_RE = /^[A-Za-z0-9_-]{1,80}$/;
/** 한 번에 AI 에게 넣는 줄 수(서버가 한 번에 주는 5줄 + 「N건 더」). */
export const MAX_LINES = 6;
/** 서버에 「받았다」고 한 번에 알리는 id 상한(서버 상한과 같다). */
export const ACK_MAX = 32;
/** 맡아 둔 줄을 버리는 나이 — 그사이 철회되었을 수 있다. 아직 유효하면 서버가 다시 준다(「받았다」를 안 보냈으니). */
export const PENDING_MAX_AGE_MS = 10 * 60 * 1000;
/** 보여 준 id 를 기억하는 기간 — 서버 보관(7일)보다 조금 길게. */
const SEEN_KEEP_MS = 8 * 24 * 60 * 60 * 1000;
const SEEN_MAX = 500;
const PENDING_MAX = 20;
/** 쉬는 창을 깨우는 상한 — 한 시간에 이만큼. 넘으면 다음 사람 입력이나 도구 때 전한다. */
export const WAKES_PER_HOUR = 6;

// 서버(app/src/i18n.ts)의 문구 틀 — 글자까지 같아야 한다(계약 시험이 잰다). 고칠 때는 양쪽을 함께.
export const TEMPLATES = {
  "ko": {
    "inbox_reply_channel": "📨 팀핑 — {who}님이 이 세션이 쓴 채팅 글에 답장했습니다(답장 글 {ref}). list_channel_messages 로 읽으세요.",
    "inbox_reply_thread": "📨 팀핑 — {who}님이 이 세션이 회의에 쓴 발언에 답장했습니다(답장 글 {ref}). list_thread_messages(threadId={thread}) 로 읽으세요.",
    "inbox_card_response": "📨 팀핑 — {who}님이 이 세션이 집은 카드에 의견을 남겼습니다. get_manifest(id={ref}) 로 읽으세요.",
    "inbox_card_confirmed": "📨 팀핑 — {who}님이 이 세션이 집은 카드를 확인했습니다(카드 {ref}).",
    "inbox_card_unconfirmed": "📨 팀핑 — {who}님이 이 세션이 집은 카드의 확인을 취소했습니다. get_manifest(id={ref}) 로 보세요.",
    "inbox_assign_request": "📨 팀핑 — {who}님이 이 세션이 집은 카드의 담당을 바꿔 달라고 요청했습니다. get_manifest(id={ref}) 로 보세요 — 수락·거절은 사람이 웹에서 합니다.",
    "inbox_receipt": "📨 팀핑 — {who}님의 세션이 이 세션이 보낸 글을 받았습니다(글 {ref}).",
    "inbox_more": "📨 팀핑 — 이 세션에 온 연락이 {n}건 더 있습니다. 다음 도구 때 이어서 드립니다.",
    "inbox_tail": " 사용자에게 먼저 알리고(예: 「다른 세션의 답이 여기로 왔습니다」) 이어서 처리할지 물어보세요.",
    "lock_someone": "다른 팀원",
    "deleted_user": "탈퇴한 사용자"
  },
  "en": {
    "inbox_reply_channel": "📨 Teamping — {who} replied to a chat message this session wrote (reply {ref}). Read it with list_channel_messages.",
    "inbox_reply_thread": "📨 Teamping — {who} replied to something this session said in a meeting (reply {ref}). Read it with list_thread_messages(threadId={thread}).",
    "inbox_card_response": "📨 Teamping — {who} left feedback on the card this session picked up. Read it with get_manifest(id={ref}).",
    "inbox_card_confirmed": "📨 Teamping — {who} confirmed the card this session picked up (card {ref}).",
    "inbox_card_unconfirmed": "📨 Teamping — {who} undid the confirmation of the card this session picked up. See get_manifest(id={ref}).",
    "inbox_assign_request": "📨 Teamping — {who} asked to change the assignee of the card this session picked up. See get_manifest(id={ref}) — a person accepts or declines on the web.",
    "inbox_receipt": "📨 Teamping — {who}'s session received the message this session sent (message {ref}).",
    "inbox_more": "📨 Teamping — {n} more for this session. They'll come with the next tool call.",
    "inbox_tail": " Tell the user first (e.g. \"a reply from another session arrived here\") and ask whether to act on it.",
    "lock_someone": "another teammate",
    "deleted_user": "Deleted user"
  }
};

/**
 * 틀에 안 맞는 줄 대신 넣는 이 플러그인의 문장 — 서버 문장은 한 글자도 넣지 않고 id 만 채운다.
 * 왜 버리지 않나: 버리면 「받았다」를 못 보내 서버가 그 줄을 계속 준다 → 그런 줄이 쌓이면 새 연락이 전부 막힌다
 * (서버 문구가 바뀌었는데 이 판이 옛 틀만 아는 경우). 대신 「뭔가 왔다」를 정직하게 알리고 받는다.
 */
//   id 는 문장에 넣지 않는다 — 받은편지함 항목 id 라 어떤 도구도 받지 않는다(넣으면 AI 가 그 값으로 헛걸음한다).
export const FALLBACK = {
  ko: "📨 팀핑 — 이 세션에 연락이 하나 왔지만 이 플러그인 판이 그 문장을 알아보지 못했습니다. get_my_work 나 list_channel_messages 로 확인하세요.",
  en: "📨 Teamping — something arrived for this session, but this plugin version couldn't read the notice. Check with get_my_work or list_channel_messages.",
};

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const ID_PAT = "(?:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|\\?)";
const NAME_PAT = "「[\\p{L}\\p{N}\\p{M} .\\-_']{1,24}」";
const LINE_KEYS = ["inbox_reply_channel", "inbox_reply_thread", "inbox_card_response", "inbox_card_confirmed", "inbox_card_unconfirmed", "inbox_assign_request"];
/** 틀 하나 → 정규식 조각. {who} = 「이름」 또는 정해진 두 낱말 · {ref}·{thread} = uuid 또는 ? · {n} = 숫자. */
function pat(tpl, lang) {
  const who = `(?:${NAME_PAT}|${esc(TEMPLATES[lang].lock_someone)}|${esc(TEMPLATES[lang].deleted_user)})`;
  return esc(tpl)
    .replace(esc("{who}"), who)
    .replace(esc("{ref}"), ID_PAT)
    .replace(esc("{thread}"), ID_PAT)
    .replace(esc("{n}"), "[0-9]{1,6}");
}
const ITEM_RE = new RegExp(`^(?:${["ko", "en"].flatMap((l) => [
  ...LINE_KEYS.map((k) => pat(TEMPLATES[l][k], l) + esc(TEMPLATES[l].inbox_tail)),
  pat(TEMPLATES[l].inbox_receipt, l),
]).join("|")})$`, "u");
const MORE_RE = new RegExp(`^(?:${["ko", "en"].map((l) => pat(TEMPLATES[l].inbox_more, l)).join("|")})$`, "u");

export function inboxDir() {
  return path.join(process.env.HOME || os.homedir(), ".config", "teamping", "inbox");
}

/** 창 하나의 파일 이름들. 세션 id 가 모양에 안 맞으면 null(아무것도 안 한다). */
export function inboxPaths(dir, session) {
  if (typeof session !== "string" || !SESSION_RE.test(session) || !dir) return null;
  const key = crypto.createHash("sha256").update(`${dir}::${session}`).digest("hex").slice(0, 32);
  const d = inboxDir();
  return {
    dir: d,
    pending: path.join(d, `${key}.${session}.pending.json`),
    state: path.join(d, `${key}.state.json`),
    lock: path.join(d, `${key}.lock`),
    wait: path.join(d, `${key}.${session}.wait`),
  };
}

function ensureDir(d) {
  // 이미 있는 것이 심볼릭 링크면 쓰지 않는다(링크 너머 폴더의 권한을 바꾸지 않게).
  try { if (fs.lstatSync(d).isSymbolicLink()) throw new Error("symlink"); } catch (e) { if (e && e.message === "symlink") throw e; }
  fs.mkdirSync(d, { recursive: true, mode: 0o700 });
  try { fs.chmodSync(d, 0o700); } catch {}
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return null; }
}

/** 원자적 쓰기(tmp → rename) · 소유자만 읽게 · tmp 는 새로 만들 때만(wx). */
function writeJson(file, value) {
  const tmp = `${file}.${process.pid}.${crypto.randomBytes(6).toString("hex")}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(value), { mode: 0o600, flag: "wx" });
  try { fs.chmodSync(tmp, 0o600); } catch {}
  fs.renameSync(tmp, file);
}

const sleepSync = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

/**
 * 창 하나의 파일을 잠그고 fn 을 돈다. 같은 창의 훅이 동시에 돌 수 있다(병렬 도구 · 깨우기 훅).
 * 잠금을 못 얻으면 null — 그때는 이번에 아무것도 안 하고 다음 기회에 한다(보여 주기를 건너뛸 뿐 잃지 않는다).
 */
export function withLock(p, fn) {
  if (!p) return null;
  try { ensureDir(p.dir); } catch { return null; }
  let got = false;
  for (let i = 0; i < 40 && !got; i++) {
    try { fs.mkdirSync(p.lock, { mode: 0o700 }); got = true; } catch {
      // 5초 넘게 남은 잠금은 죽은 훅의 것이다.
      try { if (Date.now() - fs.statSync(p.lock).mtimeMs > 5000) fs.rmSync(p.lock, { recursive: true, force: true }); } catch {}
      sleepSync(10);
    }
  }
  if (!got) return null;
  try { return fn(); } finally { try { fs.rmSync(p.lock, { recursive: true, force: true }); } catch {} }
}

function loadState(p) {
  const s = readJson(p.state);
  const seen = s && s.seen && typeof s.seen === "object" && !Array.isArray(s.seen) ? s.seen : {};
  const toAck = s && Array.isArray(s.toAck) ? s.toAck.filter((x) => typeof x === "string" && UUID.test(x)) : [];
  const wakes = s && Array.isArray(s.wakes) ? s.wakes.filter((x) => Number.isFinite(x)) : [];
  const offUntil = s && Number.isFinite(s.offUntil) ? s.offUntil : 0;
  return { seen, toAck, wakes, offUntil };
}

function saveState(p, st, now) {
  const seen = {};
  const keep = Object.entries(st.seen)
    .filter(([id, at]) => UUID.test(id) && Number.isFinite(at) && now - at < SEEN_KEEP_MS)
    .sort((a, b) => b[1] - a[1])
    .slice(0, SEEN_MAX);
  for (const [id, at] of keep) seen[id] = at;
  writeJson(p.state, {
    seen,
    toAck: [...new Set(st.toAck)].slice(-ACK_MAX),
    wakes: st.wakes.filter((t) => now - t < 60 * 60 * 1000).slice(-50),
    offUntil: st.offUntil,
  });
}

/** 서버가 준 한 줄을 다듬는다 — 보이지 않는 글자 · 제어 문자 · 줄바꿈 제거. */
export function cleanLine(line) {
  if (typeof line !== "string" || line.length > 2000) return "";
  return line.replace(/[\p{Cc}\p{Cf}\p{Co}\p{Cn}\u2028\u2029]+/gu, " ").replace(/\s+/g, " ").trim();
}

/** 정해진 틀의 줄인가(「N건 더」 줄은 isMore). */
export function isItemLine(line) { return ITEM_RE.test(line); }
export function isMoreLine(line) { return MORE_RE.test(line); }

/** 서버 응답의 항목 목록 → { items: [{id, line, at}], more: {line}|null } (틀에 맞는 줄만). */
function normItems(items, now) {
  const out = [];
  let more = null;
  if (!Array.isArray(items)) return { items: out, more };
  for (const it of items.slice(0, 20)) {
    if (!it || typeof it !== "object") continue;
    const line = cleanLine(it.line);
    if (!line) continue;
    if (it.id === "more") { if (isMoreLine(line)) more = { line }; continue; }
    if (typeof it.id !== "string" || !UUID.test(it.id)) continue;
    const at = Number.isFinite(it.at) ? it.at : now;
    if (isItemLine(line)) { out.push({ id: it.id, line, at }); continue; }
    // 틀 밖 — 이 플러그인 문장으로 바꿔 넣는다(서버 글자는 버린다 · 언어만 본다).
    //   언어는 「」 안(사람 이름)을 빼고 본다 — 영어 문장 속 한글 이름 때문에 한국어로 나가지 않게.
    const lang = /[\u3131-\u318e\uac00-\ud7a3]/.test(line.replace(/「[^」]*」/g, "")) ? "ko" : "en";
    out.push({ id: it.id, line: FALLBACK[lang] + TEMPLATES[lang].inbox_tail, at, fallback: true });
  }
  return { items: out, more };
}

/** 맡아 둔 것 읽기 — 너무 오래된 줄은 버린다. */
function loadPending(p, now) {
  const pend = readJson(p.pending);
  const n = normItems(pend && pend.items, now);
  const items = n.items.filter((x) => now - x.at < PENDING_MAX_AGE_MS && x.at <= now + 60_000);
  const more = items.length > 0 && pend && pend.more && typeof pend.more.line === "string" && isMoreLine(pend.more.line) ? { line: pend.more.line } : null;
  return { items, more };
}

function savePending(p, items, more) {
  if (items.length === 0) { try { fs.rmSync(p.pending, { force: true }); } catch {} return; }
  writeJson(p.pending, { items: items.slice(0, PENDING_MAX), more: more || null });
}

/** 서버에 「받았다」고 알릴 id(다음 요청에 싣는다). */
export function acksToSend(p) {
  if (!p) return [];
  return loadState(p).toAck.slice(-ACK_MAX);
}

/** 서버가 지금 이 기능을 꺼 두었나(꺼져 있다는 답을 받은 뒤 잠깐 쉰다). */
export function isResting(p, now = Date.now()) {
  if (!p) return true;
  return loadState(p).offUntil > now;
}

/** 꺼져 있다는 답을 받았다 — ms 동안 기다리는 훅을 걸지 않는다. */
export function rest(p, ms, now = Date.now()) {
  return withLock(p, () => {
    const st = loadState(p);
    st.offUntil = now + ms;
    saveState(p, st, now);
    return true;
  });
}

/**
 * 서버 응답을 받았다. ① 보낸 「받았다」 id 는 지운다(서버가 받았다) ② 맡아 둔 줄을 서버가 지금 준 목록으로 **바꾼다**
 *   — 서버가 원본이다. 서버는 「받았다」 전까지 같은 줄을 다시 주므로, 목록에서 빠진 줄은 철회·만료된 것이다.
 *   그래서 맡아 둔 줄을 버려도 잃지 않는다. ③ 이미 보여 줬는데 서버가 또 준 줄은 「받았다」를 다시 싣는다.
 * items 가 null 이면 「받았다」만 지운다(맡아 둔 줄과 「N건 더」는 그대로).
 * ⚠️ 응답 순서는 따지지 않는다 — 병렬 요청의 옛 응답이 늦게 오면 그사이 철회된 줄이 한 번 보일 수 있다.
 *   그 줄이 가리키는 글은 이미 없고, 줄은 「먼저 사용자에게 물어라」를 말한다. 순서를 재는 장치는 시계 · 긴 기다림과
 *   엉켜 받은편지함을 조용히 멈추게 할 수 있다 — 드문 한 줄보다 멈춤이 나쁘다.
 */
export function afterServer(p, sentAcks, items, now = Date.now()) {
  return withLock(p, () => {
    const st = loadState(p);
    const sent = new Set(Array.isArray(sentAcks) ? sentAcks : []);
    st.toAck = st.toAck.filter((id) => !sent.has(id));
    const pend = loadPending(p, now);
    let more = pend.more;
    if (items !== null) {
      const list = normItems(items, now);
      more = list.more; // 서버가 지금 말한 「더 있다」가 맞다(없으면 없앤다)
      const oldAt = new Map(pend.items.map((x) => [x.id, x.at]));
      const next = [];
      for (const it of list.items) {
        if (st.seen[it.id]) { if (!st.toAck.includes(it.id)) st.toAck.push(it.id); continue; }
        if (next.some((x) => x.id === it.id)) continue;
        next.push({ ...it, at: oldAt.get(it.id) ?? it.at });
      }
      pend.items = next;
    }
    savePending(p, pend.items, more);
    saveState(p, st, now);
    return pend.items.length;
  });
}

/**
 * 보여 줄 줄을 고른다 — 아직 안 보여 준 것 중 앞에서부터 한도만큼만 「보여 줬다」로 적는다.
 * 한도 밖의 줄은 그대로 맡아 둔다(보여 주지 않은 줄을 「받았다」로 보내면 영영 사라진다).
 */
function pick(st, pend, now) {
  const fresh = pend.items.filter((x) => !st.seen[x.id]);
  if (fresh.length === 0) return { lines: [], rest: [] };
  const room = MAX_LINES - 1; // 마지막 칸은 「더 있다」 자리
  const show = fresh.slice(0, room);
  const rest = fresh.slice(room);
  for (const it of show) {
    st.seen[it.id] = now;
    if (!st.toAck.includes(it.id)) st.toAck.push(it.id);
  }
  // 같은 문장은 한 번만(대체 문장이 여럿이면 똑같은 줄이 겹친다) — 「받았다」는 위에서 모두 적었다.
  const lines = [...new Set(show.map((x) => x.line))];
  if (pend.more) lines.push(pend.more.line);
  return { lines, rest };
}

/** 맡아 둔 줄을 꺼내 「보여 줬다」로 적는다. 돌려준 줄을 훅이 AI 에게 넣는다. */
export function takePending(p, now = Date.now()) {
  if (!p || !fs.existsSync(p.pending)) return [];
  const r = withLock(p, () => {
    const st = loadState(p);
    const pend = loadPending(p, now);
    const { lines, rest } = pick(st, pend, now);
    savePending(p, rest, rest.length > 0 ? pend.more : null);
    saveState(p, st, now);
    return lines;
  });
  return r || [];
}

/** 쉬는 창을 깨울 줄 — 맡아 둔 줄과 방금 받은 줄을 함께 본다. 깨우기 상한에 걸리면 [] (줄은 그대로 맡아 둔다). */
export function takeForWake(p, items, now = Date.now()) {
  const r = withLock(p, () => {
    const st = loadState(p);
    st.wakes = st.wakes.filter((t) => now - t < 60 * 60 * 1000);
    const pend = loadPending(p, now);
    const list = normItems(items, now);
    const have = new Set(pend.items.map((x) => x.id));
    for (const it of list.items) {
      if (st.seen[it.id]) { if (!st.toAck.includes(it.id)) st.toAck.push(it.id); continue; }
      if (!have.has(it.id)) { pend.items.push(it); have.add(it.id); }
    }
    if (list.items.length > 0 || list.more) pend.more = list.more;
    const fresh = pend.items.filter((x) => !st.seen[x.id]);
    if (fresh.length === 0) { savePending(p, [], null); saveState(p, st, now); return { lines: [], capped: false }; }
    if (st.wakes.length >= WAKES_PER_HOUR) {
      // 깨우지 않는다 — 줄은 맡아 두고 다음 사람 입력이나 도구 때 넣는다.
      savePending(p, fresh, pend.more);
      saveState(p, st, now);
      return { lines: [], capped: true };
    }
    const { lines, rest } = pick(st, { items: fresh, more: pend.more }, now);
    savePending(p, rest, rest.length > 0 ? pend.more : null);
    if (lines.length > 0) st.wakes.push(now);
    saveState(p, st, now);
    return { lines, capped: false };
  });
  return r || { lines: [], capped: false };
}

/** 기다리는 훅의 차례를 새로 잡는다(이전 차례의 훅은 다음 확인 때 조용히 끝난다). */
export function claimWaitTurn(p) {
  if (!p) return null;
  const turn = crypto.randomBytes(8).toString("hex");
  try { ensureDir(p.dir); writeJson(p.wait, { turn }); } catch { return null; }
  return turn;
}

export function isMyWaitTurn(p, turn) {
  const w = readJson(p.wait);
  return !!(w && w.turn === turn);
}

/** 8일 넘게 안 쓴 창의 파일 · 죽은 잠금 · 남은 tmp 를 지운다(닫힌 창이 남긴 것). */
export function sweepOld(now = Date.now()) {
  const d = inboxDir();
  let names = [];
  try { names = fs.readdirSync(d); } catch { return; }
  for (const n of names) {
    const f = path.join(d, n);
    let st;
    try { st = fs.lstatSync(f); } catch { continue; }
    const age = now - st.mtimeMs;
    if (/\.tmp$/.test(n) && age > 60_000) { try { fs.rmSync(f, { force: true }); } catch {} continue; }
    if (/^[0-9a-f]{32}\.lock$/.test(n) && age > 60_000) { try { fs.rmSync(f, { recursive: true, force: true }); } catch {} continue; }
    if (!/^[0-9a-f]{32}\.(?:[A-Za-z0-9_-]{1,80}\.)?(pending\.json|state\.json|wait)$/.test(n)) continue;
    if (age > SEEN_KEEP_MS) { try { fs.rmSync(f, { force: true }); } catch {} }
  }
}

/** AI 에게 넣을 글(여러 줄). */
export function formatLines(lines) {
  return lines.join("\n");
}

export { UUID };
