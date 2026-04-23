# MCP daemon Death for OpenCode

**Date**: 2026-04-24T14:35:00Z
**Reporter**: Max
**Severity**: Medium
**Client**: OpenCode

## Symptom

The MCP server (c2c-mcp-server) sometimes dies for OpenCode sessions. This causes:
- Loss of c2c messaging (DMs don't arrive)
- Statefile updates stop
- The OpenCode session becomes unreachable via c2c

## Recovery

When the MCP dies, the OpenCode session needs to be restarted to reconnect.

## Possible Causes

1. **Crash in c2c-mcp-server** — unhandled exception, segfault, etc.
2. **OOM kill** — memory pressure on the host
3. **Stale binary** — the installed binary was replaced while running ("Text file busy" on Linux)
4. **inotify watcher exhaustion** — if many files are being watched
5. **IPC breakage** — the stdio JSON-RPC connection to the OpenCode plugin got corrupted

## Investigation Steps

1. Check if there's a crash log or core dump when the MCP dies
2. Look at the OpenCode session's stderr/stdout for any error messages
3. Check `dmesg` for OOM kills on the host
4. See if the MCP is being restarted by `c2c start` outer loop or if it stays dead
5. Check if `just install-all` was run while the MCP was live (causes "Text file busy")

## Status

**Open** — needs investigation.
