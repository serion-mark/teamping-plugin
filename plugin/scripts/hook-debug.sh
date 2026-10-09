#!/bin/bash
# 팀핑 훅이 Claude Code로부터 **실제로 무엇을 받는지** 보여주는 진단 도구. 평소엔 꺼져 있다.
#
# 켜는 법:
#   export TEAMPING_HOOK_DEBUG=~/teamping-hook-input.jsonl    # 파일 경로를 값으로
#   (새 창을 열 필요 없다 — 훅은 매번 이 스크립트를 새로 읽는다)
# 끄는 법: 환경변수를 지우거나 창을 닫는다.
#
# 팀핑이 훅에서 무엇을 받는지 사용자가 직접 확인할 수 있게 하려는 도구다.
#
# ⚠️ 값은 저장하지 않는다 — 키 이름과 타입/길이만.
#   훅 입력에는 명령어 원문(tool_input)과 도구 결과 본문(tool_response)이 들어 있어,
#   비밀이 파일에 남지 않도록 구조만 기록한다. 기록 파일은 본인만 읽을 수 있게(0600) 둔다.
set -uo pipefail

[ -n "${TEAMPING_HOOK_DEBUG:-}" ] || exit 0   # 꺼져 있으면 여기서 끝
command -v node >/dev/null 2>&1 || exit 0     # 진단이 작업을 막으면 안 된다

OUT="$TEAMPING_HOOK_DEBUG"
mkdir -p "$(dirname "$OUT")" 2>/dev/null || exit 0

node -e '
  let s = "";
  process.stdin.on("data", (d) => (s += d));
  process.stdin.on("end", () => {
    try {
      const ev = JSON.parse(s);
      // 값을 옮기지 않는다. "무엇이 왔나"만 요약한다.
      const shape = (v) => {
        if (v === null) return "null";
        if (Array.isArray(v)) return `array(${v.length})`;
        if (typeof v === "object") return `object{${Object.keys(v).join(",")}}`;
        if (typeof v === "string") return v.length === 0 ? "string(empty)" : `string(len=${v.length})`;
        return typeof v;
      };
      const keys = {};
      for (const [k, v] of Object.entries(ev)) keys[k] = shape(v);
      process.stdout.write(JSON.stringify({
        ts: new Date().toISOString(),
        event: typeof ev.hook_event_name === "string" ? ev.hook_event_name : null,
        tool: typeof ev.tool_name === "string" ? ev.tool_name : null,
        // 서브에이전트에서 온 호출인지 — 값이 아니라 유무·형태만.
        is_subagent: typeof ev.agent_id === "string" && ev.agent_id.length > 0,
        agent_type: typeof ev.agent_type === "string" ? ev.agent_type : null,
        keys,
      }) + "\n");
    } catch { /* 파싱 실패는 조용히 */ }
  });
' >> "$OUT" 2>/dev/null

chmod 600 "$OUT" 2>/dev/null || true
exit 0
