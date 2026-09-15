#!/bin/bash
# 팀핑 훅이 Claude Code로부터 **실제로 무엇을 받는지** 보여준다. 평소엔 꺼져 있다.
#
# 켜는 법:
#   export TEAMPING_HOOK_DEBUG=~/teamping-hook-input.jsonl    # 파일 경로를 값으로
#   (새 창을 열 필요 없다 — 훅은 매번 이 스크립트를 새로 읽는다)
# 끄는 법: 환경변수를 지우거나 창을 닫는다.
#
# ⭐⭐ 왜 제품에 넣나:
#   우리는 훅 입력을 볼 방법이 없어서, 매번 **코드를 읽고 추측한 뒤**
#   구현 → PR → 배포 → 플러그인 전파 → 새 창 → 실증 사이클을 돌았다. 한 바퀴가 반나절이고,
#   16-5는 그렇게 **두 번 틀렸다**(`transcript_path`가 서브에이전트를 가리킬 거라는 추측).
#   한 번 직접 보니 5분 만에 끝났다 — *"순서를 바꾸면 쉽게 풀릴 수도 있다"*.
#   그 도구를 일회성으로 버리지 않고 제품에 남긴다.
#
#   고객에게도 같은 값이 있다: `data-boundary.md`는 *"믿어달라 하지 않는다"* 고 말하는데,
#   이건 **"우리가 무엇을 받는지 당신이 직접 보라"** 는 그 약속의 실물이다.
#
# ⚠️ **값은 저장하지 않는다 — 키 이름과 타입/길이만.**
#   훅 입력에는 `tool_input`(명령어 원문)과 `tool_response`(도구 결과 본문)가 들어 있다.
#   그대로 남기면 절대규칙("비밀을 화면에 찍지 마라")을 진단 도구가 어기는 꼴이 된다.
#   알고 싶은 건 "무슨 필드가 오는가 · 비어 있지 않은가"뿐이고, 구조만으로 답이 된다.
set -uo pipefail

[ -n "${TEAMPING_HOOK_DEBUG:-}" ] || exit 0   # ⭐ 꺼져 있으면 여기서 끝 — 프로세스 0개
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
        // ⭐ 팀핑이 실제로 쓰는 판별자 — 값이 아니라 유무·형태만.
        is_subagent: typeof ev.agent_id === "string" && ev.agent_id.length > 0,
        agent_type: typeof ev.agent_type === "string" ? ev.agent_type : null,
        keys,
      }) + "\n");
    } catch { /* 파싱 실패는 조용히 */ }
  });
' >> "$OUT" 2>/dev/null

chmod 600 "$OUT" 2>/dev/null || true
exit 0
