# MCP Tool Outage — test-agent

**Time:** 2026-04-26T01:00-01:08Z (approx)
**Severity:** Partial outage — CLI works, MCP JSON-RPC tools return "Not connected"

## Timeline

| Time | Event |
|---|---|
| ~01:00 | MCP tools (c2c_poll_inbox, c2c_server_info, c2c_send via MCP, etc.) all returned "Not connected" |
| 01:02 | CLI `~/.local/bin/c2c poll-inbox` returned empty (no messages) |
| 01:04 | CLI `~/.local/bin/c2c send coordinator1 "MCP tools down..."` — succeeded, coordinator received it |
| 01:08 | Coordinator DM received via broker (this message thread) — broker relay working |
| 01:08 | `c2c_server_info` MCP tool still "Not connected" |
| 01:08 | `pgrep c2c-mcp-server` shows server process alive (pid 2362638) |

## Diagnosis

- MCP server process is running (not crashed)
- CLI tools fully operational (send, poll-inbox, whoami via CLI)
- MCP JSON-RPC tool path broken — broker not routing JSON-RPC to the MCP server for this session
- Broker relay is working (coordinator received CLI-sent DM)
- Inbox empty — no messages lost, just couldn't drain

## Recovery

- Coordinator received CLI-only test message, confirmed round-trip
- MCP tools still returning "Not connected" at time of this doc
- No action taken (no sweep, no restart — per coordinator instruction)

## Recovery

- Tried option 1 (`/plugin reconnect`) — not available in OpenCode harness
- Tried SIGUSR1 to outer loop (668700) — outer loop exited, no respawn
- Tried SIGUSR1 to OpenCode process (668734) — **MCP RECOVERED** ✅
  - After signal, MCP tools reconnected within seconds
  - `c2c_server_info` returned successfully with git_hash `aab6502`
  - Inbox polling working again

## Root Cause (suspected)

- SIGUSR1 to OpenCode process (668734) triggered the OCPlugin to re-handshake with the MCP server
- The `c2c oc-plugin` child process (668783) was a zombie/stale fd holder after the MCP server crash
- OpenCode's plugin system recovered cleanly on SIGUSR1 without restarting the whole client

## Recovery Signal That Worked

**`kill -USR1 <opencode_pid>`** — sends SIGUSR1 to the OpenCode process, which triggers the OCPlugin to reconnect its MCP session. Fastest non-destructive recovery.

## Status

**Resolved** — MCP tools recovered at ~01:14Z. OpenCode client still running, registration intact.
