#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
// 팀핑 플러그인 — 이 레포에 자동 잠금 켜기(Claude Code 로그인 연결용 · 브라우저에서 한 번 허용).
//
//   node hook-key-receive.mjs --origin https://teamping.dev --user <사람 id> --org <회사 id> [--ch <프로젝트 id>]
//
// 하는 일: 127.0.0.1 임시 포트에 한 번용 수신기 → 브라우저로 팀핑 동의 화면(열쇠 택배 · 목적 hook) → 사람이 프로젝트를 고르고 허용 →
//   수령증 교환(PKCE) → 범위 hook 열쇠(훅 문만 연다 · 팀핑 도구 0개)를 ~/.config/teamping/hookkey/<레포 키> 에 0600 으로 저장.
//   Codex 용 조각의 hook_key_receive.py 와 **같은 서버 흐름·같은 파일·같은 출력 낱말**이다(계약 v1).
// --user·--org 는 이 연결의 신원(팀핑 도구 get_my_work 맨 위 줄 · 셋업 키트) — 브라우저 로그인이 다른 사람·회사면 서버가 열쇠를 만들지 않는다.
//
// 출력(마지막 줄 하나 · 열쇠 값은 어디에도 안 찍는다):
//   TEAMPING_HOOKKEY_OK replaced_old=<0|1> moved=<0|1> key=<열쇠 id 앞 12자>
//   TEAMPING_HOOKKEY_STOP <낱말>   (낱말 = 아래 REASONS — 셋업 키트가 사람 문장으로 바꾼다)
// ─────────────────────────────────────────────────────────────────────────────
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { spawn } from "node:child_process";
import {
  validOrigin, releaseHeldLocks, repoIdentity, rawDevice, kitDeviceOf, hookDeviceValue, readKey, withRepoLock, writeKeyAt, removeKeyAt, formatHookKeyFile,
} from "./hook-key.mjs";

const WAIT_MS = 540_000; // 서버 흐름 수명(10분) 안 · 터미널은 9분 기다린다
const GO_WAIT_MS = 30_000; // 브라우저가 수신기에 닿기까지
const LIMIT = 65_536;
const REASONS = new Set([
  "bad_input", "remote", "no_python", "no_repo", "no_device", "no_git", "server_off", "hook_off", "rate_limited", "flow_rejected",
  "cancelled", "timeout", "exchange_failed", "exchange_lost", "identity_mismatch", "server_mismatch", "locked", "write_failed",
]);
const ID_RE = /^[A-Za-z0-9_-]{1,64}$/;
const lang = process.env.TEAMPING_LANG === "en" ? "en" : "ko";
const TEXT = {
  ko: {
    label: "브라우저가 열리면 이 레포를 쓰는 프로젝트를 고르고 허용하세요. 동의 화면의 『이 열쇠의 이름』에 레포 이름을 적어 두면 나중에 고르기 쉽습니다.",
    mismatch: "서버가 옛 판일 수 있어요 — 마이페이지 『연결 열쇠』에서 방금 생긴 열쇠를 끊어 주세요.",
  },
  en: {
    label: "When the browser opens, pick the project this repo belongs to and allow. Name this repository in the consent screen key label so you can identify it later.",
    mismatch: "The server may be outdated. Revoke the newly created key in My page / Connection keys.",
  },
};

/** 신호로 끝날 때 치울 것 — 발급(200) 뒤면 이 레포의 옛 열쇠 파일(서버에선 이미 끊김) · 브라우저용 임시 폴더(파이썬 판과 같은 정리). */
const cleanup = { issuedDir: null, repo: null, temp: null };
function cleanOnSignal() {
  if (cleanup.issuedDir && cleanup.repo) removeKeyAt(cleanup.issuedDir, cleanup.repo);
  if (cleanup.temp) {
    try {
      fs.rmSync(cleanup.temp, { recursive: true, force: true });
    } catch {
      /* 없음 */
    }
  }
}

class Stop extends Error {
  constructor(reason) {
    super(reason);
    this.reason = reason;
  }
}

function args(argv) {
  const names = new Set(["--origin", "--user", "--org", "--ch"]);
  const v = {};
  if (argv.length % 2 !== 0) throw new Stop("bad_input");
  for (let i = 0; i < argv.length; i += 2) {
    const k = argv[i];
    if (!names.has(k) || Object.prototype.hasOwnProperty.call(v, k.slice(2))) throw new Stop("bad_input");
    v[k.slice(2)] = argv[i + 1];
  }
  if (!validOrigin(v.origin) || !ID_RE.test(v.user ?? "") || !ID_RE.test(v.org ?? "")) throw new Stop("bad_input");
  if (v.ch !== undefined && v.ch !== "" && !ID_RE.test(v.ch)) throw new Stop("bad_input");
  return v;
}

