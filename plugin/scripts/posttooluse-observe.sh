#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 팀핑 플러그인 — PostToolUse 훅(작업 관측).
#
# 도구가 실행된 뒤 무엇이 바뀌었는지 기록만 한다. 막거나 판정하지 않는다.
#
# 바뀐 파일은 명령어 텍스트가 아니라 git 에게 묻는다(git status).
# 보내는 것은 이번 도구로 새로 바뀐 파일의 프로젝트 기준 상대경로뿐이다 — 워킹트리 전체 목록은 보내지 않는다.
#   직전 상태는 프로젝트 밖(~/.cache/teamping/observe)에 소유자만 읽게 저장한다.
#
# 서버가 응답하지 않거나 오류가 나도 도구 실행을 방해하지 않는다. 실패는 조용히 exit 0.
#
# 팀핑 연락: 서버 응답에 이 창에 온 연락(서버가 만든 한 줄 문장)이 실려 오면 이 기계에 맡아 두고,
#   **다음** 도구 때 그 줄을 AI 에게 넣는다(inbox-local.mjs). 본문은 넣지 않는다.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

LEVEL="${TEAMPING_LEVEL-}"
case "$LEVEL" in
  lv0 | lv1 | lv2 | lv3) ;;
  *) [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && LEVEL="lv2" || LEVEL="lv1" ;;
esac
case "$LEVEL" in lv0 | lv1) exit 0 ;; esac

command -v node >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

INPUT="$(cat)"
[ -n "$INPUT" ] || exit 0

# 진단 모드 — TEAMPING_HOOK_DEBUG 가 켜져 있을 때만 받은 입력의 구조를 남긴다(값은 남기지 않는다).
[ -n "${TEAMPING_HOOK_DEBUG:-}" ] && printf '%s' "$INPUT" | "$(dirname "$0")/hook-debug.sh" 2>/dev/null

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

# 지난번 서버 응답으로 맡아 둔 이 창 몫의 팀핑 연락이 있으면 지금 AI 에게 넣는다(없으면 node 를 띄우지 않는다).
. "$(dirname "${BASH_SOURCE[0]}")/inbox-pending.sh"
if teamping_inbox_has_pending "$INPUT"; then
  printf '%s' "$INPUT" | TEAMPING_PROJECT_DIR="$PROJECT_DIR" node "$(dirname "${BASH_SOURCE[0]}")/inbox-show.mjs" PostToolUse 2>/dev/null
fi

# 토큰은 resolve-token.sh 를 별도 프로세스로 실행해 받는다(화면에 찍히지 않게).
CREDS="$(bash "$(dirname "${BASH_SOURCE[0]}")/resolve-token.sh")"
TOKEN="$(printf '%s\n' "$CREDS" | sed -n 's/^TEAMPING_TOKEN=//p')"
BASE="$(printf '%s\n' "$CREDS" | sed -n 's/^TEAMPING_BASE=//p')"
[ -n "$TOKEN" ] || exit 0

REPO_KEY="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || true)"
[ -n "$REPO_KEY" ] || REPO_KEY="$(basename "$PROJECT_DIR")"

