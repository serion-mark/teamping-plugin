# Teamping for Antigravity

Automatic file locks for Antigravity (Google Gemini's coding tool). Before Antigravity's AI edits a file, Teamping checks whether a teammate's AI is working on it. If so, the edit stops and your AI is told who holds the file.

## What it needs

- A Teamping connection with a key in `~/.gemini/config/mcp_config.json`, or in the Antigravity app's `~/.gemini/antigravity/mcp_config.json` (the first file that has a Teamping entry is used — see https://teamping.dev/connect#antigravity). The plugin reuses that key and stores nothing else. A key in a project's `.agents/mcp_config.json` connects MCP but is not used for locks, because a project file may come from someone else's repository. A connection without a key (quick connect) has no key for the hooks, so edits go through unlocked.
- Node.js 18 or later on the `PATH` Antigravity uses to run hooks. Without it the hook can't run. What Antigravity does when an editing hook can't run hasn't been checked yet.

## Install

macOS and Linux, with the Antigravity CLI (`agy`) on your `PATH`. Run this, then start a new Antigravity conversation:

```bash
d="$(mktemp -d)" && git clone --depth 1 https://github.com/serion-mark/teamping-plugin "$d/r" && agy plugin install "$d/r/antigravity-plugin/teamping"; rm -rf "$d"
```

The plugin is copied to `~/.gemini/config/plugins/teamping`. Run the command again to update. To turn it off, run `agy plugin disable teamping`; to turn it back on, run `agy plugin enable teamping` (installing again does not turn a disabled plugin back on). Checked with Antigravity CLI 1.5.7; whether the Antigravity app picks up the same plugin has not been checked yet.

## What it covers

- Edits with `write_file` and `edit_file` (checked in Antigravity CLI 1.5.7) and with `write_to_file`, `replace_file_content` and `multi_replace_file_content` (the names in Antigravity's hooks documentation, not yet checked directly), and files a `run_command` shell command writes to (only the file paths are sent — never the command).
- Locks go to the project of that key, whichever repository you edit. To edit a repository in another Teamping project, switch to that project's key and start a new conversation.
- After an edit, the edited file is recorded. When your AI claims a work card with Teamping's `claim_work`, files it edits are attached to that card.
- Antigravity has no end-of-conversation event, so a conversation's locks are released after 30 minutes without activity.
- If the server can't be reached within about 2 seconds, or anything goes wrong, the edit goes ahead. The plugin only ever answers `deny` (when a teammate holds the file); otherwise it outputs nothing, so Antigravity's own permission rules decide as usual. It never answers `allow` or `auto_approve`. With `agy -p`, edits went ahead with no output; how no output affects permission prompts in an interactive conversation hasn't been checked yet.
- It sends repository-relative file paths, the tool name and a conversation marker. File contents, command text and your prompts are not sent.

---

# 팀핑 — Antigravity 용

Antigravity(Google Gemini 의 코딩 도구)의 자동 파일 잠금입니다. Antigravity 의 AI 가 파일을 고치기 직전에 다른 팀원의 AI 가 그 파일을 작업 중인지 팀핑에 묻습니다. 작업 중이면 편집을 멈추고 누가 잡고 있는지 AI 에게 알려 줍니다.

## 필요한 것

- `~/.gemini/config/mcp_config.json` 또는 Antigravity 앱의 `~/.gemini/antigravity/mcp_config.json` 에 열쇠로 넣은 팀핑 연결(팀핑 항목이 있는 앞의 파일 · https://teamping.dev/connect#antigravity). 플러그인은 그 열쇠를 그대로 쓰고 다른 것은 저장하지 않습니다. 프로젝트의 `.agents/mcp_config.json` 에 넣은 열쇠는 MCP 연결에는 쓰이지만 잠금에는 쓰지 않습니다 — 남의 레포에서 온 파일일 수 있어서입니다. 열쇠 없는 연결(간편 연결)은 훅이 쓸 열쇠가 없어 잠금 없이 진행됩니다.
- Antigravity 가 훅을 돌리는 `PATH` 에 Node.js 18 이상. 없으면 훅이 돌지 못합니다. 편집 전 훅이 돌지 못할 때 Antigravity 가 어떻게 하는지는 아직 확인하지 못했습니다.

## 설치

macOS · Linux 에서, Antigravity CLI(`agy`)가 `PATH` 에 있어야 합니다. 아래를 실행한 뒤 Antigravity 에서 새 대화를 여세요:

```bash
d="$(mktemp -d)" && git clone --depth 1 https://github.com/serion-mark/teamping-plugin "$d/r" && agy plugin install "$d/r/antigravity-plugin/teamping"; rm -rf "$d"
```

플러그인은 `~/.gemini/config/plugins/teamping` 으로 복사됩니다. 다시 실행하면 새 판으로 바뀝니다. 끄려면 `agy plugin disable teamping`, 다시 켜려면 `agy plugin enable teamping` 을 실행하세요(다시 설치해도 꺼 둔 플러그인은 켜지지 않습니다). Antigravity CLI 1.5.7 에서 확인했고, Antigravity 앱이 같은 플러그인을 쓰는지는 아직 확인하지 못했습니다.

## 하는 일

- `write_file` · `edit_file` 편집(Antigravity CLI 1.5.7 에서 확인)과 `write_to_file` · `replace_file_content` · `multi_replace_file_content` 편집(Antigravity 훅 문서의 이름 · 아직 직접 확인 못 함), 그리고 `run_command` 셸 명령이 쓰는 파일(파일 경로만 보냅니다 — 명령 원문은 보내지 않습니다).
- 어느 레포를 고치든 잠금은 그 열쇠의 프로젝트로 갑니다. 다른 팀핑 프로젝트의 레포를 고칠 땐 그 프로젝트의 열쇠로 바꾸고 새 대화를 여세요.
- 편집한 뒤 고친 파일을 기록합니다. AI 가 팀핑 `claim_work` 로 작업 카드를 집으면 그 뒤 고친 파일이 그 카드에 붙습니다.
- Antigravity 에는 대화가 끝났다는 신호가 없어서, 대화의 잠금은 30분 동안 움직임이 없으면 풀립니다.
- 서버에 2초쯤 안에 닿지 않거나 무슨 일이 생기면 편집은 그대로 진행됩니다. 플러그인은 다른 팀원이 파일을 잡고 있을 때만 `deny` 로 답하고, 그 밖에는 아무것도 출력하지 않아 Antigravity 의 평소 권한 규칙이 그대로 정합니다. `allow`·`auto_approve` 는 쓰지 않습니다. `agy -p` 에서는 출력이 없을 때 편집이 그대로 진행됐고, 대화형에서 권한 묻기에 어떻게 작용하는지는 아직 확인하지 못했습니다.
- 레포 기준 파일 경로 · 도구 이름 · 대화 표식만 보냅니다. 파일 내용 · 명령 원문 · 프롬프트는 보내지 않습니다.
