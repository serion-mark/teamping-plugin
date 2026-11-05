# Teamping for Cursor

Automatic file locks for Cursor's Agent. Before the Agent edits a file, Teamping checks whether a teammate's AI is working on it. If so, the edit stops and your AI is told who holds the file.

## Install

macOS and Linux. Run this, then reload Cursor (Command Palette → Developer: Reload Window):

```bash
d="$(mktemp -d)" && git clone --depth 1 https://github.com/serion-mark/teamping-plugin "$d/r" && mkdir -p ~/.cursor/plugins/local && rm -rf "$HOME/.cursor/plugins/local/.teamping-new" && cp -R "$d/r/cursor-plugin/teamping" "$HOME/.cursor/plugins/local/.teamping-new" && rm -rf ~/.cursor/plugins/local/teamping && mv "$HOME/.cursor/plugins/local/.teamping-new" ~/.cursor/plugins/local/teamping; rm -rf "$d"
```

Run it again to update. On Cursor Enterprise, an admin must turn on "Allow Local Plugin Imports" first.

## What it needs

- A Teamping connection in `~/.cursor/mcp.json` (see https://teamping.dev/connect#cursor). The plugin reuses that key and stores nothing else. A key in `<project>/.cursor/mcp.json` connects MCP but is not used for locks, because a project file may come from someone else's repository.
- Node.js 18 or later on the `PATH` of Cursor's hooks. Without it, the hooks do nothing and edits go through unlocked.

## What it covers

- Locks cover one project at a time: whichever repository you edit, they go to the project of the key in `~/.cursor/mcp.json`. When you edit a repository in another project, switch to that project's key, reload Cursor and start a new chat. MCP moves with the key, and locks in the previous project can stay for up to 30 minutes.
- Tab completions and edits you make by hand are not checked. Edits made through shell commands are only partly checked.

## What it sends

The repository address, file paths relative to the repository, the tool name and the conversation id. It never sends file contents, shell commands or your email address.

## Failure behaviour

If the server is unreachable, slow, or the key is missing, your edit goes ahead. Locks release after 30 idle minutes, even if you close the window sooner.

To turn it off, delete `~/.cursor/plugins/local/teamping` and reload Cursor, or set `TEAMPING_LEVEL=lv0` in the environment Cursor starts from.
