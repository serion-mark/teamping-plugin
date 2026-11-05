# Teamping for Cursor

Automatic file locks for Cursor's own AI. Before Cursor edits a file, Teamping checks whether a teammate's AI is working on it. If so, the edit stops and your AI is told who holds the file.

## Install

macOS and Linux. Run this, then reload Cursor (Command Palette → Developer: Reload Window):

```bash
d="$(mktemp -d)" && git clone --depth 1 https://github.com/serion-mark/teamping-plugin "$d/r" && mkdir -p ~/.cursor/plugins/local && cp -R "$d/r/cursor-plugin/teamping" "$HOME/.cursor/plugins/local/.teamping-new" && rm -rf ~/.cursor/plugins/local/teamping && mv "$HOME/.cursor/plugins/local/.teamping-new" ~/.cursor/plugins/local/teamping; rm -rf "$d"
```

Run it again to update. On Cursor Enterprise, an admin must turn on "Allow Local Plugin Imports" first.

## What it needs

- A Teamping connection in `~/.cursor/mcp.json` (see https://teamping.dev/connect#cursor). The plugin reuses that key and stores nothing else. A key in `<project>/.cursor/mcp.json` connects MCP but is not used for locks, because a project file may come from someone else's repository.
- Node.js on the `PATH` of Cursor's hooks. Without it, the hooks do nothing and edits go through unlocked.

## What it sends

The repository address, file paths relative to the repository, the tool name and the conversation id. It never sends file contents, shell commands or your email address.

## Failure behaviour

If the server is unreachable, slow, or the key is missing, your edit goes ahead. Locks release when the conversation ends, or after 30 idle minutes.

To turn it off, disable the plugin in Cursor, or set `TEAMPING_LEVEL=lv0` in the environment Cursor starts from.
