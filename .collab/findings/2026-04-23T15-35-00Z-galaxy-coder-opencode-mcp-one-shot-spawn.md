# OpenCode MCP One-Shot Spawn Pattern

**Date:** 2026-04-23
**Author:** galaxy-coder (investigation with jungle-coder)
**Status:** Understood — not a bug

## Finding

The OpenCode MCP client spawns the `c2c-mcp-server` as a one-shot process per request. The server starts, handles the JSON-RPC call, and exits when stdin closes. Evidence:

```
2026-04-23T15:32:07.274Z [3466015] starting pid=3466015
2026-04-23T15:32:07.274Z [3466015] session_id=galaxy-coder
2026-04-23T15:32:07.279Z [3466015] stdin EOF — exiting
2026-04-23T15:32:07.279Z [3466015] normal exit
```

The server ran for only ~5ms before stdin EOF.

## Root Cause

This is OpenCode's MCP client architecture — it spawns the server per-request, not as a persistent background process. This is NOT a bug in c2c.

## Why This Doesn't Break Delivery

OpenCode's delivery is handled by the **TypeScript plugin** (`c2c.ts`), NOT by the continuous inbox watcher:

- The plugin uses `promptAsync` to deliver messages to the active OpenCode session
- `promptAsync` is called when the plugin's inbox watcher (inotifywait on the broker) fires
- The watcher runs as a subprocess of OpenCode, not as the MCP server

The MCP server's continuous watcher is a **separate delivery path** that doesn't apply to OpenCode. For OpenCode:
- MCP calls (register, send, poll_inbox, etc.) work as one-shot calls
- Real-time message delivery works via the plugin's `promptAsync` path

## Implications

1. The inbox watcher in `c2c-mcp-server` is irrelevant for OpenCode delivery
2. The "disconnect" pattern (MCP server exiting) is expected and harmless for OpenCode
3. If messages aren't arriving for OpenCode, the bug would be in the plugin's inotifywait/promptAsync path, not the MCP server

## For Other Clients

- **Claude Code**: uses PostToolUse hook + optional watcher — different architecture
- **Kimi**: uses Wire bridge
- **Codex**: uses sentinel + deliver daemon

Each client has its own delivery mechanism. The MCP server's watcher is primarily useful for clients that support continuous MCP connections.
