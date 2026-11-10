// ─────────────────────────────────────────────────────────────────────────────
// 팀핑 플러그인 — 레포별 「자동 잠금 열쇠」(훅 범위 열쇠) 계약 v1 의 node 구현(Claude Code 로그인 연결).
//
// 왜: Claude Code 를 로그인(OAuth)으로 붙이면 팀핑 연결 열쇠가 설정 파일에 없다(Claude Code 가 자기 금고에 둔다).
//     훅은 그 금고를 못 연다 → 레포마다 따로 받은 **훅 문만 여는 열쇠**(범위 hook · MCP 도구 0개)를 쓴다.
//     Codex 용 조각(hook_key.py)과 **같은 파일·같은 계산**이다 — 한 레포에 두 도구가 같은 열쇠를 쓴다(고정 시험 벡터로 대조한다).
//
// ⛔ 비밀: 열쇠 값은 어디에도 찍지 않는다(stdout·argv·로그). 이 모듈은 값을 돌려줄 뿐이다.
// ⛔ 홈 = 계정의 홈(os.userInfo — 환경 변수 HOME·XDG_CONFIG_HOME 무시) · 링크는 어느 단계에서도 따르지 않는다.
//    `home` 인자는 시험만 넘긴다(코드 인자 · 환경 변수로 바꿀 길은 없다 — 레포의 .envrc 가 열쇠 위치를 바꾸지 못하게).
// ─────────────────────────────────────────────────────────────────────────────
import { createHash, randomBytes } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

