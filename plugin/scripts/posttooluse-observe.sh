#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 팀핑 플러그인 — PostToolUse 훅(Phase 16-1 관측 확장).
#
# 무엇: 도구가 **실행된 뒤** 무엇을 바꿨는지 기록만 한다. 판정하지 않는다.
#
# ⭐ 왜 PreToolUse가 아닌가 (결정 D1·D2):
#   ① 차단과 관측은 다른 일이다. Bash엔 file_path가 없어 명령어를 파싱해야 하는데 쉘 확장·
#      파이프·heredoc 때문에 정확한 파싱이 불가능하다. 그 위에서 차단하면 오탐이 곧 오탐 차단이
#      되고, 락 훅 제1원칙("팀 도구가 개인 작업을 막으면 삭제된다") 정면 위반이다.
#   ② PostToolUse는 도구를 되돌릴 수 없다(이미 실행된 뒤 호출된다).
#   ③ 유입 기록(Phase 19)도 결과를 봐야 하므로 어차피 이 자리가 필요하다.
#
# ⭐ 왜 명령어 텍스트를 안 보고 git에게 묻나 (16-2 리플레이 실측):
#   명령어에 패턴을 대면 "언급"과 "접근"이 안 갈린다(.env 매칭 1,050건 vs .pem 0건).
#   바뀐 파일은 **git이 말하게 한다** — heredoc·변수·파이프에 영향받지 않는다.
#
# ⭐⭐ 데이터 경계(적대검증 BLOCK-3): 워킹트리 **전량**을 보내면 안 된다.
#   초판은 `git status` 결과를 통째로 보냈고, 이 레포에서 발명요지서·IR 자료 파일명 31건이
#   실제로 나갔다. → **delta를 여기서 계산해 "이번에 새로 바뀐 것"만 보낸다.**
#   상태 파일은 프로젝트 밖(캐시)에 둔다 — 안에 두면 git status가 그걸 또 잡아 순환한다.
#
# 제1원칙: **무슨 일이 있어도 도구 실행을 방해하지 않는다.** 모든 실패는 조용히 exit 0.
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

# 🔍 진단 모드 — TEAMPING_HOOK_DEBUG가 켜져 있을 때만 "무엇을 받았는지" 구조를 남긴다.
#    꺼져 있으면 hook-debug.sh가 첫 줄에서 끝나므로 비용은 사실상 0이다(지연 게이트 유지).
[ -n "${TEAMPING_HOOK_DEBUG:-}" ] && printf '%s' "$INPUT" | "$(dirname "$0")/hook-debug.sh" 2>/dev/null

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

# ⚠️ 토큰은 형제 훅 4개와 **똑같은 방식**으로 받는다(적대검증 BLOCK-1).
#    초판은 `. resolve-token.sh` 로 source했는데, 그 스크립트는 값을 stdout으로 내고 `exit 0`으로
#    끝나므로 **source하면 이 스크립트가 그 자리에서 죽고 토큰이 stdout으로 샜다.**
CREDS="$(bash "$(dirname "${BASH_SOURCE[0]}")/resolve-token.sh")"
TOKEN="$(printf '%s\n' "$CREDS" | sed -n 's/^TEAMPING_TOKEN=//p')"
BASE="$(printf '%s\n' "$CREDS" | sed -n 's/^TEAMPING_BASE=//p')"
[ -n "$TOKEN" ] || exit 0

REPO_KEY="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || true)"
[ -n "$REPO_KEY" ] || REPO_KEY="$(basename "$PROJECT_DIR")"

