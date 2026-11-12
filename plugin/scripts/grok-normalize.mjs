#!/usr/bin/env node
// 팀핑 플러그인 — Grok Build 훅 입력의 도구 이름을 Claude Code 이름으로 바꾼다(grok-input.sh 가 부른다).
//
// stdin = 훅 입력 JSON. 최상위에 Grok 모양 칸(hookEventName 문자열)이 있을 때만 바꾼 JSON 을 stdout 에 낸다.
// 아니면 아무것도 내지 않고 끝낸다(부르는 쪽이 원래 입력을 그대로 쓴다). 어떤 오류도 같은 결 — 훅이 사용자 작업을 막지 않는다.
//
// 이름 표(grok 1.0.77 에서 확인):
//   write                → Write  (tool_input.file_path 절대 · content)
//   search_replace       → Edit   (tool_input.file_path · old_string · new_string)
//   run_terminal_command → Bash   (tool_input.command)
// MCP 도구는 Grok 이 `<서버>__<도구>`(예: teamping__claim_work)로 부른다 → Claude 모양 `mcp__<서버>__<도구>` 로 바꾼다
//   (집기·글 쓰기 관측이 그 모양을 본다 · posttooluse-observe.sh). 그 밖의 이름(read_file·list_dir 등)은 그대로 둔다.
// ⛔ 입력의 다른 칸은 건드리지 않는다(session_id·cwd·tool_input 그대로).

export const GROK_TOOL_NAMES = Object.freeze({
  write: "Write",
  search_replace: "Edit",
  run_terminal_command: "Bash",
});

/** Grok 의 MCP 도구 이름 모양 — 서버 이름(글자·숫자·-·_)과 도구 이름 사이에 밑줄 둘(teamping_work__claim_work 도). */
const GROK_MCP_NAME = /^(?=.{1,256}$)[A-Za-z0-9][A-Za-z0-9_-]*__[A-Za-z0-9_]+$/; // 길이 상한 — 긴 이름에서 되짚기가 길어지지 않게

/** 훅 입력 객체 → 바꾼 객체(Grok 모양이 아니면 null). */
export function normalizeGrokInput(input) {
  if (!input || typeof input !== "object" || Array.isArray(input)) return null;
  if (typeof input.hookEventName !== "string" || !input.hookEventName) return null;
  const out = { ...input };
  if (typeof out.tool_name === "string" && Object.prototype.hasOwnProperty.call(GROK_TOOL_NAMES, out.tool_name)) {
    out.tool_name = GROK_TOOL_NAMES[out.tool_name];
  } else if (typeof out.tool_name === "string" && !out.tool_name.startsWith("mcp__") && GROK_MCP_NAME.test(out.tool_name)) {
    out.tool_name = `mcp__${out.tool_name}`;
  }
  return out;
}

const isMain = (() => {
  try {
    return import.meta.url === new URL(`file://${process.argv[1]}`).href || process.argv[1]?.endsWith("grok-normalize.mjs");
  } catch {
    return false;
  }
})();

if (isMain) {
  let raw = "";
  try {
    for await (const chunk of process.stdin) raw += chunk;
    const out = normalizeGrokInput(JSON.parse(raw));
    if (out) process.stdout.write(JSON.stringify(out));
  } catch {
    /* 아무것도 내지 않는다 */
  }
}
