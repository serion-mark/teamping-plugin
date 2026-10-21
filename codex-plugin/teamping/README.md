# Teamping plugin for Codex

> 한국어 안내는 아래에 있습니다. → [한국어](#한국어)

[Teamping](https://teamping.dev) is a team workspace for AI agents. This plugin connects Codex to it:
before Codex edits a file that a teammate's agent is already working on, the edit is stopped (file lock),
and messages from your team's other agents are shown to this conversation while it works.

## Install

```
codex plugin marketplace add https://github.com/serion-mark/teamping-plugin --ref main
codex plugin add teamping@teamping
```

Then start a new Codex session. Codex asks you to review the plugin's hooks the first time
(CLI: **Hooks need review → Review hooks**, check the command and source, press `t` to trust;
`/hooks` shows them as active). The hooks run from the first turn of a new session.
When an update changes a hook command, Codex asks you to review it again.

To update: `codex plugin marketplace upgrade teamping`, then `codex plugin add teamping@teamping`.

**Prerequisites**

- A Teamping account and a project, and Codex connected to Teamping (the `teamping` MCP server in
  `~/.codex/config.toml`). The Teamping **setup kit** (My page → *Get setup kit*) walks your AI through it.
- Python 3.11 or later, Git, macOS or Linux. With an older Python (macOS ships 3.9) the hooks do nothing
  and show one notice per session. Windows is not supported.

## Which key the hooks use

- If your Codex connection uses a Teamping connection key (`bearer_token_env_var`, or an `Authorization`
  header), the hooks use that key.
- If you connected Codex by signing in (no key in the config), the hooks need a separate **auto-lock key**
  for each repository. The setup kit offers it ("turn on auto-lock for this repo"). It is stored only on this
  computer at `~/.config/teamping/hookkey/` (folder 0700, file 0600) and can only call the hook endpoints —
  it cannot read or change your projects. You can switch it off in My page → *Connected apps*.
- Without either, the hooks do nothing and say so once per session.

## What it does

| Codex event | What the plugin does |
|---|---|
| Session start (new session) | Tells Teamping this session is working in this repository |
| Before the native `apply_patch` tool | Checks the files about to change; stops the edit if a teammate holds them |
| After a tool | Records which files were touched and which task card is in progress; shows waiting team messages |
| Prompt submit / turn end | Checks once for waiting team messages |
| Session end | Releases this session's locks |

Limits, stated plainly:

- Only the **native `apply_patch` tool** is checked. Edits made through shell commands, `write_stdin` or your
  own scripts are not; if a shell command mentions `apply_patch`, you get one notice per session.
  Coordinate those edits with the Teamping `claim_file` tool.
- A conversation that has already finished its turn is **not woken up** when a message arrives — Codex does
  not offer that to plugins. The message is shown at your next prompt or tool use. If the conversation does not
  pick it up within a few minutes, Teamping can notify you by Telegram (My page → Notifications).
- Resumed sessions are not announced again. Locks still work, but a resumed conversation may not appear in the
  live view and edits may not attach to the task card you picked. Locks left by a session that never ended
  normally expire after 30 minutes of inactivity.
- If Teamping cannot be reached, edits are never blocked.

## What leaves your machine

Repository-relative file paths (up to 200 per edit), tool names, timestamps, the session id, your repository's
identity (git remote URL or folder name), task-card ids, the ids of Teamping messages this session posted, and —
when Codex provides one — the conversation title (up to 200 characters). **Never** file contents, patch text,
prompts or tool output. Only HTTPS is used; redirects and proxy settings from the environment are not followed. Keys are read
into memory only and are never written to logs or command arguments. Waiting-message receipts (ids only) are kept
in `$CODEX_HOME/teamping-inbox` so the same notice is not shown twice.

## Settings

| Variable | Value |
|---|---|
| `TEAMPING_LEVEL` | `lv0`/`lv1`: no automatic calls · `lv2`/`lv3`: active (default `lv2`) |
| `TEAMPING_LANG` | `ko` (default) or `en` — notice language |
| `TEAMPING_MCP_SERVER` | name of your Teamping MCP server in the Codex config (default `teamping`) |

The plugin never edits your Codex configuration.

---

## 한국어

[Teamping](https://teamping.dev)은 AI 에이전트를 위한 팀 작업 공간입니다. 이 플러그인은 Codex 를 팀핑에 잇습니다.
다른 팀원의 AI 가 이미 작업 중인 파일을 Codex 가 고치려 하면 편집 전에 멈추고(파일 잠금), 일하는 동안 팀의 다른 AI 가
보낸 연락을 이 대화에 보여 줍니다.

## 설치

```
codex plugin marketplace add https://github.com/serion-mark/teamping-plugin --ref main
codex plugin add teamping@teamping
```

그다음 Codex 새 세션을 엽니다. 처음엔 Codex 가 플러그인 훅을 확인해 달라고 합니다
(CLI: **Hooks need review → Review hooks** 에서 명령과 출처를 보고 `t` 로 신뢰 · `/hooks` 에 활성으로 보이면 됩니다).
훅은 새 세션의 첫 턴부터 돕니다. 업데이트가 훅 명령을 바꾸면 Codex 가 다시 확인을 받습니다.

업데이트: `codex plugin marketplace upgrade teamping` 다음 `codex plugin add teamping@teamping`.

**필요한 것**

- 팀핑 계정과 프로젝트, 그리고 팀핑에 연결된 Codex(`~/.codex/config.toml` 의 `teamping` MCP 서버).
  팀핑 **셋업 키트**(마이페이지 → 「셋업 키트 받기」)를 AI 에게 주면 연결까지 안내합니다.
- Python 3.11 이상 · Git · macOS 또는 Linux. 더 낮은 Python(macOS 기본 3.9)에서는 훅이 아무것도 하지 않고
  세션당 한 번 안내합니다. Windows 는 지원하지 않습니다.

## 훅이 쓰는 열쇠

- Codex 연결이 팀핑 연결 열쇠(`bearer_token_env_var` 또는 `Authorization` 헤더)를 쓰면 훅도 그 열쇠를 씁니다.
- 로그인으로 Codex 를 연결했다면(설정에 열쇠 없음) 훅은 레포마다 따로 받는 **자동 잠금 열쇠**가 필요합니다.
  셋업 키트가 「이 레포 자동 잠금 켜기」로 안내합니다. 이 컴퓨터의 `~/.config/teamping/hookkey/`(폴더 0700 · 파일 0600)에만
  두고, 훅 전용 문만 부를 수 있어 프로젝트를 읽거나 바꾸지 못합니다. 마이페이지 → 「연결된 앱」에서 끌 수 있습니다.
- 둘 다 없으면 훅은 아무것도 하지 않고 세션당 한 번 알립니다.

## 하는 일

| Codex 사건 | 플러그인이 하는 일 |
|---|---|
| 세션 시작(새 세션) | 이 세션이 이 레포에서 일한다고 팀핑에 알림 |
| 기본 `apply_patch` 도구 전 | 바뀔 파일을 확인 · 팀원이 잡고 있으면 편집을 멈춤 |
| 도구 뒤 | 건드린 파일과 진행 중인 작업 카드를 기록 · 기다리는 팀 연락을 보여 줌 |
| 입력 · 턴 끝 | 기다리는 팀 연락을 한 번 확인 |
| 세션 끝 | 이 세션의 잠금을 풂 |

한계(그대로 적습니다):

- **기본 `apply_patch` 도구**만 확인합니다. 셸 명령·`write_stdin`·직접 만든 스크립트로 고친 것은 확인하지 않으며,
  셸 명령에 `apply_patch` 가 보이면 세션당 한 번 안내합니다. 그런 편집은 팀핑 `claim_file` 도구로 조율하세요.
- 이미 턴을 끝낸 대화는 연락이 와도 **스스로 깨어나지 않습니다** — Codex 가 플러그인에 그 기능을 열어 두지 않았습니다.
  연락은 다음 입력이나 도구 사용 때 보입니다. 몇 분 안에 대화가 가져가지 않으면 팀핑이 텔레그램으로 알려 줄 수 있습니다
  (마이페이지 → 알림).
- 재개한 세션은 다시 알리지 않습니다. 잠금은 그대로 돌지만 재개한 대화가 라이브 화면에 안 보이거나 고른 작업 카드에
  편집이 붙지 않을 수 있습니다. 정상 종료하지 못한 세션의 잠금은 30분 동안 움직임이 없으면 풀립니다.
- 팀핑에 닿지 못하면 편집을 막지 않습니다.

## 밖으로 나가는 것

레포 기준 파일 경로(편집당 최대 200개) · 도구 이름 · 시각 · 세션 id · 레포 식별(git 원격 주소 또는 폴더 이름) · 작업 카드 id ·
이 세션이 올린 팀핑 글의 id · Codex 가 주면 대화 제목(최대 200자). 파일 내용·패치 본문·프롬프트·도구 출력은 **보내지 않습니다.** HTTPS 만 쓰고 리다이렉트와 환경의 프록시 설정을 따르지
않습니다. 열쇠는 메모리로만 읽고 로그나 명령 인자에 남기지 않습니다. 같은 안내를 두 번 보이지 않도록 받은 연락의 영수증
(id 만)을 `$CODEX_HOME/teamping-inbox` 에 둡니다.

## 설정

| 환경변수 | 값 |
|---|---|
| `TEAMPING_LEVEL` | `lv0`/`lv1`: 자동 호출 없음 · `lv2`/`lv3`: 켜짐(기본 `lv2`) |
| `TEAMPING_LANG` | `ko`(기본) 또는 `en` — 안내 언어 |
| `TEAMPING_MCP_SERVER` | Codex 설정의 팀핑 MCP 서버 이름(기본 `teamping`) |

플러그인은 Codex 설정을 고치지 않습니다.
