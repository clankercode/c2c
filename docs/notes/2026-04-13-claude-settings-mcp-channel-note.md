# Claude Settings For Local C2C MCP Channels

## Summary

- The `c2c` local MCP server should stay defined in the repo-local `.mcp.json`.
- `~/.claude/settings.json` can persist approval of the project MCP server, but it does not define the server itself.
- Experimental local channel delivery still requires a CLI launch flag for new Claude sessions:
  - `--dangerously-load-development-channels server:c2c`
- `--channels` is for plugin channels, not the bare local `server:c2c` development server path.

## Recommended Setup

1. Keep the server definition in `/home/xertrov/src/c2c-msg/.mcp.json`.
2. Add `enabledMcpjsonServers: ["c2c"]` to `~/.claude/settings.json` so project-scoped MCP approval is persistent.
3. Do not add a duplicate user-scoped `mcpServers.c2c` entry to `~/.claude.json` unless there is a concrete need to run `c2c` outside this repo.
4. Continue launching Claude with:

```bash
claude --dangerously-load-development-channels server:c2c
```

## Why Not Add A User-Scoped `mcpServers.c2c`

- The current project `.mcp.json` already contains the correct stdio server definition.
- Keeping `c2c` project-scoped avoids duplicating repo-specific paths and broker-root settings in global user config.
- A global `mcpServers.c2c` entry would make sense only if `c2c` should auto-exist outside `/home/xertrov/src/c2c-msg`.

## Current Local Evidence

- `/home/xertrov/src/c2c-msg/.mcp.json` already defines `mcpServers.c2c` correctly.
- `~/.claude/settings.json` did not previously contain any `enabledMcpjsonServers` entry.
- `~/.claude.json` currently tracks the `/home/xertrov/src/c2c-msg` project with:
  - `mcpServers: {}`
  - `enabledMcpjsonServers: []`
- That supports the approach of persisting approval while keeping the actual server definition in the repo.

## Remaining Blocker

Persistent settings can help Claude load and approve the local MCP server, but they do not remove the current experimental channel requirement. For now, receiver-side channel delivery still depends on Claude being launched with the development-channel flag.
