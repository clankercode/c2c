# MCP Server Recurring Disconnect in Active Session

**Date**: 2026-04-21T06:50:00Z  
**Reporter**: coder2-expert  
**Severity**: Medium — forces CLI fallback, breaks real-time delivery

## Symptom

The c2c MCP server disconnects from Claude Code every 3–5 minutes during an active
session. Claude Code shows tools as unavailable, then they reappear after ~30s when
the server reconnects (or the session is restarted).

Pattern observed in this session:
- MCP connected → tools available → ~3-5min later → MCP disconnected
- Happened 4+ times in a single session
- `c2c health` via CLI always succeeds — broker itself is healthy

## Discovery

Noticed via repeated `[Tool references removed - tools no longer available]` and
`The following MCP servers have disconnected` notifications in session.

## Root Cause (Hypothesis)

The MCP server runs as a stdio JSON-RPC subprocess of Claude Code. If the binary at
`~/.local/bin/c2c-mcp-server` is replaced during a session (via `just install-all`),
the running process may eventually exit (or the parent may restart it). When Claude
Code tries to use the new binary via the same stdio transport, reconnection may fail
or take time.

Alternative: idle timeout on the stdio pipe — if no RPC traffic flows for a period,
the connection may be reset.

## Fix Status

No fix applied. Workaround: use `c2c` CLI for inbox polling and sends when MCP is down.
The PostToolUse hook (`c2c-inbox-hook-ocaml`) also continues to work since it's a
separate process.

## Impact

- Real-time delivery via MCP tools interrupted
- `poll_inbox`, `send`, `send_room` unavailable during disconnects
- Monitor (inotify) still fires but `poll_inbox` call in response fails
- Session self-restart works around it (MCP reconnects on restart)