export const CONTRACT_VERSION = 1;
export const DIR_REL = ".config/teamping/hookkey";
export const FILE_KEYS = ["v", "server", "key", "key_id", "org", "channel", "repo"];
const FIELD_RE = {
  v: /^1$/,
  server: /^https:\/\/[a-z0-9-]+(?:\.[a-z0-9-]+)*(?::[1-9][0-9]{0,4})?$/,
  key: /^teamping_[0-9a-f]{64}$/,
  key_id: /^tok_[0-9a-f-]{36}$/,
  org: /^[A-Za-z0-9_-]{1,64}$/,
  channel: /^[A-Za-z0-9_-]{1,64}$/,
  repo: /^[0-9a-f]{16}$/,
};
const LINE_RE = /^([a-z_]+)=([\x21-\x3c\x3e-\x7e]{1,512})$/;
const CONFIG_URL_RE = /^https:\/\/([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*)(?::([0-9]{1,5}))?\/mcp\/?$/;
const FILE_SERVER_RE = /^https:\/\/([a-z0-9-]+(?:\.[a-z0-9-]+)*)(?::([1-9][0-9]{0,4}))?$/;
const GIT_ENV = ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_CEILING_DIRECTORIES"];

const sha = (s) => createHash("sha256").update(s, "utf8").digest("hex");
const portOk = (p) => p === undefined || (Number(p) >= 1 && Number(p) <= 65535);

export const repoKeyOf = (diskCommonDir) => sha(`teamping-hook-repo:v1:${diskCommonDir}`).slice(0, 16);
export const repoKeyOfDir = (diskCwd) => sha(`teamping-hook-repo-dir:v1:${diskCwd}`).slice(0, 16);
export const kitDeviceOf = (user, uid, raw) => sha(`teamping-kit-device:v1:${user}:${uid}:${raw}`);
export const hookDeviceValue = (kitDevice, repoKey) => sha(`teamping-hook-device:v1:${kitDevice}:${repoKey}`);

/** server 칸(origin) 모양인가. */
export function validOrigin(v) {
  if (typeof v !== "string") return false;
  const m = FILE_SERVER_RE.exec(v);
  return !!m && portOk(m[2]);
}

/** 파일 본문(Buffer) → 칸 · 하나라도 어긋나면 null(계약 §4 — 엄격 UTF-8 · 4096 바이트 · 끝 \n · split("\n") 만 · 순서 무관). */
export function parseHookKeyFile(buf) {
  if (!Buffer.isBuffer(buf) || buf.length > 4096 || buf.length === 0 || buf[buf.length - 1] !== 0x0a) return null;
  let text;
  try {
    text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(buf);
  } catch {
    return null;
  }
  if (!/^[\x21-\x7e\n]*$/.test(text)) return null;
  const out = {};
  for (const line of text.slice(0, -1).split("\n")) {
    const m = LINE_RE.exec(line);
    if (!m) return null;
    const k = m[1];
    if (!FILE_KEYS.includes(k) || Object.prototype.hasOwnProperty.call(out, k)) return null;
    if (!FIELD_RE[k].test(m[2])) return null;
    if (k === "server" && !validOrigin(m[2])) return null;
    out[k] = m[2];
  }
  for (const k of FILE_KEYS) if (!Object.prototype.hasOwnProperty.call(out, k)) return null;
  return out;
}

export function formatHookKeyFile(f) {
  const buf = Buffer.from(FILE_KEYS.map((k) => `${k}=${f[k]}\n`).join(""), "utf8");
  const back = parseHookKeyFile(buf);
  if (!back || FILE_KEYS.some((k) => back[k] !== f[k])) throw new Error("invalid key fields");
  return buf;
}

/** 설정의 팀핑 url 과 파일의 server 가 같은 서버인가(원문 정규식 · URL 라이브러리 안 씀 · 계약 §5). */
export function sameHookServer(configUrl, fileServer) {
  if (typeof configUrl !== "string" || typeof fileServer !== "string") return false;
  const a = CONFIG_URL_RE.exec(configUrl);
  const b = FILE_SERVER_RE.exec(fileServer);
  if (!a || !b || !portOk(a[2]) || !portOk(b[2])) return false;
  const port = (p) => (p === undefined ? 443 : Number(p));
  return a[1].toLowerCase() === b[1] && port(a[2]) === port(b[2]);
}

/** 설정 url 이 「로그인 연결로 쓸 수 있는 팀핑 주소」 모양인가(https://<host>[:port]/mcp[/]). */
export const isConfigUrl = (u) => typeof u === "string" && CONFIG_URL_RE.test(u);

/** 계정 홈 — 환경 변수가 아니라 계정 정보(getpwuid)에서. */
export function accountHome() {
  return os.userInfo().homedir;
}

/** chdir 뒤 getcwd — 대소문자 무시 파일시스템에서도 디스크 표기(파이썬 disk() 와 같은 식). */
function disk(p) {
  const old = process.cwd();
  try {
    process.chdir(p);
    return process.cwd();
  } finally {
    process.chdir(old);
  }
}

/**
 * 레포 키 — `git rev-parse --git-common-dir` 를 disk() 로 푼 절대 경로의 키. 같은 레포의 작업 폴더(worktree)는 같은 키(H10).
 * git 저장소가 아니면 null(git 없는 폴더의 레포별 열쇠는 이 판에 없다 — 그 폴더는 claim_file 로).
 * 실패 이유를 가르려면 throw 를 받는다: ENOENT(git 없음) = { code: "no_git" } · 그 밖 = { code: "no_repo" }.
 */
export function repoIdentity(cwd) {
  const env = { ...process.env, LC_ALL: "C", LANGUAGE: "C" };
  for (const k of GIT_ENV) delete env[k];
  let out;
  try {
    out = execFileSync("git", ["-C", cwd, "rev-parse", "--git-common-dir"], { env, stdio: ["ignore", "pipe", "ignore"], timeout: 1000 });
  } catch (e) {
    throw Object.assign(new Error("git"), { code: e && e.code === "ENOENT" ? "no_git" : "no_repo" });
  }
  let raw = out.toString("utf8");
  if (raw.endsWith("\n")) raw = raw.slice(0, -1);
  if (!raw || raw.includes("\n")) throw Object.assign(new Error("git"), { code: "no_repo" });
  const common = path.isAbsolute(raw) ? raw : path.join(cwd, raw);
  return repoKeyOf(disk(common));
}

/** 이 컴퓨터의 기기 원문(맥 IOPlatformUUID · 리눅스 machine-id) — 못 읽으면 null. */
export function rawDevice(dev) {
  if (dev === "mac") {
    try {
      const out = execFileSync("/usr/sbin/ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"], { stdio: ["ignore", "pipe", "ignore"], timeout: 3000 }).toString("utf8");
      const m = /"IOPlatformUUID" = "([0-9A-F-]{36})"/.exec(out);
      const v = m ? m[1] : "";
      return /^[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}$/.test(v) ? v : null;
    } catch {
      return null;
    }
  }
  for (const p of ["/etc/machine-id", "/var/lib/dbus/machine-id"]) {
    let v;
    try {
      v = fs.readFileSync(p).subarray(0, 256).toString("ascii").trim();
    } catch {
      continue;
    }
    return /^[0-9a-f]{32}$/.test(v) ? v : null;
  }
  return null;
}

