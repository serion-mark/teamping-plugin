// ─────────────────────────────────────────────────────────────────────────────
// 팀핑 플러그인 — 이 창에 온 팀핑 연락을 서버에서 가져온다.
//
//   node inbox-wait.mjs wait   턴이 끝난 뒤(쉬는 창) 뒤에서 기다리다, 연락이 오면 그 줄을 stderr 로 내고
//                              종료 코드 2 로 끝난다 → Claude Code 가 창을 깨워 AI 가 읽는다(asyncRewake).
//                              연락이 없으면 정해진 시간 뒤 조용히 끝난다(다음 턴 끝에 다시 건다).
//   node inbox-wait.mjs once   한 번만 묻고 받은 줄은 맡아 둔다(다음 도구 · 입력 때 넣는다). 기다리지 않는다.
//
// 보내는 것: 세션 id · 레포 주소(어느 프로젝트인지) · 「받았다」 id. 받는 것: 서버가 만든 한 줄 문장들.
// 환경: TEAMPING_TOKEN · TEAMPING_BASE · TEAMPING_REPO_KEY · TEAMPING_PROJECT_DIR
// ─────────────────────────────────────────────────────────────────────────────
import {
  inboxPaths, acksToSend, afterServer, takeForWake, isResting, rest,
  claimWaitTurn, isMyWaitTurn, sweepOld, formatLines,
} from "./inbox-local.mjs";

const MODE = process.argv[2] === "once" ? "once" : "wait";
// 기다리는 총 시간(초). 시험에서만 줄인다.
const LIFETIME_S = Math.max(1, Math.min(Number(process.env.TEAMPING_INBOX_WAIT_LIFETIME_S) || 50 * 60, 55 * 60));
// 한 번 물을 때 서버가 붙잡아 두는 시간(초 · 서버 상한 50).
const POLL_S = Math.max(0, Math.min(Number(process.env.TEAMPING_INBOX_POLL_S) || 50, 50));
// 쉬는 시간 단위(밀리초) — 시험에서만 줄인다.
const UNIT_MS = Math.max(1, Number(process.env.TEAMPING_INBOX_UNIT_MS) || 1000);
// 서버가 이 기능을 꺼 두었거나 이 창을 모를 때 다시 묻지 않는 시간.
const REST_MS = 10 * 60 * 1000;
const STOP_WHY = new Set(["off", "no-token", "no-scope", "unmapped-repo", "no-channel-access", "missing-fields", "bad-body"]);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function ask(base, token, body, timeoutS, stillMine = null) {
  // 다음 턴의 기다림이 차례를 가져가면 붙잡아 둔 요청을 바로 끊는다 — 서버의 기다림 자리를 비워 주려고.
  //   (옛 node 에도 있는 것만 쓴다 — 시간 상한도 같은 컨트롤러로.)
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutS * 1000);
  const tick = stillMine ? setInterval(() => { if (!stillMine()) ctl.abort(); }, 1000) : null;
  // 본문을 다 읽을 때까지 같은 상한 안에서(헤더만 보내고 멈추는 서버에 붙잡히지 않게).
  try {
    const r = await fetch(`${base}/api/hooks/inbox`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
      body: JSON.stringify(body),
      signal: ctl.signal,
    });
    let j = null;
    try { j = await r.json(); } catch { j = null; }
    if (ctl.signal.aborted) throw new Error("aborted");
    return { status: r.status, j };
  } finally { clearTimeout(timer); if (tick) clearInterval(tick); }
}

let input = "";
process.stdin.on("data", (d) => (input += d));
process.stdin.on("end", async () => {
  let code = 0;
  try {
    code = await main(JSON.parse(input));
  } catch { code = 0; }
  process.exit(code);
});