function device() {
  if (process.platform === "darwin") return "mac";
  if (process.platform === "linux") return "linux";
  throw new Stop("remote"); // Windows 등은 이 판에서 받지 않는다(셋업 키트의 열쇠 복사 경로로)
}

function browserCommand(dev) {
  const env = process.env;
  if (["SSH_CONNECTION", "SSH_TTY", "SSH_CLIENT", "WSL_DISTRO_NAME", "REMOTE_CONTAINERS", "REMOTE_CONTAINERS_IPC"].some((k) => env[k]) || env.CODESPACES === "true") {
    throw new Stop("remote");
  }
  if (fs.existsSync("/.dockerenv")) throw new Stop("remote");
  for (const [file, re] of [["/proc/version", /microsoft/i], ["/proc/1/cgroup", /docker|kubepods|containerd/i]]) {
    try {
      if (re.test(fs.readFileSync(file, "utf8").slice(0, 65536))) throw new Stop("remote");
    } catch (e) {
      if (e instanceof Stop) throw e;
    }
  }
  if (["vscode-server", "browser.sh", "helpers/browser"].some((x) => (env.BROWSER ?? "").includes(x))) throw new Stop("remote");
  if (dev === "linux" && !(env.DISPLAY || env.WAYLAND_DISPLAY)) throw new Stop("remote");
  const name = dev === "mac" ? "open" : "xdg-open";
  // 고정 경로를 먼저 — PATH 는 마지막(레포의 .envrc 가 PATH 앞에 레포 안 폴더를 넣어도 가짜 열기 명령을 덜 타게)
  const fixed = dev === "mac" ? ["/usr/bin/open"] : ["/usr/bin/xdg-open", "/usr/local/bin/xdg-open", "/bin/xdg-open"];
  for (const f of fixed) if (fs.existsSync(f)) return f;
  for (const dir of (env.PATH ?? "").split(path.delimiter)) {
    if (!dir || !path.isAbsolute(dir)) continue; // 상대 경로 PATH 칸(현재 폴더)은 쓰지 않는다 — 레포 안의 가짜 open 을 부르지 않게
    const p = path.join(dir, name);
    try {
      fs.accessSync(p, fs.constants.X_OK);
      return p;
    } catch {
      /* 다음 */
    }
  }
  throw new Stop("remote");
}

/** 요청 — 리다이렉트를 따르지 않고 프록시 환경 변수를 쓰지 않는다(node fetch 는 원래 안 씀). { status, body(Buffer|null) }. */
async function request(url, fields, onStatus) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), fields ? 30_000 : 5_000);
  let status = 0;
  try {
    const res = await fetch(url, {
      method: fields ? "POST" : "GET",
      redirect: "manual",
      signal: ctl.signal,
      headers: { accept: "application/json", ...(fields ? { "content-type": "application/x-www-form-urlencoded" } : {}) },
      body: fields ? new URLSearchParams(fields).toString() : undefined,
    });
    status = res.status;
    if (onStatus) onStatus(status);
    const buf = Buffer.from(await res.arrayBuffer());
    return { status, body: buf.length <= LIMIT ? buf : null };
  } catch {
    if (fields && status === 200) throw new Stop("exchange_lost"); // 발급은 됐는데 본문을 잃음
    if (fields && status === 0) throw new Stop(ctl.signal.aborted ? "timeout" : "exchange_failed");
    return { status, body: null };
  } finally {
    clearTimeout(timer);
  }
}

async function probe(origin) {
  const { status } = await request(`${origin}/kit/connect?purpose=hook`);
  const word = status === 400 ? null : status === 503 ? "hook_off" : status === 429 ? "rate_limited" : "server_off";
  if (word) throw new Stop(word);
}

const same = (a, b) => {
  const x = Buffer.from(String(a));
  const y = Buffer.from(String(b));
  return x.length === y.length && timingSafeEqual(x, y);
};

