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
        let prev = null;
        try { prev = JSON.parse(fs.readFileSync(stateFile, "utf8")); } catch { prev = null; }
        try {
          // ⚠️ mode를 명시한다 — 안 주면 프로세스 기본 umask로 0755/0644가 되어(적대검증 WARN·실측)
          //    **이 파일이 애초에 막으려던 것이 로컬 파일권한으로는 그대로 열린다.** 담긴 내용이
          //    "바뀐 파일 경로 목록"이라 발명요지서·IR 같은 민감 파일명이 여기 남는다.
          //    ⚠️ mkdirSync의 mode도 기존 디렉토리엔 안 먹으므로 chmod로 되돌린다(형제 tok/과 같은 함정).
          fs.mkdirSync(stateDir, { recursive: true, mode: 0o700 });
          try { fs.chmodSync(stateDir, 0o700); } catch {}
          fs.writeFileSync(stateFile, JSON.stringify(now.slice(0, 500)), { mode: 0o600 });
          try { fs.chmodSync(stateFile, 0o600); } catch {}
        } catch { /* 상태를 못 써도 관측은 계속한다(다음 번에 다시 기준선이 될 뿐) */ }
        if (prev === null) {
          // 첫 실행 = 기준선. "세션 시작 시점에 이미 있던 변경"을 이 도구가 한 일로 적지 않는다.
          changed = [];
        } else {
          const before = new Set(prev);
          changed = now.filter((p) => !before.has(p)).slice(0, 50);
        }
      }

      // ⚠️ 보내는 것: 도구 이름 · **이번에 새로 바뀐** 레포 상대경로 · 결과 크기.
      //    명령어 원문·파일 본문·도구 출력·워킹트리 전량은 보내지 않는다.
      const resp = ev.tool_response;
      const respBytes = typeof resp === "string" ? resp.length : resp == null ? 0 : JSON.stringify(resp).length;

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
        }),
        signal: AbortSignal.timeout(4000),
      }).catch(() => {});
    } catch { /* 관측 실패는 조용히 — 도구는 이미 실행됐고 우리는 막을 수도 없다 */ }
  });
' >/dev/null 2>&1 &

# ⭐ 아무것도 출력하지 않는다. PostToolUse의 stdout/stderr·exit 2는 에이전트에게 말을 걸 수 있는데,
#    관측은 말할 것이 없다(그리고 말하는 순간 그건 더 이상 관측이 아니다).
exit 0
