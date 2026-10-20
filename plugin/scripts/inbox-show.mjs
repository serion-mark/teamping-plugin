// ─────────────────────────────────────────────────────────────────────────────
// 팀핑 플러그인 — 맡아 둔 팀핑 연락을 AI 에게 넣는다(훅의 출력으로).
//
//   node inbox-show.mjs PostToolUse       → 도구 결과 뒤에 덧붙인다
//   node inbox-show.mjs UserPromptSubmit  → 사용자 입력 옆에 덧붙인다
//   node inbox-show.mjs Stop              → 턴이 끝나려 할 때 한 번만 붙잡아 읽게 한다
//
// 입력: Claude Code 가 훅에 주는 JSON(stdin). 환경 TEAMPING_PROJECT_DIR.
// 넣는 것은 서버가 만든 한 줄 문장뿐이다(누가 · 무엇이 · 글 id · 읽는 도구). 본문은 없다.
// 서브에이전트 안에서는 넣지 않는다 — 그 줄은 사용자와 이야기하는 창의 AI 가 받아야 한다.
// 실패하면 아무것도 출력하지 않는다(훅은 사용자 작업을 막지 않는다).
// ─────────────────────────────────────────────────────────────────────────────
import { inboxPaths, takePending, formatLines } from "./inbox-local.mjs";

const EVENT = process.argv[2];
let input = "";
process.stdin.on("data", (d) => (input += d));
process.stdin.on("end", () => {
  try {
    const ev = JSON.parse(input);
    const session = typeof ev.session_id === "string" ? ev.session_id : "";
    const dir = process.env.TEAMPING_PROJECT_DIR || "";
    if (!session || !dir) return;
    if (typeof ev.agent_id === "string" && ev.agent_id) return; // 서브에이전트
    if (EVENT === "Stop" && ev.stop_hook_active === true) return; // 이미 한 번 붙잡았다 — 놓아준다
    const lines = takePending(inboxPaths(dir, session));
    if (lines.length === 0) return;
    const text = formatLines(lines);
    if (EVENT === "Stop") {
      process.stdout.write(JSON.stringify({ decision: "block", reason: text }));
    } else if (EVENT === "PostToolUse" || EVENT === "UserPromptSubmit") {
      process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: EVENT, additionalContext: text } }));
    }
  } catch { /* 조용히 */ }
});