// ── 열쇠 파일 ───────────────────────────────────────────────────────────────

const uid = () => (typeof process.getuid === "function" ? process.getuid() : -1);

/** 홈 아래 .config/teamping/hookkey 를 한 단계씩 확인한다(링크 아님 · 내 것 · 폴더 · 쓰기 권한 남에게 없음 · 마지막은 0700). write 면 없을 때 만든다. */
function keyDir(write, home = accountHome()) {
  let dir = home;
  const top = fs.lstatSync(dir);
  if (!top.isDirectory()) throw new Error("unsafe home");
  const parts = DIR_REL.split("/");
  for (const part of parts) {
    dir = path.join(dir, part);
    let st;
    try {
      st = fs.lstatSync(dir);
    } catch (e) {
      if (!write || !e || e.code !== "ENOENT") throw e;
      fs.mkdirSync(dir, { mode: 0o700 });
      st = fs.lstatSync(dir);
    }
    if (st.isSymbolicLink() || !st.isDirectory() || st.uid !== uid()) throw new Error("unsafe directory");
    const last = part === "hookkey";
    if (last && write && (st.mode & 0o777) !== 0o700) {
      fs.chmodSync(dir, 0o700);
      st = fs.lstatSync(dir);
    }
    if ((last && (st.mode & 0o777) !== 0o700) || (!last && st.mode & 0o022)) throw new Error("unsafe directory");
  }
  return dir;
}

/** 이 레포의 열쇠 파일 경로(있든 없든 · 폴더 검사 없음 — 캐시 비교용). */
export function keyFilePath(repo, home = accountHome()) {
  if (!FIELD_RE.repo.test(repo)) throw new Error("invalid repo key");
  return path.join(home, DIR_REL, repo);
}

function readFd(fd) {
  const st = fs.fstatSync(fd);
  if (!st.isFile() || st.uid !== uid() || st.mode & 0o077 || st.nlink !== 1) throw new Error("unsafe file");
  const buf = Buffer.alloc(4097);
  let n = 0;
  for (;;) {
    const r = fs.readSync(fd, buf, n, buf.length - n, null);
    if (r === 0) break;
    n += r;
    if (n >= buf.length) break;
  }
  return buf.subarray(0, n);
}

/** 열쇠 파일 읽기 — 없거나 조금이라도 이상하면 null(던지지 않는다 · 훅은 편집을 막지 않는다). repo 칸이 이 레포가 아니면 null. */
export function readKey(repo, home = accountHome()) {
  try {
    if (!FIELD_RE.repo.test(repo)) return null;
    const dir = keyDir(false, home);
    const file = path.join(dir, repo);
    // 일반 파일만 연다(관·장치 파일을 열다 멈추지 않게) — 연 뒤에도 fstat 으로 다시 본다.
    if (!fs.lstatSync(file).isFile()) return null;
    const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    try {
      const f = parseHookKeyFile(readFd(fd));
      return f && f.repo === repo ? f : null;
    } finally {
      fs.closeSync(fd);
    }
  } catch {
    return null;
  }
}

