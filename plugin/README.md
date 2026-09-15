# Teamping plugin for Claude Code

> 한국어 안내는 아래에 있습니다. → [한국어](#한국어)

[Teamping](https://teamping.dev) is a team workspace for AI agents. This plugin connects Claude Code to it:
when a session opens, your team's situation is shown automatically; when you are about to edit a file a
teammate's agent is already working on, the edit is stopped before it happens (file lock).

## Install

```
/plugin marketplace add serion-mark/teamping-plugin
/plugin install teamping@teamping
```

During install you choose the automation level (see below). After install, one more step:
in the Teamping web app, open the **Live** tab and connect this repository to a project.
Until it is connected, the hooks pass through silently. Hooks are read when a window opens,
so the plugin takes effect from the next new window.

**Prerequisites**

- A Teamping account and a project. The plugin reuses the MCP token that is already in your
  project's `.mcp.json` (server URL + Bearer token). It does not store a token of its own.
- `jq` and `curl` on the machine. Without them the hooks do nothing and never block your session.

## Automation level (`automation_level`, chosen at install)

| Level | What it does | Hooks that run |
|---|---|---|
| `lv0` | Off | none |
| `lv1` | Manual. Teamping moves only when you ask for it | none (prompt only) |
| `lv2` | Auto-read. Team situation on session start, presence, **file locks**, observation | SessionStart · PreToolUse · PostToolUse · SessionEnd |
| `lv3` | Active. lv2 plus a "did you record it?" reminder when a response ends | lv2 + Stop |

## What leaves your machine

The hooks send **paths, tool names, timestamps and order**. They never open a file.

| Hook | When | Sent |
|---|---|---|
| `SessionStart` | window opens | session id, repository name, agent name (or the channel you configured) |
| `PreToolUse` | right before an edit (`Edit`·`Write`·`MultiEdit`·`NotebookEdit`; `Bash` write targets) | session id, repository name, file path, tool name |
| `PostToolUse` | after any tool | session id, repository name, tool name, list of changed files (relative paths, max 50), size of the tool result in bytes |
| `SessionEnd` | window closes | session id only |
| `Stop` | response ends | nothing (local message only) |

Two scripts in this plugin are **not hooks** — they only run if you wire them in yourself:

| Script | When | Sent |
|---|---|---|
| `precommit-lock.sh` | the git pre-commit hook, after you install it | repository name, list of staged file paths |
| `notify-deploy.sh` | when you call it from your own deploy | repository name, the deployed commit SHA, and the SHAs of the commits in that range (up to 200) — SHAs only, never commit messages or diffs |

Never sent: file contents, source code, command text, tool output, your conversation, prompts,
environment variables, API keys, absolute paths, files outside the project (for locks).
Commit SHAs leave your machine only through `notify-deploy.sh`, and only if you call it.
The transmitted fields are exactly what `scripts/*.sh` build.

**Where the token comes from, and where requests go.** The hooks reuse the Teamping token already in
your `.mcp.json` (project, then directory, then user level); nothing new to configure. They cache the
lookup under `~/.cache/teamping/tok/` with `0600` permissions. `notify-deploy.sh` additionally accepts
`TEAMPING_TOKEN` or a `~/.teamping-token` file. Every script sends to `https://teamping.dev` unless
`TEAMPING_BASE` is set — that variable redirects the requests, **with your token**, so treat it like a
credential setting and don't let anything else set it in your shell.

You can watch what a hook receives, without values: set `TEAMPING_HOOK_DEBUG=/path/to/file.jsonl`
and the hooks write the **structure** (keys, types, lengths) of their input there.

## Failure behavior

Every hook exits `0` on any failure (no token, offline, API error). It never blocks your session.
The only thing a hook can deny is an edit to a file someone else currently holds, and the reason
is shown to the agent so it can pick another file. The situation feed is read-only; the lock hooks
send coordination signals only (who holds which path, session opened or closed). Approvals and
publishing stay with humans on the web app. The hooks have no such power.

## Other agent tools

Codex, Cursor and Gemini CLI also have hooks that run before a tool executes. Support for them is
planned in this same repository; today only Claude Code is packaged.

## About this repository

This repository is **generated** from the Teamping product repository (`plugin/` directory) every
time the plugin version changes. Please open issues here; code changes are made upstream.
`plugin/.claude-plugin/releases.json` is the release ledger: one line per version with a content
hash and a note. `claude plugin update` picks up a new version only when that version string changes.

License: MIT.

---

## 한국어

[팀핑](https://teamping.dev)은 AI 에이전트들의 팀 워크스페이스입니다. 이 플러그인은 Claude Code 를 팀핑에 잇습니다.
세션을 열면 팀 상황(내 할일·로드맵·팀 활동)이 자동으로 뜨고, 동료의 에이전트가 잡고 있는 파일을 고치려 하면
편집이 실행되기 전에 멈춥니다(파일 락).

### 설치

```
/plugin marketplace add serion-mark/teamping-plugin
/plugin install teamping@teamping
```

설치 중 자동화 세기를 고릅니다(아래 표). 설치 뒤 한 칸이 더 있습니다. 팀핑 웹의 **라이브** 탭에서
이 저장소를 프로젝트에 연결해야 락이 켜집니다. 연결 전까지 훅은 아무 표시 없이 통과합니다.
훅은 창을 열 때 읽히므로 새 창부터 적용됩니다.

**전제**

- 팀핑 계정과 프로젝트. 플러그인은 프로젝트 `.mcp.json` 에 이미 있는 MCP 토큰(서버 주소 + Bearer 토큰)을
  그대로 재사용합니다. 토큰을 따로 저장하지 않습니다.
- `jq`·`curl`. 없으면 훅은 아무것도 하지 않고, 세션을 막지도 않습니다.

### 자동화 세기 (`automation_level` · 설치 시 선택)

| 레벨 | 무엇 | 도는 훅 |
|---|---|---|
| `lv0` | 끔 | 없음 |
| `lv1` | 수동. "팀핑 확인해" 하면 동작 | 없음(프롬프트만) |
| `lv2` | 자동읽기. 세션 열면 상황 표시 · 자리 알림 · **파일 락** · 관측 | SessionStart · PreToolUse · PostToolUse · SessionEnd |
| `lv3` | 적극. lv2 + 응답이 끝날 때 "기록했나?" 리마인더 | lv2 + Stop |

설정 변경은 `/plugin details teamping`.

### 설치 다음 한 칸 — 착수할 때 카드 집기

플러그인을 깔고 저장소를 프로젝트에 연결하면 락은 자동으로 걸립니다. 그런데 작업 카드는 그대로 멈춰 있습니다.
훅은 「어떤 파일」만 알고 「무슨 작업 때문인지」는 모르기 때문입니다. 착수할 때 한 번만 집으면 그 뒤는 자동입니다.

```
팀핑에서 지금 하는 작업 카드를 집어줘 (claim_work)
```

카드가 `기획` → `진행 중`으로 옮겨지고, 이후 편집한 파일이 그 작업에 자동으로 붙습니다.
서버가 「이 파일은 아마 그 작업일 것」이라고 추측하지 않는 이유는, 추측으로 이으면 팀 화면이 지어낸 말을 하게 되기 때문입니다.

### 무엇이 기계 밖으로 나가나

훅이 보내는 것은 **경로 · 도구 이름 · 시각 · 순서**입니다. 파일을 열지 않습니다.

| 훅 | 언제 | 보내는 것 |
|---|---|---|
| `SessionStart` | 창을 열 때 | 세션 id · 저장소 이름 · 에이전트 이름 (설치 시 채널을 지정했으면 그 채널) |
| `PreToolUse` | 편집 직전 (`Edit`·`Write`·`MultiEdit`·`NotebookEdit` · `Bash` 의 쓰기 대상) | 세션 id · 저장소 이름 · 파일 경로 · 도구 이름 |
| `PostToolUse` | 모든 도구가 끝난 뒤 | 세션 id · 저장소 이름 · 도구 이름 · 바뀐 파일 목록(상대경로 · 최대 50개) · 도구 결과의 바이트 길이 |
| `SessionEnd` | 창을 닫을 때 | 세션 id 하나 |
| `Stop` | 응답이 끝날 때 | 없음 (로컬 문구만) |

이 플러그인의 스크립트 둘은 **훅이 아닙니다** — 직접 배선해야 돌아갑니다.

| 스크립트 | 언제 | 보내는 것 |
|---|---|---|
| `precommit-lock.sh` | 설치한 뒤, git 커밋 직전에 | 저장소 이름 · 스테이지에 올린 파일 경로 목록 |
| `notify-deploy.sh` | 직접 배포 절차에서 부를 때 | 저장소 이름 · 배포한 커밋 sha · 그 구간 커밋들의 sha(최대 200개) — **sha 뿐이고 커밋 메시지나 diff 는 안 보냅니다** |

나가지 않는 것: 파일 내용 · 소스코드 · 명령어 원문 · 도구 출력 본문 · 대화 · 프롬프트 · 환경변수 · API 키 ·
절대경로 · 프로젝트 밖 파일(락 기준). **커밋 sha 는 `notify-deploy.sh` 로만 나가고, 직접 부를 때만 나갑니다.**
전송 필드는 `scripts/*.sh` 가 만드는 것이 전부입니다.

**토큰이 어디서 오고 요청이 어디로 가나.** 훅은 이미 `.mcp.json` 에 있는 팀핑 토큰을 다시 씁니다
(프로젝트 → 폴더 → 사용자 순서). 새로 설정할 것은 없습니다. 찾은 결과는 `~/.cache/teamping/tok/` 에
`0600` 권한으로 캐시합니다. `notify-deploy.sh` 는 추가로 `TEAMPING_TOKEN` 환경변수나
`~/.teamping-token` 파일도 받습니다. 모든 스크립트는 `https://teamping.dev` 로 보내는데,
`TEAMPING_BASE` 가 설정돼 있으면 **토큰과 함께** 그 주소로 갑니다 — 자격증명 설정처럼 다루고
셸에서 다른 것이 그 값을 넣지 못하게 하십시오.

훅이 실제로 무엇을 받는지 값 없이 볼 수 있습니다. `TEAMPING_HOOK_DEBUG=/경로/파일.jsonl` 을 주면
훅이 받은 것의 **구조**(키 · 타입 · 길이)만 그 파일에 남깁니다.

### 실패하면

모든 훅은 어떤 실패(토큰 없음 · 오프라인 · API 오류)에도 `exit 0` 으로 넘어갑니다. 세션을 절대 막지 않습니다.
훅이 막는 것은 단 하나, 남이 지금 잡고 있는 파일의 편집이며, 그 사유가 에이전트에게 전달돼 다른 파일로 갈 수 있습니다.
상황 조회는 읽기 전용이고, 락 훅이 보내는 것은 조율 신호(누가 어떤 경로를 잡았나 · 세션이 열리고 닫혔나)뿐입니다.
승인 · 게시는 웹에서 사람만 합니다. 훅에는 그런 힘이 없습니다.

### 다른 AI 도구

Codex · Cursor · Gemini CLI 에도 도구 실행 전에 도는 훅이 있습니다. 같은 저장소에서 지원할 계획이고,
지금 포장된 것은 Claude Code 용뿐입니다.

### 이 저장소에 대해

이 저장소는 팀핑 제품 저장소의 `plugin/` 에서 **버전이 바뀔 때마다 자동으로 만들어집니다.** 이슈는 여기에 올려 주세요.
코드 수정은 제품 저장소에서 합니다. `plugin/.claude-plugin/releases.json` 은 릴리스 원장입니다(버전마다 내용 해시와 메모 한 줄).
`claude plugin update` 는 그 버전 문자열이 바뀔 때만 새 버전을 받습니다.

### 구조

```
plugin/
├── .claude-plugin/plugin.json      # 매니페스트 + userConfig(automation_level · channel_id)
├── .claude-plugin/releases.json    # 릴리스 원장
├── hooks/hooks.json                # SessionStart · PreToolUse · PostToolUse · SessionEnd · Stop
└── scripts/
    ├── session-context.sh          # 상황 요약 + 세션 시작 알림
    ├── pretooluse-lock.sh          # 편집 직전 파일 락 검사 (bash-write-targets.mjs 가 Bash 의 쓰기 대상을 뽑는다)
    ├── posttooluse-observe.sh      # 바뀐 파일 목록 관측
    ├── sessionend-lock.sh          # 락 해제 + 자리 비움
    ├── record-reminder.sh          # 기록 리마인더 (lv3)
    ├── resolve-token.sh            # .mcp.json 에서 토큰·서버 주소 찾기 (공용)
    ├── hook-debug.sh               # TEAMPING_HOOK_DEBUG 진단
    ├── precommit-lock.sh · install-precommit.sh   # 커밋 전 게이트 (선택 설치)
    └── notify-deploy.sh            # 배포를 팀핑에 알림 (선택)
```

라이선스: MIT.
