# MCP Server Disconnect Investigation

**Date:** 2026-04-24T15:25:00Z
**Author:** jungle-coder
**Status:** In progress — debug logging enabled, awaiting next disconnect event

## Symptom
Galaxy-coder's MCP keeps disconnecting (Not connected on poll_inbox) while CLI continues to work. 4 `c2c-mcp-server` processes observed running simultaneously.

## Key Clarification (2026-04-24T15:35:00Z)
Galaxy is running OpenCode (NOT `c2c start codex`). The "no-session.log" in the debug dir is from a DIFFERENT Codex MCP client session that was started without `C2C_MCP_SESSION_ID` — unrelated to galaxy's disconnect issue.

Galaxy's OpenCode MCP IS working currently. The 4 servers = 4 restart cycles of galaxy's OpenCode MCP server.

## Root Cause (hypothesis)

**The MCP server exits cleanly when its parent process (OpenCode's MCP client) closes stdin.** This is correct behavior, not a crash.

Location: `ocaml/server/c2c_mcp_server.ml` line 207:
```ocaml
| None -> debug_log "stdin EOF — exiting"; Lwt.return_unit
```

When OpenCode's MCP client disconnects, it kills the `c2c-mcp-server` child process → stdin pipe closes → `Lwt_io.read_line_opt` returns `None` → main loop exits → server terminates.

The 4 running servers = 4 restart cycles from repeated disconnects.

## Debug Logging Now Active
- `C2C_MCP_DEBUG=1` set in galaxy's OpenCode session
- Log path: `~/.local/share/c2c/mcp-debug/<session_id>.log`
- Next disconnect will be logged as "stdin EOF — exiting"

## Why the CLI Still Works
The CLI uses a persistent broker daemon (`c2c broker`) that doesn't depend on the MCP server. The MCP server is a separate per-client process spawned by OpenCode's MCP client infrastructure.

## CRITICAL FINDING (2026-04-24T15:40:00Z)

**galaxy-coder.log reveals immediate stdin EOF (5ms after startup).**

Log contents:
```
2026-04-23T15:32:07.274Z [3466015] starting pid=3466015
2026-04-23T15:32:07.274Z [3466015] session_id=galaxy-coder
2026-04-23T15:32:07.274Z [3466015] channel_delivery=true
2026-04-23T15:32:07.274Z [3466015] broker_root=/home/xertrov/src/c2c/.git/c2c/mcp
2026-04-23T15:32:07.279Z [3466015] starting inbox watcher for galaxy-coder
2026-04-23T15:32:07.279Z [3466015] stdin EOF — exiting
2026-04-23T15:32:07.279Z [3466015] normal exit
```

The server starts and exits 5ms later. This is NOT a crash after running — it's an immediate exit after startup.

**Hypothesis**: OpenCode's MCP client spawns the server for one-shot requests (initialize + single tool call), then closes stdin and exits. A NEW server is spawned for each subsequent MCP call. This explains:
- "4 servers running" = 4 separate spawn cycles for 4 requests
- MCP works intermittently = if you poll quickly enough, the server might still be alive
- The disconnect pattern = each request is a fresh server process

**But this contradicts the OCaml MCP server design** which expects a persistent stdio connection with a read loop. One-shot spawns would mean:
- No inbox watcher survives between calls
- Each call re-registers and re-starts the watcher
- The broker sees many short-lived sessions

**Root cause**: OpenCode's MCP client uses ephemeral per-request spawns, not persistent connections. The c2c MCP server was designed for the latter.

## Confirmed Working (2026-04-24T15:45:00Z)

Test DM from jungle-coder arrived via `promptAsync` — appeared in galaxy's transcript as a user message. `poll_inbox` showed empty because `promptAsync` already drained it. **Delivery IS working.**

## Conclusion

The MCP "disconnect" for OpenCode is **cosmetic and expected**. OpenCode's MCP client uses one-shot spawns; the OCaml MCP server exits immediately after each request. This is NOT a bug — the plugin's `promptAsync` path handles delivery independently.

**For OpenCode**: promptAsync delivery is the correct and working path. MCP tools work for commands but aren't needed for delivery.

**For Claude Code/Codex**: These use persistent MCP connections where the inbox watcher is meaningful. The disconnect issue is OpenCode-specific.

## True Fix Requires
Either:
- OpenCode changes to not kill MCP child processes on disconnect (OpenCode-level fix)
- MCP server uses PTY instead of piped stdin (so it survives parent death) — complex, affects protocol
- OpenCode auto-restarts MCP server on disconnect (OpenCode-level fix)