/** 수신기 + 브라우저 → 수령증. */
async function receiveCode(v, dev, command) {
  const verifier = randomBytes(32).toString("base64url");
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  const state = randomBytes(32).toString("base64url");
  const nonce = randomBytes(24).toString("base64url");
  let go = false;
  let result = null; // 문자열 = 수령증 · false = 거절
  let noise = 0;
  let auth = "";
  let host = "";
  const page = (res, status, location) => {
    const body = '<meta name="referrer" content="no-referrer"><script>history.replaceState(null,"","/done")</script>Teamping';
    res.writeHead(status, {
      "content-length": Buffer.byteLength(body), "content-type": "text/html; charset=utf-8", "cache-control": "no-store",
      "referrer-policy": "no-referrer", "x-frame-options": "DENY", "x-content-type-options": "nosniff",
      "content-security-policy": "default-src 'none'; script-src 'unsafe-inline'; frame-ancestors 'none'", connection: "close",
      ...(location ? { location } : {}),
    });
    res.end(body);
  };
  const bad = (res) => {
    noise += 1;
    page(res, 400);
  };
  const server = http.createServer((req, res) => {
    // 콜백 주소·수령증·state 는 어디에도 기록하지 않는다
    if (req.method !== "GET" || req.headers.host !== host || (req.rawHeaders.filter((h, i) => i % 2 === 0 && h.toLowerCase() === "host").length !== 1) || (req.url ?? "").length > 2048) return bad(res);
    let u;
    try {
      u = new URL(req.url ?? "", `http://${host}`);
    } catch {
      return bad(res);
    }
    if (!(req.url ?? "").startsWith("/") || u.hash) return bad(res);
    const keys = [...u.searchParams.keys()];
    if (keys.length > 5 || new Set(keys).size !== keys.length) return bad(res);
    const q = Object.fromEntries(u.searchParams);
    if (u.pathname === "/go") {
      if (go || keys.length !== 1 || !("n" in q) || !same(q.n, nonce)) return bad(res);
      go = true;
      return page(res, 302, auth);
    }
    if (u.pathname !== "/callback" || !go || !same(q.state ?? "", state)) return bad(res);
    if (keys.length === 2 && "code" in q && /^teamping_kac_[0-9a-f]{64}$/.test(q.code)) result = q.code;
    else if (q.error === "access_denied" && keys.every((k) => ["error", "reason", "state"].includes(k))) result = false;
    else return bad(res);
    page(res, 200);
  });
  server.requestTimeout = 5_000;
  server.headersTimeout = 5_000;
  server.on("clientError", (_e, sock) => {
    noise += 1;
    sock.destroy();
  });
  await new Promise((ok, no) => {
    server.once("error", () => no(new Stop("remote")));
    server.listen(0, "127.0.0.1", ok);
  });
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), "teamping-hook-consent-"));
  cleanup.temp = temp;
  try {
    const port = server.address().port;
    host = `127.0.0.1:${port}`;
    const fields = { port: String(port), state, challenge, org: v.org, dev, purpose: "hook", ...(v.ch ? { ch: v.ch } : {}) };
    auth = `${v.origin}/kit/connect?${new URLSearchParams(fields).toString()}`;
    // 같은 흐름 등록은 멱등 — 브라우저가 같은 주소를 다시 열어 자기 쿠키를 받는다(이 확인은 쿠키를 넘기지 않는다)
    const reg = await request(auth);
    if (reg.status !== 200) throw new Stop("flow_rejected");
    console.log(TEXT[lang].label);
    // 브라우저에 주소(state 포함)를 명령 인자로 넘기지 않는다 — 0600 임시 HTML 이 수신기의 /go 로 보낸다(ps 에 안 보이게)
    const html = path.join(temp, "open.html");
    const fd = fs.openSync(html, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY, 0o600);
    fs.writeSync(fd, `<meta name="referrer" content="no-referrer"><meta http-equiv="refresh" content="0;url=http://${host}/go?n=${nonce}">`);
    fs.closeSync(fd);
    let exited = null;
    let child;
    try {
      child = spawn(command, [html], { stdio: "ignore", detached: false });
    } catch {
      throw new Stop("remote");
    }
    child.on("error", () => {
      exited = 1;
    });
    child.on("exit", (c) => {
      exited = c ?? 1;
    });
    const start = Date.now();
    while (result === null) {
      if (Date.now() - start > WAIT_MS) throw new Stop("timeout");
      if (!go && (Date.now() - start > GO_WAIT_MS || (exited !== null && exited !== 0))) throw new Stop("remote");
      if (noise >= 20) throw new Stop("cancelled");
      await new Promise((r) => setTimeout(r, 200));
    }
    if (result === false) throw new Stop("cancelled");
    return { code: result, verifier, port };
  } finally {
    server.closeAllConnections?.();
    server.close();
    fs.rmSync(temp, { recursive: true, force: true });
    cleanup.temp = null;
  }
}