async function main(ev) {
  const session = typeof ev.session_id === "string" ? ev.session_id : "";
  const dir = process.env.TEAMPING_PROJECT_DIR || "";
  const token = process.env.TEAMPING_TOKEN || "";
  const base = process.env.TEAMPING_BASE || "";
  const repoKey = process.env.TEAMPING_REPO_KEY || "";
  if (!session || !dir || !token || !base) return 0;
  if (typeof ev.agent_id === "string" && ev.agent_id) return 0; // 서브에이전트의 턴 끝이 아니라 창의 턴 끝에만
  const p = inboxPaths(dir, session);
  if (isResting(p)) return 0;

  if (MODE === "once") {
    const acks = acksToSend(p);
    const { status, j } = await ask(base, token, { session_id: session, repo_key: repoKey, inbox_ack: acks, wait_s: 0 }, 5);
    if (status === 401 || status === 403 || (j && j.ok === false && STOP_WHY.has(j.why))) { rest(p, REST_MS); return 0; }
    if (status === 200 && j && j.ok === true) afterServer(p, acks, Array.isArray(j.items) ? j.items : []);
    return 0;
  }

  sweepOld();
  const turn = claimWaitTurn(p);
  if (!turn) return 0;
  const deadline = Date.now() + LIFETIME_S * 1000;
  const mine = () => isMyWaitTurn(p, turn);
  let quick = 0; // 서버가 붙잡지 않고 빈손으로 바로 답한 횟수(연달아)
  while (Date.now() < deadline && mine()) {
    const acks = acksToSend(p);
    const left = Math.floor((deadline - Date.now()) / 1000);
    // ⛔ 1초도 안 남았으면 끝낸다 — 0초 기다림을 부탁하면 서버가 바로 답해 마지막 순간에 몰아쳐 묻게 된다.
    if (left < 1) break;
    const waitS = Math.min(POLL_S, left);
    const t0 = Date.now();
    let res;
    try {
      res = await ask(base, token, { session_id: session, repo_key: repoKey, inbox_ack: acks, wait_s: waitS }, waitS + 15, mine);
    } catch {
      if (!mine()) return 0; // 다음 차례가 가져갔다
      await sleep(30 * UNIT_MS); // 네트워크가 끊겼다 — 잠시 뒤 다시
      continue;
    }
    const { status, j } = res;
    if (status === 401 || status === 403) { rest(p, REST_MS); return 0; }
    if (status === 429) { await sleep(60 * UNIT_MS); continue; }
    if (!j || status !== 200) { await sleep(30 * UNIT_MS); continue; }
    if (j.ok === false) {
      if (STOP_WHY.has(j.why)) { rest(p, REST_MS); return 0; }
      await sleep(30 * UNIT_MS);
      continue;
    }
    // 서버가 「받았다」를 받았다 — 지우고, 맡아 둔 줄을 서버가 지금 준 목록으로 바꾼다.
    afterServer(p, acks, Array.isArray(j.items) ? j.items : []);
    // 다음 턴의 기다림이 이미 걸렸다 — 받은 줄은 맡겨 두었으니 조용히 끝난다(새 차례가 전한다).
    if (!isMyWaitTurn(p, turn)) return 0;
    const { lines, capped } = takeForWake(p, []);
    if (lines.length > 0) {
      process.stderr.write(formatLines(lines) + "\n");
      return 2; // 창을 깨운다
    }
    if (capped) return 0; // 한 시간 깨우기 상한 — 줄은 맡겨 두었다
    // 서버가 기다리지 않고 빈손으로 바로 답했다 — 붐비면 한참 쉬었다 다시.
    //   붐빈 것도 아닌데 두 번 연달아 그렇다면 서버가 이 창을 모른다(예: 새 대화로 바뀐 뒤) — 이번 턴은 그만 기다린다.
    //   「바로」 = 부탁한 기다림의 절반도 안 돼서(최대 5초) — 짧게 부탁했을 때 붙잡아 준 답을 즉답으로 오인하지 않게.
    if (Date.now() - t0 < Math.min(5000, waitS * 500)) {
      if (j.why !== "busy" && ++quick >= 2) return 0;
      await sleep((j.why === "busy" ? 60 : 45) * UNIT_MS);
    } else quick = 0;
  }
  return 0;
}
