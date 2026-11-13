# What this plugin sends

Every field the Teamping plugin sends from your machine, in full. The README links here.

← [README](https://github.com/serion-mark/teamping-plugin/blob/main/plugin/README.md) · [한국어](https://github.com/serion-mark/teamping-plugin/blob/main/plugin/DATA.ko.md)

## Only paths and tool names are sent

The hooks send **paths, tool names, timestamps and order** — never file contents. (Locally they read your
git status and your `.mcp.json` to find the token.) They run in **every repository where the plugin is
enabled, including ones not yet connected to a Teamping project.**
"Repository address" below is your git `origin` URL exactly as configured — if credentials are embedded in it
(like `https://user:token@…`) they go too, so keep tokens out of `origin`; a git repository with no `origin` sends
the folder name. **Folders without git are recorded only if you chose them** — tell your AI "record this folder too"
(it runs this plugin's folder tool: `node scripts/teamping-folders.mjs add [folder]`, with `remove` and `list` too — you can run it yourself). For a chosen folder the repository address is `dir:` plus a random id (never the folder name) and
paths are relative to that folder; the "after a tool" hook also lists files the shell command changed there (by
modification time). Folders without git that you did not choose send no folder or file information (the session-start
briefing is still asked for without a repository, and session end still releases this window's locks). "Window id" is a random-looking hash made on this machine per Claude window (no machine or user name in it).

| Hook | When | Sent |
|---|---|---|
| `SessionStart` | window opens | session id, window id, repository address, agent name (or the channel you configured), this plugin's version, your time-zone offset, display language, and one word for this repo's pre-commit check (`off`·`on`·`declined`·`custom`) |
| `PreToolUse` | right before an edit (`Edit`·`Write`·`MultiEdit`·`NotebookEdit`; `Bash` write targets) | session id, window id, agent name, repository address, file paths (relative), tool name, display language |
| `PostToolUse` | after any tool | session id, agent name, repository address, tool name, list of changed files (relative paths, max 50), size of the tool result in bytes, **SHAs of new commits in this repo (max 20 — SHAs only, never messages or diffs)**, the sub-agent id when a sub-agent made the call, the Teamping card id when the AI has just claimed a card, the ids of Teamping notices this window has already shown the AI (so they aren't sent again), and the id of the Teamping message when the AI has just posted one |
| `SessionEnd` | window closes | session id, window id, the time it was sent |
| `UserPromptSubmit` | you send a message | session id, repository address, ids of notices already shown, and the window's title if you gave it one (shown as the window's name to your team and in your own Teamping notices) — never your message |
| `Stop` | response ends | while the window is idle, waits for a Teamping notice: session id, repository address, ids of notices already shown (otherwise nothing — local message only) |

Two scripts in this plugin are **not hooks** — they only run if you wire them in yourself:

| Script | When | Sent |
|---|---|---|
| `precommit-lock.sh` | the git pre-commit hook, after you install it | repository address, list of staged file paths |
| `notify-deploy.sh` | when you call it from your own deploy | repository address, the deployed commit SHA, and the SHAs of the commits in that range (up to 200) — SHAs only, never commit messages or diffs |

**Teamping notices for this window.** When someone replies to a message this window posted, responds to / confirms the card this window claimed, or another AI addresses a message to this window, Teamping keeps a one-line notice for this window (who · what · the id · which tool to read it with — never the message itself). The hooks add that line to the AI's context after a tool, next to your message, or once when a response ends; while the window is idle a background hook waits for it and wakes the window (at most 6 times in an hour without you typing — counting restarts when you type, but never more than 20 times in an hour · gives up after 50 minutes until the next response). The AI is told to tell you first and ask before acting on it. Lines waiting to be shown and ids already shown are kept in `~/.config/teamping/inbox/` (folder 0700 · files 0600 · one set per window · cleared after 8 days). Nothing is sent to the AI from inside a sub-agent.

**Setup resume.** When the setup kit needs an app restart, the AI leaves a copy of the kit plus the step to resume and the copy's hash in `~/.config/teamping/setup/<per-repo key>/` on this computer (the repo is untouched · no secrets). In the reopened session `SessionStart` reads it and tells the AI to continue from that step only if the hash and the repo path match — nothing is sent. Notes older than 7 days aren't followed; they're cleared and mentioned once. The AI deletes the note when setup is done.

**Grok Build (xAI, 0.2.36).** Grok Build reads Claude Code plugins, so these hooks also run inside Grok. Grok-only users install it with `grok plugin marketplace add serion-mark/teamping-plugin` and `grok plugin install teamping@teamping-plugin --trust`. When the hooks can tell they are running inside Grok, they read Grok's tool names (`write`, `search_replace`, `run_terminal_command`), record your work as Grok rather than Claude Code, and look for the key in `[mcp_servers.teamping]` of `~/.grok/config.toml` first (`$GROK_HOME` if set). If that entry (or the file) exists but can't be read, they stop there. If there's no entry, they use only this folder's entry in your Claude Code settings (`~/.claude.json`) or a sign-in connection's per-repo auto-lock key — never the top-level copied key there, which may belong to another workspace. A `.mcp.json` inside a repo is never used in Grok. Grok's MCP tool names (`teamping__…`) are read too. The inbox and session-briefing hooks are skipped in Grok for now.

**Auto-lock key (sign-in connections, 0.2.35).** If Claude Code is connected to Teamping by signing in (`claude mcp add` + browser), its key lives in Claude Code's own storage, which the hooks can't read. With your OK, the plugin opens a one-time listener on `127.0.0.1`, opens the browser to Teamping's consent screen (you pick the project and allow), and saves a key that only opens Teamping's lock/record hooks — not Teamping tools — to `~/.config/teamping/hookkey/<per-repo key>` (folder 0700 · file 0600 · one per repo; worktrees of the same repo share it). What it sends: the port, your OS kind (mac/linux), a one-way value of this computer and repo (no path or repo name), and the person and workspace ids. Revoke it under "Connection keys" on My page; Teamping then rejects the hooks' requests until you turn it on again (the file stays until then). Only entries in your own Claude Code settings (`~/.claude.json`) are treated as a sign-in connection — a key-less `teamping` entry in a repo's `.mcp.json` is skipped as before.

**The pre-commit check is opt-in per repository.** When it's off, the session-start briefing asks once a day whether to turn it on; the plugin's pre-commit installer then inserts one marked block right after the first line of this machine's `.git/hooks/pre-commit` (never committed; the rest of an existing hook is kept as is). If you installed it, `SessionStart` keeps the path inside that block pointing at the current plugin version (old version folders get cleaned up after an update) — it touches nothing outside the block. Repos using `core.hooksPath` (husky etc.), symlinked hook files, and hooks that aren't sh-family scripts are left alone (the installer prints the line to add instead). To stop being asked: `git config teamping.precommit off`.

Never sent: file contents, source code, command text, tool output, your conversation, prompts,
environment variables, API keys, absolute paths, files outside the project (for locks), commit messages.
Everything listed above is built by the hook scripts shipped in this plugin — you can read them under `plugin/scripts/`.

**Where the token comes from, and where requests go.** The hooks reuse the Teamping token already in
your `.mcp.json` (project, then directory, then user level); nothing new to configure. They cache the
lookup under `~/.cache/teamping/tok/` with `0600` permissions. The hooks send to the **server URL of that same
`teamping` entry** — so a repository's own `.mcp.json` can point them at another server. Open repositories you
trust, and check the `teamping` URL in a project's `.mcp.json`. `notify-deploy.sh` additionally accepts
`TEAMPING_BASE` / `TEAMPING_TOKEN` environment variables or a `~/.teamping-token` file — treat those like
credential settings.

You can watch what a hook receives, without values: set `TEAMPING_HOOK_DEBUG=/path/to/file.jsonl`
and the hooks write the **structure** (keys, types, lengths) of their input there.