# 여기서부터 백그라운드에서 돈다 — git·네트워크 작업이 도구 실행을 늦추지 않게.
export TEAMPING_TOKEN="$TOKEN" TEAMPING_BASE="$BASE" TEAMPING_PROJECT_DIR="$PROJECT_DIR" TEAMPING_REPO_KEY="$REPO_KEY"
export TEAMPING_TREES="$(dirname "${BASH_SOURCE[0]}")/repo-trees.mjs" # 같은 레포의 작업 폴더 목록(락 훅과 같은 파일)
export TEAMPING_INBOX="$(dirname "${BASH_SOURCE[0]}")/inbox-local.mjs" # 이 창에 온 팀핑 연락을 맡아 두는 곳
printf '%s' "$INPUT" | nohup node -e '
  const fs = require("fs"), os = require("os"), path = require("path"), crypto = require("crypto");
  const { execFileSync } = require("child_process");
  let input = "";
  process.stdin.on("data", (d) => (input += d));
  process.stdin.on("end", async () => {
    try {
      const ev = JSON.parse(input);
      const dir = process.env.TEAMPING_PROJECT_DIR;
      const tool = String(ev.tool_name || "");
      const session = String(ev.session_id || "");

      // 파일을 바꿀 수 있는 도구에서만 git을 본다.
      const MUTATORS = /^(Edit|Write|MultiEdit|NotebookEdit|Bash)$/;
      let changed = [];
      // 이번 Bash 로 새로 만든 커밋 번호. 없으면 빈 배열.
      let commits = [];
      if (MUTATORS.test(tool) && session) {
        const statusOf = (base) => {
          let now = [];
          try {
            // 프로젝트 밖 파일 이름은 보내지 않는다.
            //   `git status` 는 레포 루트 기준으로 답하므로, 프로젝트가 레포의 하위 폴더면
            //   ① pathspec `-- .` 로 프로젝트 안만 묻고 ② 경로를 프로젝트 기준으로 바꾸고
            //   ③ 그래도 프로젝트 밖으로 나가는 경로는 버린다.
            let prefix = "";
            try {
              prefix = execFileSync("git", ["-C", base, "--no-optional-locks", "rev-parse", "--show-prefix"], {
                encoding: "utf8", timeout: 3000,
              }).trim();
            } catch { prefix = ""; }

            const out = execFileSync("git", ["-C", base, "--no-optional-locks", "status", "--porcelain", "-z", "--", "."], {
              encoding: "utf8", timeout: 3000, maxBuffer: 1 << 20,
            });
            // -z: NUL 구분. 이름 바꾸기(R)·복사(C)는 "새경로\0옛경로" 두 항목으로 오므로 옛 경로는 건너뛴다.
            const parts = out.split("\0").filter((s) => s.length > 0);
            for (let i = 0; i < parts.length; i++) {
              const xy = parts[i].slice(0, 2);
              const raw = parts[i].slice(3);
              if (xy.includes("R") || xy.includes("C")) i++; // 다음 항목은 원본 경로 — 건너뛴다
              if (!prefix) { now.push(raw); continue; }       // 프로젝트 = 레포 루트
              if (!raw.startsWith(prefix)) continue;          // ③ 프로젝트 밖 → 버린다
              const rel = raw.slice(prefix.length);
              if (rel) now.push(rel);
            }
          } catch { now = []; }
          return now;
        };

        // 이번에 새로 바뀐 것만 보내기 위해 직전 상태와 비교한다.
        //    상태 파일은 프로젝트 밖(캐시)에 둔다 — 안에 두면 git status 가 그 파일을 잡는다.
        const key = crypto.createHash("sha256").update(`${dir}::${session}`).digest("hex").slice(0, 32);
        const stateDir = path.join(os.homedir(), ".cache", "teamping", "observe");
        const stateFile = path.join(stateDir, `${key}.json`);
        let prevState = null;
        try { prevState = JSON.parse(fs.readFileSync(stateFile, "utf8")); } catch { prevState = null; }
        // 예전 판의 상태 파일(경로 배열)도 읽는다 — 업데이트 직후에도 기준선을 잃지 않게.
        const prev = Array.isArray(prevState) ? prevState : prevState && Array.isArray(prevState.files) ? prevState.files : null;
        // 상태 파일에서 읽은 값은 git 인자로 들어가므로 40자 16진수가 아니면 버린다.
        const prevHeadRaw = prevState && !Array.isArray(prevState) && typeof prevState.head === "string" ? prevState.head : "";
        const prevHead = /^[0-9a-f]{40}$/.test(prevHeadRaw) ? prevHeadRaw : null;
        // 직전 관측 시각(초) — 이보다 먼저 만들어진 커밋은 이번 명령이 만든 것이 아니다.
        const prevAt = prevState && !Array.isArray(prevState) && Number.isSafeInteger(prevState.at) ? prevState.at : null;
        // 커밋도 git 에게 묻는다. 이번 Bash 가 커밋을 만드는 git 명령이고 HEAD 가 앞으로 움직였을 때만,
        //    그 사이 커밋 중 이 기계의 git 사용자가 만든 것을 보낸다. 명령 원문은 보내지 않는다.
        // 관측 시각은 HEAD 를 읽기 직전에 찍는다.
        const cmd = ev.tool_input && typeof ev.tool_input.command === "string" ? ev.tool_input.command : "";
        const COMMIT_CMD = /(^|[;&|(\s])git(\s+-[Cc]\s+\S+|\s+--?[\w.-]+(=\S+)?)*\s+(commit|merge|cherry-pick|rebase|revert|am)(?=\s|$|[;&|)])/;
        const commitsOf = (base, prevHead, head, prevAt) => {
          if (!(tool === "Bash" && COMMIT_CMD.test(cmd) && prevHead && prevAt !== null && head && prevHead !== head)) return [];
          try {
            // ① 앞으로 움직였을 때만 — 브랜치 전환·reset 은 새로 만든 커밋이 아니다.
            execFileSync("git", ["-C", base, "merge-base", "--is-ancestor", prevHead, head], { timeout: 3000, stdio: "ignore" });
            // ② 이 기계의 git 사용자 — 비교에만 쓰고 보내지 않는다.
            const me = execFileSync("git", ["-C", base, "config", "user.email"], { encoding: "utf8", timeout: 3000 }).trim().toLowerCase();
            if (me) {
              const log = execFileSync("git", ["-C", base, "--no-optional-locks", "log", "--format=%H%x09%ce%x09%ct", "--max-count=21", `${prevHead}..${head}`], {
                encoding: "utf8", timeout: 3000, maxBuffer: 1 << 20,
              });
              const lines = log.split("\n").filter((l) => l.length > 0);
              // ③ 20개 넘게 한꺼번에 들어왔으면 pull·merge 로 받은 것이라 보내지 않는다.
              // ④ 커밋한 사람이 이 기계의 git 사용자인 것만 — 받아 온 동료 커밋은 뺀다.
              if (lines.length <= 20) {
                return lines
                  .map((l) => l.split("\t"))
                  // ⑤ 커밋 시각이 직전 관측 뒤인 것만 — 병합으로 들어온 옛 커밋은 뺀다.
                  .filter(([h, ce, ct]) => /^[0-9a-f]{40}$/.test(h || "") && (ce || "").trim().toLowerCase() === me && Number(ct) >= prevAt)
                  .map(([h]) => h);
              }
            }
          } catch { /* 모르면 안 한다 */ }
          return [];
        };

        const nowAt = Math.floor(Date.now() / 1000);
        let head = null;
        try {
          head = execFileSync("git", ["-C", dir, "--no-optional-locks", "rev-parse", "HEAD"], { encoding: "utf8", timeout: 3000 }).trim();
        } catch { head = null; }
        if (!/^[0-9a-f]{40}$/.test(head || "")) head = null;

        // 같은 레포의 다른 작업 폴더(git worktree)도 본다. 목록·HEAD 는 repo-trees.mjs 가 git 한 번으로 가져온다.
        //    변경은 이번 도구가 건드린 폴더에서만 싣는다(Edit 은 그 파일의 폴더 · Bash 는 명령에 적힌 폴더와 cwd).
        //    HEAD 는 모든 폴더를 적어 둔다 — 처음 건드리는 폴더에서 바로 커밋해도 기준선이 있게.
        let info = null;
        let treesMod = null;
        try {
          treesMod = await import(process.env.TEAMPING_TREES);
          info = treesMod.listRepoTrees(dir);
        } catch { info = null; }
        const others = [];
        if (info) {
          const touch = (t) => { if (t && t !== info.home && !others.includes(t)) others.push(t); };
          const ti = ev.tool_input && typeof ev.tool_input === "object" ? ev.tool_input : {};
          if (tool === "Bash") {
            for (const t of treesMod.treesNamedIn(cmd, info)) touch(t);
            touch(treesMod.treeOf(typeof ev.cwd === "string" ? ev.cwd : null, info));
          } else {
            touch(treesMod.treeOf(typeof ti.file_path === "string" ? ti.file_path : ti.notebook_path, info));
          }
        }
        const prevWt = prevState && !Array.isArray(prevState) && prevState.wt && typeof prevState.wt === "object" ? prevState.wt : {};
        const wtChanged = [];
        const wtCommits = [];
        // 직전 기준선을 이어받는다.
        const wt = {};
        if (info) {
          for (const t of info.trees) {
            if (t === info.home) continue;
            const old = prevWt[t.id] && typeof prevWt[t.id] === "object" ? prevWt[t.id] : null;
            wt[t.id] = {
              head: old && typeof old.head === "string" && /^[0-9a-f]{40}$/.test(old.head) ? old.head : null,
              files: old && Array.isArray(old.files) ? old.files.filter((f) => typeof f === "string").slice(0, 500) : null,
              // 기준선이 아직 없는 폴더에서 Edit 으로 이미 알린 파일 — 같은 파일을 다시 알리지 않게.
              edits: old && Array.isArray(old.edits) ? old.edits.filter((f) => typeof f === "string").slice(0, 500) : [],
            };
          }
        }
        if (info && tool !== "Bash") {
          // Edit 류는 도구가 고친 그 파일만 싣는다. 같은 폴더의 다른 변경은 다른 창의 것일 수 있어 싣지 않는다.
          //    다른 폴더의 기준선·HEAD 는 건드리지 않는다.
          const ti0 = ev.tool_input && typeof ev.tool_input === "object" ? ev.tool_input : {};
          const hit = treesMod.resolveInTrees(typeof ti0.file_path === "string" ? ti0.file_path : ti0.notebook_path, info, null);
          //    이름은 그 작업 폴더의 git status 에서 이 파일을 덮는 항목(파일 자체 또는 새 폴더 `app/nd/`)으로 정한다.
          //    · 덮는 항목이 없다(원복·같은 내용·무시 파일) → 싣지 않고 기억에서 뺀다.
          //    · 이미 기억에 있다 → 다시 싣지 않는다.
          //    · 덮는 항목 하나만 기억에 더한다.
          if (hit && hit.tree !== info.home) {
            const cur = wt[hit.tree.id];
            if (cur) {
              const base = info.prefix ? path.join(hit.tree.id, info.prefix) : hit.tree.id;
              const entries = statusOf(base);
              const cover = entries.find((e) => e === hit.rel || (e.endsWith("/") && hit.rel.startsWith(e)));
              const key = Array.isArray(cur.files) ? "files" : "edits";
              if (!cover) {
                cur[key] = cur[key].filter((f) => f !== hit.rel);
              } else if (!cur[key].includes(cover)) {
                wtChanged.push(cover);
                cur[key] = [...cur[key], cover].slice(0, 500);
              }
            }
          }
        } else if (info) {
          // 새 커밋 번호는 이번 git 명령의 출력에서 읽는다(출력 자체는 보내지 않는다).
          const respRaw = ev.tool_response;
          const respText = typeof respRaw === "string" ? respRaw
            : respRaw && typeof respRaw === "object" ? [respRaw.stdout, respRaw.stderr].filter((x) => typeof x === "string").join("\n")
            : "";
          const made = [];
          for (const m of respText.matchAll(/\[[^\]\n]*\s([0-9a-f]{4,40})\]/g)) made.push(m[1]);
          // 기준선(files·head)은 Bash 마다 모든 작업 폴더에서 갱신하고, 싣는 것은 이번에 건드린 폴더에서만.
          for (const t of info.trees) {
            if (t === info.home) continue;
            const old = wt[t.id];
            const base = info.prefix ? path.join(t.id, info.prefix) : t.id;
            const files = statusOf(base);
            if (others.includes(t)) {
              // 이 폴더를 처음 보면 기준선만 잡는다 — 이미 있던 변경을 이 도구가 한 일로 적지 않는다.
              if (old && Array.isArray(old.files)) {
                const before = new Set(old.files);
                // Edit 도 git 이 쓰는 이름으로 기억하므로 같은 이름끼리 비교된다.
                for (const f of files) if (!before.has(f)) wtChanged.push(f);
              }
              // 작업 폴더의 커밋은 이번 명령의 출력에 그 커밋 번호가 찍혔을 때만 싣는다.
              for (const h of commitsOf(base, old ? old.head : null, t.head, prevAt)) {
                if (made.some((abbr) => h.startsWith(abbr))) wtCommits.push(h);
              }
            }
            wt[t.id] = { head: t.head, files: files.slice(0, 500), edits: [] };
          }
        }
        // 세션 폴더의 커밋을 앞에 둔다(최대 20개).
        commits = commitsOf(dir, prevHead, head, prevAt);
        for (const h of wtCommits) if (!commits.includes(h)) commits.push(h);
        commits = commits.slice(0, 20);

        const now = statusOf(dir);
        try {
          // 상태 파일엔 바뀐 파일 경로가 담기므로 폴더 0700 · 파일 0600 으로 소유자만 읽게 한다.
          //    mkdirSync 의 mode 는 이미 있는 폴더엔 안 먹으므로 chmod 로 맞춘다.
          fs.mkdirSync(stateDir, { recursive: true, mode: 0o700 });
          try { fs.chmodSync(stateDir, 0o700); } catch {}
          // 원자적 쓰기(tmp → rename) — 병렬 도구가 반쯤 쓴 파일을 읽지 않게.
          const tmp = `${stateFile}.${process.pid}.tmp`;
          fs.writeFileSync(tmp, JSON.stringify({ files: now.slice(0, 500), head, at: nowAt, wt }), { mode: 0o600 });
          try { fs.chmodSync(tmp, 0o600); } catch {}
          fs.renameSync(tmp, stateFile);
        } catch { /* 상태를 못 써도 관측은 계속한다(다음 번에 다시 기준선이 될 뿐) */ }
        if (prev === null) {
          // 첫 실행 = 기준선. "세션 시작 시점에 이미 있던 변경"을 이 도구가 한 일로 적지 않는다.
          changed = [];
        } else {
          const before = new Set(prev);
          changed = now.filter((p) => !before.has(p));
        }
        // 작업 폴더에서 바뀐 것도 같은 이름(프로젝트 기준)이라 합쳐 보낸다 — 중복은 한 번.
        for (const f of wtChanged) if (!changed.includes(f)) changed.push(f);
        changed = changed.slice(0, 50);
      }

      // 보내는 것: 도구 이름 · 이번에 새로 바뀐 레포 상대경로 · 결과 크기 · 새 커밋 번호.
      //    명령어 원문·파일 본문·도구 출력·워킹트리 전체 목록은 보내지 않는다.
      const resp = ev.tool_response;
      const respBytes = typeof resp === "string" ? resp.length : resp == null ? 0 : JSON.stringify(resp).length;

      // 팀핑 작업 집기 도구(claim_work · claim_file · submit_manifest(claim:"me"))면 집은 카드 id 를 함께 보낸다.
      //   보내는 것은 uuid 하나뿐이고, 형식이 맞지 않으면 보내지 않는다.
      const CLAIM_TOOL = /^mcp__.+__(claim_work|claim_file|submit_manifest)$/;
      const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
      let claimedManifestId = null;
      const cm = CLAIM_TOOL.exec(tool);
      if (cm) {
        const ti = ev.tool_input && typeof ev.tool_input === "object" ? ev.tool_input : {};
        let cand = null;
        if (cm[1] !== "submit_manifest") cand = ti.manifestId;
        else if (ti.claim === "me") {
          const text = typeof resp === "string" ? resp : resp == null ? "" : JSON.stringify(resp);
          const mm = /\(id ([0-9a-f-]{36})\)/.exec(text);
          cand = mm ? mm[1] : null;
        }
        if (typeof cand === "string" && UUID.test(cand)) claimedManifestId = cand;
      }

      // 이 도구를 부른 것이 사용자 세션인가 서브에이전트인가 — Claude Code 가 훅 입력에 주는 agent_id 로 가른다.
      //   서브에이전트면 agent_id 가 있고, 없으면 사용자 세션이다.
      //   보내는 것은 그 불투명 id 하나뿐이고, 형식이 맞지 않으면 보내지 않는다.
      const rawAgentId = typeof ev.agent_id === "string" ? ev.agent_id : "";
      const subagentId = /^[A-Za-z0-9_-]{1,64}$/.test(rawAgentId) ? rawAgentId : null;

      // 팀핑 연락 — 이미 AI 에게 넣은 줄의 id 를 「받았다」로 함께 보낸다(서버가 같은 줄을 다시 주지 않게).
      //   팀핑에 글을 쓴 도구면 그 글 id 를 보낸다 — 그 글에 답장이 오면 이 창으로 오게.
      let inbox = null, inboxPaths = null, inboxAck = [];
      try {
        inbox = await import(require("url").pathToFileURL(process.env.TEAMPING_INBOX).href);
        inboxPaths = inbox.inboxPaths(dir, session); // 세션 id 가 모양에 안 맞으면 null
        inboxAck = inbox.acksToSend(inboxPaths);
      } catch { inbox = null; }
      const POST_TOOLS = /^mcp__.+__(post_channel_message|post_thread_message)$/;
      let postedMessageId = null;
      if (POST_TOOLS.test(tool)) {
        const text = typeof resp === "string" ? resp : resp == null ? "" : JSON.stringify(resp);
        const pm = /\(id ([0-9a-f-]{36})\)/.exec(text);
        if (pm && UUID.test(pm[1])) postedMessageId = pm[1];
      }
      const r = await fetch(`${process.env.TEAMPING_BASE}/api/hooks/observe`, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${process.env.TEAMPING_TOKEN}` },
        body: JSON.stringify({
          session_id: session,
          agent: "claude-code",
          tool_name: tool,
          repo_key: process.env.TEAMPING_REPO_KEY,
          changed,
          response_bytes: respBytes,
          subagent_id: subagentId,
          // 집기 도구가 아니면 null.
          claimed_manifest_id: claimedManifestId,
          // 이번 Bash 로 이 기계의 git 사용자가 새로 만든 커밋 번호(0~20 · 번호만).
          commits,
          inbox_ack: inboxAck,
          posted_message_id: postedMessageId,
        }),
        signal: AbortSignal.timeout(4000),
      }).catch(() => null);
      // 서버가 받았으면 「받았다」 id 를 지우고, 새로 온 연락은 맡아 둔다(다음 도구 때 넣는다).
      if (r && r.ok && inbox && inboxPaths) {
        // 할 일이 없으면(보낸 「받았다」도 · 새 연락도 · 맡아 둔 줄도 없음) 이 기계 파일을 건드리지 않는다 — 도구마다 쓰지 않게.
        let j = null;
        try { j = await r.json(); } catch { j = null; }
        const got = j && j.ok === true && Array.isArray(j.inbox) ? j.inbox : [];
        if (j && j.ok === true && (inboxAck.length > 0 || got.length > 0 || fs.existsSync(inboxPaths.pending))) inbox.afterServer(inboxPaths, inboxAck, got);
      }
    } catch { /* 관측 실패는 조용히 — 도구는 이미 실행됐고 우리는 막을 수도 없다 */ }
  });
' >/dev/null 2>&1 &

# 관측은 에이전트에게 말을 걸지 않는다 — 출력은 위의 팀핑 연락 한 줄(있을 때)뿐이다.
exit 0