const held = new Set();
/** 잡고 있는 잠금 파일을 지운다 — 신호로 끝날 때처럼 finally 가 못 도는 종료 직전에 부른다. */
export function releaseHeldLocks() {
  for (const p of held) {
    try {
      fs.unlinkSync(p);
    } catch {
      /* 없음 */
    }
  }
  held.clear();
}

/**
 * 이 레포 열쇠를 다루는 동안 잠근다 — `<repo>.nlock` 를 O_EXCL 로 만들고 내 프로세스 번호를 적는다(node 엔 flock 이 없다 ·
 * 파이썬 조각의 `<repo>.lock` 과 다른 이름). 적힌 프로세스가 이미 없거나 15분 넘은 잠금은 죽은 것으로 보고 치운다
 * (시간 상한·강제 종료로 finally 가 못 돌아도 다음 실행이 막히지 않게). 잡지 못하면 { code: "locked" } 를 던진다.
 */
export async function withRepoLock(repo, fn, home = accountHome()) {
  if (!FIELD_RE.repo.test(repo)) throw new Error("invalid repo key");
  const dir = keyDir(true, home);
  const lock = path.join(dir, `${repo}.nlock`);
  const take = () => {
    const fd = fs.openSync(lock, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY | fs.constants.O_NOFOLLOW, 0o600);
    try {
      fs.writeSync(fd, `${process.pid}\n`);
    } finally {
      fs.closeSync(fd);
    }
  };
  const alive = (pid) => {
    try {
      process.kill(pid, 0);
      return true;
    } catch (e) {
      return !!e && e.code === "EPERM";
    }
  };
  try {
    take();
  } catch (e) {
    if (!e || e.code !== "EEXIST") throw e;
    let stale = false;
    try {
      const st = fs.lstatSync(lock);
      if (!st.isSymbolicLink() && st.isFile()) {
        const pid = Number(/^([1-9][0-9]{0,9})\n?$/.exec(fs.readFileSync(lock, "utf8").slice(0, 16))?.[1] ?? 0);
        stale = Date.now() - st.mtimeMs > 15 * 60 * 1000 || (pid > 0 && pid !== process.pid && !alive(pid));
      }
    } catch {
      /* 그새 사라짐 */
    }
    if (!stale) throw Object.assign(new Error("locked"), { code: "locked" });
    try {
      fs.unlinkSync(lock);
      take();
    } catch {
      throw Object.assign(new Error("locked"), { code: "locked" });
    }
  }
  held.add(lock);
  try {
    return await fn(dir);
  } finally {
    held.delete(lock);
    try {
      fs.unlinkSync(lock);
    } catch {
      /* 이미 없음 */
    }
  }
}

/** 원자 저장(0600 임시 파일 → fsync → rename) 뒤 다시 읽어 같은지 확인. 실패하면 던진다. */
export function writeKeyAt(dir, fields, home = accountHome()) {
  const data = formatHookKeyFile(fields);
  const tmp = path.join(dir, `.${fields.repo}.${randomBytes(12).toString("hex")}`);
  const old = process.umask(0o077);
  try {
    const fd = fs.openSync(tmp, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY | fs.constants.O_NOFOLLOW, 0o600);
    try {
      fs.fchmodSync(fd, 0o600);
      fs.writeSync(fd, data);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fs.renameSync(tmp, path.join(dir, fields.repo));
  } finally {
    process.umask(old);
    try {
      fs.unlinkSync(tmp);
    } catch {
      /* rename 됐으면 없다 */
    }
  }
  const back = readKey(fields.repo, home);
  if (!back || back.key_id !== fields.key_id || back.key !== fields.key) throw new Error("readback failed");
}

export function removeKeyAt(dir, repo) {
  try {
    fs.unlinkSync(path.join(dir, repo));
  } catch {
    /* 없음 */
  }
}