# ⭐ 여기서부터 백그라운드 — 훅이 붙잡는 시간은 위까지다(git·네트워크는 그쪽에서).
#    ⚠️ setsid는 macOS에 없다(초판 주석이 거짓이었다·적대검증 W6). `&` + nohup 만으로 충분하다.
export TEAMPING_TOKEN="$TOKEN" TEAMPING_BASE="$BASE" TEAMPING_PROJECT_DIR="$PROJECT_DIR" TEAMPING_REPO_KEY="$REPO_KEY"
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
      // ⭐ 0.2.18(25-2 S2) — 이번 Bash 로 **새로 만든 커밋 번호**. 없으면 빈 배열(키는 늘 보낸다 — 서버가 옛 플러그인과 가른다).
      let commits = [];
      if (MUTATORS.test(tool) && session) {
        let now = [];
        try {
          // ⭐⭐ 프로젝트 **밖** 파일이 새어나가지 않게 (락엔 있고 관측엔 없던 비대칭).
          //   `git status --porcelain` 은 **레포 루트 기준**으로 답한다 — `-C dir` 를 줘도 그렇다.
          //   그래서 프로젝트 폴더가 레포 루트가 아니면(모노레포 하위 패키지, 홈 디렉토리 자체가
          //   git 레포인 경우) **프로젝트 밖 파일 이름이 그대로 딸려 나온다.**
          //   실측 재현: 레포 루트에 `발명요지서.md`, 프로젝트가 `sub/` 일 때 그 파일명이 목록에 들어왔다.
          //
          //   ① pathspec `-- .` 로 **git이 애초에 프로젝트 밖을 안 뱉게** 한다(인자 하나·비용 0).
          //   ② 남는 경로는 여전히 레포 루트 기준이라(`sub/x.ts`) 프로젝트 기준으로 바꾼다.
          //      `data-boundary.md`가 *"프로젝트 기준 상대경로로 변환해서 보낸다"* 고 적어둔 것을
          //      사실로 만드는 부분 — 우리 레포는 프로젝트=레포루트라 그동안 차이가 안 드러났다.
          //   ③ 그래도 접두사 밖으로 나가는 경로는 **버린다**(이중 방어 — 락의 `startsWith("..")`와 같은 정신).
          //   ⚠️ git을 한 번 더 부르지만 이 코드는 **백그라운드**(nohup … &)에서 돈다.
          //      동기 구간이 아니라 지연 게이트(p95 +5ms)에 영향이 없다.
          let prefix = "";
          try {
            prefix = execFileSync("git", ["-C", dir, "--no-optional-locks", "rev-parse", "--show-prefix"], {
              encoding: "utf8", timeout: 3000,
            }).trim();
          } catch { prefix = ""; }

          const out = execFileSync("git", ["-C", dir, "--no-optional-locks", "status", "--porcelain", "-z", "--", "."], {
            encoding: "utf8", timeout: 3000, maxBuffer: 1 << 20,
          });
          // -z: NUL 구분. rename(R)은 "새경로\0옛경로" 두 항목으로 오므로 **뒤따르는 옛 경로를 건너뛴다**
          // (적대검증 W1: 초판은 옛 경로에도 slice(3)을 먹여 훼손된 가짜 경로를 만들었다).
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

        // ⭐ delta를 **여기서** 계산한다. 워킹트리 전량을 서버로 보내지 않는다(BLOCK-3).
        //    상태 파일은 프로젝트 **밖**(캐시)에 — 안에 두면 git status가 그걸 또 잡는다.
        const key = crypto.createHash("sha256").update(`${dir}::${session}`).digest("hex").slice(0, 32);
        const stateDir = path.join(os.homedir(), ".cache", "teamping", "observe");
        const stateFile = path.join(stateDir, `${key}.json`);
        let prevState = null;
        try { prevState = JSON.parse(fs.readFileSync(stateFile, "utf8")); } catch { prevState = null; }
        // 0.2.17 까지 상태 파일은 경로 배열이었다 — 그 모양도 읽는다(업데이트 직후 첫 도구가 기준선을 잃지 않게).
        const prev = Array.isArray(prevState) ? prevState : prevState && Array.isArray(prevState.files) ? prevState.files : null;
        // ⛔ 상태 파일에서 읽은 값은 git **인자**로 들어간다 — 40자 16진수가 아니면 버린다(`--output=…` 같은 값이 옵션으로 읽히지 않게).
        const prevHeadRaw = prevState && !Array.isArray(prevState) && typeof prevState.head === "string" ? prevState.head : "";
        const prevHead = /^[0-9a-f]{40}$/.test(prevHeadRaw) ? prevHeadRaw : null;
        // 직전 관측 시각(초) — 이보다 **먼저 만들어진** 커밋은 이번 명령이 만든 것이 아니다(병합·빨리감기로 들어온 옛 커밋).
        const prevAt = prevState && !Array.isArray(prevState) && Number.isSafeInteger(prevState.at) ? prevState.at : null;
        // ⭐ 커밋도 **git 에게 묻는다**(명령어 텍스트를 보지 않는다 — 위 머리말의 원칙). 지금 HEAD 를 적어 두고,
        //    Bash 뒤에 앞으로 움직였으면 그 사이 커밋 중 **이 기계의 git 사용자가 만든 것**만 보낸다.
        // 관측 시각은 HEAD 를 읽기 **직전**에 찍는다 — 끝에 찍으면 이 훅이 git 을 도는 사이 AI 가 만든 다음 커밋이
        // 이번 HEAD 에도 안 들고 다음 창의 시각보다 앞서 조용히 사라진다(3라운드 결정적 재현).
        const nowAt = Math.floor(Date.now() / 1000);
        let head = null;
        try {
          head = execFileSync("git", ["-C", dir, "--no-optional-locks", "rev-parse", "HEAD"], { encoding: "utf8", timeout: 3000 }).trim();
        } catch { head = null; }
        if (!/^[0-9a-f]{40}$/.test(head || "")) head = null;
        // ⭐ 「AI 가 만든 커밋」으로 좁히는 조건 — 이번 Bash 가 **커밋을 만드는 git 명령**이었을 때만(1차 BLOCK 실측:
        //    사람이 다른 터미널에서 커밋한 뒤 AI 가 아무 Bash 나 돌리면 그 커밋이 「팀핑 자리에서 만든 것」으로 잡혔다 —
        //    한 기계에선 사람과 AI 의 git 사용자가 같다). 텍스트만으로 판정하지 않는다: **명령(의도) AND HEAD 가 앞으로(결과)**
        //    둘 다 맞아야 보낸다(위 머리말이 금지한 것은 텍스트 단독 판정). 명령 원문은 여전히 보내지 않는다.
        //    ⚠️ 한계: 스크립트 안에서 커밋하는 경우(npm run release 등)는 놓친다 — 과소 신고 쪽으로 닫힌다(모르면 안 한다).
        const cmd = ev.tool_input && typeof ev.tool_input.command === "string" ? ev.tool_input.command : "";
        const COMMIT_CMD = /(^|[;&|(\s])git(\s+-[Cc]\s+\S+|\s+--?[\w.-]+(=\S+)?)*\s+(commit|merge|cherry-pick|rebase|revert|am)(?=\s|$|[;&|)])/;
        if (tool === "Bash" && COMMIT_CMD.test(cmd) && prevHead && prevAt !== null && head && prevHead !== head) {
          try {
            // ① 앞으로만 — 브랜치 전환·reset·되감기는 「만든 것」이 아니다(조상이 아니면 git 이 0 이 아닌 값으로 끝나 throw).
            execFileSync("git", ["-C", dir, "merge-base", "--is-ancestor", prevHead, head], { timeout: 3000, stdio: "ignore" });
            // ② 이 기계의 git 사용자 — 비교에만 쓰고 **보내지 않는다**. 없으면 아무것도 안 보낸다(모르면 안 한다).
            const me = execFileSync("git", ["-C", dir, "config", "user.email"], { encoding: "utf8", timeout: 3000 }).trim().toLowerCase();
            if (me) {
              const log = execFileSync("git", ["-C", dir, "--no-optional-locks", "log", "--format=%H%x09%ce%x09%ct", "--max-count=21", `${prevHead}..${head}`], {
                encoding: "utf8", timeout: 3000, maxBuffer: 1 << 20,
              });
              const lines = log.split("\n").filter((l) => l.length > 0);
              // ③ 20 개 넘게 한꺼번에 들어왔으면 pull·merge 로 받은 것 — 통째로 보내지 않는다.
              //    ④ 커밋한 사람이 나인 것만 — AI 가 `git pull` 로 받아 온 동료 커밋이 「팀핑에서 만든 커밋」으로 둔갑하지 않게.
              if (lines.length <= 20) {
                commits = lines
                  .map((l) => l.split("\t"))
                  // ⑤ 커밋 시각이 직전 관측 뒤인 것만 — AI 가 사람의 브랜치를 병합·빨리감기하면 **그 사람의 옛 커밋**이
                  //    「AI 가 만든 것」으로 잡혔다(Opus 2차 BLOCK · 실측 재현). rebase·cherry-pick 은 커밋 시각이 새로 찍혀 그대로 잡힌다.
                  //    ⚠️ 한계: 직전 관측과 이번 명령 **사이에** 사람이 만든 커밋은 못 가른다(한 기계에선 사람과 AI 가 같은 git 사용자).
                  .filter(([h, ce, ct]) => /^[0-9a-f]{40}$/.test(h || "") && (ce || "").trim().toLowerCase() === me && Number(ct) >= prevAt)
                  .map(([h]) => h);
              }
            }
          } catch { commits = []; }
        }
        try {
          // ⚠️ mode를 명시한다 — 안 주면 프로세스 기본 umask로 0755/0644가 되어(적대검증 WARN·실측)
          //    **이 파일이 애초에 막으려던 것이 로컬 파일권한으로는 그대로 열린다.** 담긴 내용이
          //    "바뀐 파일 경로 목록"이라 발명요지서·IR 같은 민감 파일명이 여기 남는다.
          //    ⚠️ mkdirSync의 mode도 기존 디렉토리엔 안 먹으므로 chmod로 되돌린다(형제 tok/과 같은 함정).
          fs.mkdirSync(stateDir, { recursive: true, mode: 0o700 });
          try { fs.chmodSync(stateDir, 0o700); } catch {}
          // 원자적 쓰기(tmp → rename) — 같은 세션의 병렬 도구가 반쯤 쓴 파일을 읽어 기준선을 잃지 않게(1차 WARN).
          const tmp = `${stateFile}.${process.pid}.tmp`;
          fs.writeFileSync(tmp, JSON.stringify({ files: now.slice(0, 500), head, at: nowAt }), { mode: 0o600 });
          try { fs.chmodSync(tmp, 0o600); } catch {}
          fs.renameSync(tmp, stateFile);
        } catch { /* 상태를 못 써도 관측은 계속한다(다음 번에 다시 기준선이 될 뿐) */ }
        if (prev === null) {
          // 첫 실행 = 기준선. "세션 시작 시점에 이미 있던 변경"을 이 도구가 한 일로 적지 않는다.
          changed = [];
        } else {
          const before = new Set(prev);
          changed = now.filter((p) => !before.has(p)).slice(0, 50);
        }
      }

      // ⚠️ 보내는 것: 도구 이름 · **이번에 새로 바뀐** 레포 상대경로 · 결과 크기 · (0.2.18) 새 커밋 번호.
      //    명령어 원문·파일 본문·도구 출력·워킹트리 전량은 보내지 않는다.
      const resp = ev.tool_response;
      const respBytes = typeof resp === "string" ? resp.length : resp == null ? 0 : JSON.stringify(resp).length;

      // ⭐ 0.2.15 — 팀핑 **집기 도구**면 어느 카드를 집었는지 함께 싣는다. 서버는 그동안 「이 창이 방금 집기 도구를
      //    불렀다」는 사실만 받아 10초 창·도구 이름으로 **추정**했다(세션 핀). 카드 id 가 오면 정확 대조다.
      //   · claim_work / claim_file → tool_input.manifestId (사람이 준 인자 그대로)
      //   · submit_manifest(claim:"me") → 응답 첫 줄 「✅ … (id <uuid>)」 의 uuid (서버가 만든 새 카드)
      //   보내는 것은 uuid 하나뿐 — 형식이 아니면 안 보낸다. 값의 진위(이 채널 카드인가 · 지금 담당자가 나인가)는 서버가 판정한다.
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

      // ⭐ 16-5 — 이 도구를 부린 게 사람인가 서브에이전트인가.
      //   부모와 서브에이전트는 **같은 session_id를 쓴다**(실측). 세션으로는 영원히 안 갈라지고,
      //   그래서 검증 에이전트가 판 61건이 전부 사람 이름으로 찍혔다.
      //
      //   ⭐⭐ Claude Code가 **`agent_id`를 준다** — 훅 입력을 실제로 떠서 확인했다:
      //     서브에이전트의 Read → { agent_id: "…"(17자), agent_type: "general-purpose", … }
      //     부모 세션의 Bash   → agent_id **없음**
      //   즉 이 필드는 **있으면 서브에이전트, 없으면 사람**이라는 완벽한 판별자다.
      //   보내는 건 Claude Code가 만든 불투명 id 하나뿐이고, 서버도 같은 형태를 한 번 더 강제한다.
      //   형태가 안 맞으면 **아무것도 안 보낸다** = "모른다". 사람이 한 것으로 둔갑시키지 않는다.
      //
      //   ⚠️ 첫 판은 `transcript_path`에서 `/subagents/agent-<id>.jsonl` 을 파싱했는데
      //      **틀렸다.** 그 값은 **세션 id로 만들어져** 서브에이전트에서도 부모 경로를 가리킨다
      //      (프로덕션 실증: 서브에이전트 3개를 돌려도 귀속 0건 · 훅 입력 실측으로 원인 확정).
      //      디스크에는 `subagents/agent-….jsonl` 이 실제로 있어서 **파일 구조를 보고 전달값을
      //      추론한 것**이 실수였다. 폴백으로도 남기지 않는다 — 원리적으로 안 맞는 코드라 죽은 길이고,
      //      남겨두면 다음 사람이 "둘 중 하나는 되겠지"라고 오해한다.
      //   덤: `agent_id`는 경로가 아니라서 홈 디렉토리를 아예 안 만진다 = 데이터 경계가 더 좁아졌다.
      const rawAgentId = typeof ev.agent_id === "string" ? ev.agent_id : "";
      const subagentId = /^[A-Za-z0-9_-]{1,64}$/.test(rawAgentId) ? rawAgentId : null;
      await fetch(`${process.env.TEAMPING_BASE}/api/hooks/observe`, {
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
          // 0.2.15 — 집기 도구가 아니면 null(키는 항상 보내 서버 시험이 「없음」과 「옛 플러그인」을 가를 수 있게).
          claimed_manifest_id: claimedManifestId,
          // 0.2.18(25-2 S2) — 이번 Bash 로 이 기계의 git 사용자가 새로 만든 커밋 번호(0~20 · 번호만).
          commits,
        }),
        signal: AbortSignal.timeout(4000),
      }).catch(() => {});
    } catch { /* 관측 실패는 조용히 — 도구는 이미 실행됐고 우리는 막을 수도 없다 */ }
  });
' >/dev/null 2>&1 &

# ⭐ 아무것도 출력하지 않는다. PostToolUse의 stdout/stderr·exit 2는 에이전트에게 말을 걸 수 있는데,
#    관측은 말할 것이 없다(그리고 말하는 순간 그건 더 이상 관측이 아니다).
exit 0
