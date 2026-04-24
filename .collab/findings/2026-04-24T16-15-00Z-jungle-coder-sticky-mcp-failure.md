# Sticky MCP Failure After First Error — OpenCode

## Symptom
Once the c2c MCP server fails to connect for an OpenCode session, it **keeps failing** on every subsequent tool call until the user manually disables and re-enables the MCP server in OpenCode settings. A single toggle (disable + re-enable) restores connectivity.

## Environment
- OpenCode session, managed via `c2c start opencode`
- c2c MCP server (`c2c-mcp-server`) spawned as a one-shot per tool call
- `c2c install opencode` configured with `mcp.c2c` in `opencode.json`

## Observed By
- Max (reported in swarm-lounge, 2026-04-24)
- galaxy-coder (same pattern — "Not connected on poll_inbox", toggle fixes)

## Key Observation (from Max, 2026-04-24)
- **First load works fine** — not a first-spawn issue
- **Breaks at a later point** mid-session — regression, not initialization bug
- Debug logs not captured at time of failure — need to reproduce with `C2C_MCP_DEBUG=1`

## Hypothesized Root Cause
Not an initialization bug. Candidates for mid-session breakage:
1. **Compaction mid-session**: OpenCode compacts → new process spawns → MCP server child process respawns → but `C2C_MCP_SESSION_ID` env might not be correctly set before the MCP server initializes → new registration fails or registers under wrong session ID → broker inbox for the correct session goes stale while messages pile up for the wrong one. Clear evidence: `c2c.ts` plugin clears the compacting flag on `session.compacted` but does NOT re-register or re-join rooms.
2. Registration gets invalidated/overwritten by another process re-registering same alias with different session_id
3. `C2C_MCP_SESSION_ID` env var drifting mid-session (env mutation?)
4. Broker registry file getting corrupted or swept mid-session

## Hypothesized Root Cause
OpenCode's MCP client (at the TypeScript/app level, not the c2c plugin) caches the MCP server's failure state per session. When the first spawn of `c2c-mcp-server` produces an error or exits non-zero, the client enters a permanently broken state for that session.

Disable/re-enable forces OpenCode to:
1. Tear down the broken server instance
2. Spawn a fresh `c2c-mcp-server` process
3. Re-run initialize

The fresh spawn succeeds because:
- The registration guard (`same_pid_alive_different_session` etc.) correctly allows re-registration when the old PID is dead
- Or: the previous server's registration was cleaned up on exit

## Key Code Points
- `c2c-mcp-server` at `ocaml/server/c2c_mcp_server.ml` — auto-registers on startup (line 271: `C2c_mcp.auto_register_startup`)
- `auto_register_startup` in `ocaml/c2c_mcp.ml` lines 2462-2581 — guards against hijack/alias-collision
- Guard 3 (`same_session_alive_different_pid`) at line 2522 — designed to allow re-registration when PID changes
- The server exits with debug log "stdin EOF — exiting" (line 207) after each one-shot call

## c2c.ts Plugin Compaction Handling (2026-04-24)
At `.opencode/plugins/c2c.ts` line 1861-1872, `session.compacted` handler only clears the compacting flag:
```
if (event.type === "session.compacted") {
  ...
  await runC2c(["clear-compact"]);
  ...
  return;
}
```
**Missing**: re-registration and re-join rooms after compaction. This aligns with hypothesis #1 (compaction causes registration loss).

The `clear-compact` command only clears the flag — it does NOT re-register the session or re-join rooms. After compaction spawns a new MCP server process, the new server should re-register and re-join its rooms.

## Open Questions
1. What causes the FIRST failure? Common candidates:
   - Registration guard triggering on first spawn (unlikely — guards allow fresh starts)
   - `opencode.json` env override removing `C2C_MCP_SESSION_ID` (see configure_opencode.py lines 73-79)
   - Race: server registers, exits, but OpenCode hasn't received/processed the initialize response before the next poll
   - Broker root mismatch: `C2C_MCP_BROKER_ROOT` not set correctly in `opencode.json`

2. Why does OpenCode cache the failure persistently across tool calls?
   - This is an OpenCode-level behavior — the c2c plugin has no control over this
   - Could be: the MCP client object is created once per "MCP server enable" and reused across all tool calls
   - If the client object holds a stale/dead connection reference, only a full disable/enable resets it

3. What exactly does disable/re-enable do that a fresh spawn doesn't?
   - Likely: tears down and recreates the MCP client object entirely
   - A fresh spawn by the re-enabled server would re-register cleanly

## Diagnostic Steps
1. Enable `C2C_MCP_DEBUG=1` on the failing session: set in the session env BEFORE failure occurs
2. Check `~/.local/share/c2c/mcp-debug/*.log` for the broken session ID — look for:
   - `auto_register_startup` entry — did it re-register after a compaction event?
   - "stdin EOF" vs actual error
   - Registration guard log lines (hijack_guard, alias_occupied_guard, etc.)
3. When broken: compare `c2c list --all --json` output against the stuck session's `C2C_MCP_SESSION_ID`
4. Check if `session.compacted` appears in OpenCode's own logs just before the failure starts
5. The fix (if compaction is the cause): re-register + re-join rooms on `session.compacted` in c2c.ts

## Fix Candidates
1. **Re-register + re-join rooms on `session.compacted`** in c2c.ts (fixes the compaction theory at root)
2. **Add a retry/refresh path in c2c.ts plugin** — when `poll_inbox` returns an error indicating the MCP connection is stuck, proactively trigger a re-registration
3. **Workaround for OpenCode**: document the disable/re-enable fix for users hitting this
4. **OpenCode-level fix**: if this is an OpenCode MCP client bug (caching dead connections), file with OpenCode

## Status
Filed 2026-04-24 by jungle-coder on behalf of Max.
S5c Phase B complete (bf12cf4). Returning to MCP investigation.

## Updated 2026-04-24
Pending: debug logs from a reproduction with C2C_MCP_DEBUG=1
Blocking: Need to capture what happens at the moment of failure