async function receive(v) {
  const dev = device();
  const command = browserCommand(dev);
  let repo;
  try {
    repo = repoIdentity(process.cwd());
  } catch (e) {
    throw new Stop(e && e.code === "no_git" ? "no_git" : "no_repo");
  }
  const raw = rawDevice(dev);
  if (raw === null) throw new Stop("no_device");
  const uid = typeof process.getuid === "function" ? process.getuid() : 0;
  const deviceValue = hookDeviceValue(kitDeviceOf(v.user, uid, raw), repo);
  await probe(v.origin);
  let out;
  try {
    out = await withRepoLock(repo, async (dir) => {
      const old = readKey(repo);
      const { code, verifier, port } = await receiveCode(v, dev, command);
      let issued = false;
      try {
        const { status, body } = await request(`${v.origin}/kit/connect/token`, {
          code, code_verifier: verifier, port: String(port), device: deviceValue, expect_user_id: v.user, expect_org_id: v.org, purpose: "hook",
        }, (s) => {
          issued = s === 200;
          if (issued) {
            cleanup.issuedDir = dir;
            cleanup.repo = repo;
          }
        });
        let answer = null;
        try {
          answer = body ? JSON.parse(body.toString("utf8")) : null;
        } catch {
          answer = null;
        }
        if (status !== 200) {
          if (answer && typeof answer === "object" && answer.reason === "identity_mismatch") throw new Stop("identity_mismatch");
          throw new Stop("exchange_failed");
        }
        if (body === null) throw new Stop("exchange_lost");
        if (!answer || typeof answer !== "object" || answer.purpose !== "hook" || !Array.isArray(answer.scopes) || answer.scopes.length !== 1 || answer.scopes[0] !== "hook") {
          throw new Stop("server_mismatch");
        }
        const fields = { v: "1", server: v.origin, key: answer.key, key_id: answer.token_id, org: answer.org_id, channel: answer.channel_id, repo };
        try {
          formatHookKeyFile(fields);
        } catch {
          throw new Stop("server_mismatch");
        }
        if (fields.org !== v.org || answer.user_id !== v.user) throw new Stop("server_mismatch");
        const moved = old && (old.org !== fields.org || old.channel !== fields.channel) ? 1 : 0;
        try {
          writeKeyAt(dir, fields);
        } catch {
          throw new Stop("write_failed");
        }
        cleanup.issuedDir = null; // 새 열쇠를 저장했다 — 신호가 와도 지우지 않는다
        return { replaced: answer.replaced_old === 1 ? 1 : 0, moved, keyId: fields.key_id };
      } catch (e) {
        if (issued) removeKeyAt(dir, repo); // 서버가 200 을 냈다면 옛 열쇠는 이미 끊겼다 — 옛 파일을 남기지 않는다
        throw e;
      }
    });
  } catch (e) {
    if (e instanceof Stop) throw e;
    if (e && e.code === "locked") throw new Stop("locked");
    throw new Stop("write_failed");
  }
  console.log(`TEAMPING_HOOKKEY_OK replaced_old=${out.replaced} moved=${out.moved} key=${out.keyId.slice(0, 12)}`);
}

async function main() {
  const hard = setTimeout(() => {
    cleanOnSignal();
    releaseHeldLocks();
    console.log("TEAMPING_HOOKKEY_STOP timeout");
    process.exit(2);
  }, WAIT_MS + 45_000);
  let reason;
  try {
    await receive(args(process.argv.slice(2)));
    clearTimeout(hard);
    return 0;
  } catch (e) {
    reason = e instanceof Stop && REASONS.has(e.reason) ? e.reason : "exchange_failed";
  }
  clearTimeout(hard);
  if (reason === "server_mismatch") console.log(TEXT[lang].mismatch);
  console.log(`TEAMPING_HOOKKEY_STOP ${reason}`);
  return 2;
}

for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(sig, () => {
    cleanOnSignal();
    releaseHeldLocks();
    console.log(`TEAMPING_HOOKKEY_STOP ${sig === "SIGINT" ? "cancelled" : "timeout"}`);
    process.exit(2);
  });
}
main().then((c) => process.exit(c));
