# OpenCode Plugin Drain Path Proven

**Timestamp**: 2026-04-14T00:43Z  
**Author**: storm-ember  
**Severity**: INFO (positive finding)

## Summary

The c2c OpenCode TypeScript plugin (`~/.config/opencode/plugins/c2c.ts`) is
actively running in the managed `opencode-local` session and draining the inbox
via the CLI path. The `promptAsync` delivery path is still unconfirmed for
`--fork` sessions but likely works for persistent TUI sessions.

## Evidence

Test: sent DM to opencode-local at 1776091334.449399 (2026-04-14 00:42:14Z).

1. **Inbox drained within 1 second** — the `.inbox.json` file was empty at
   t+1s (next broker.log `poll_inbox` MCP entry was 35 seconds later).
2. **No MCP `poll_inbox` logged** — broker audit log shows no `poll_inbox`
   between the `send` at 1776091334 and the next MCP poll at 1776091369.
   The plugin uses `c2c poll-inbox --json --file-fallback` (CLI subprocess),
   which bypasses the MCP layer entirely.
3. **No inbox archive created** — OCaml broker creates `.inbox.archive` only
   for MCP-path drains. No archive file exists, confirming CLI-based drain.
4. **Notify daemon ruled out** — `c2c_deliver_inbox.py --notify-only` only
   PEEKS (reads without draining) and then injects a PTY notification.
   It never drains the inbox directly.

## Conclusion: What's Proven

- Plugin is loaded and the `startBackgroundLoop()` is running ✓
- `runC2c(["poll-inbox", "--json", "--file-fallback", ...])` executes
  successfully every ~2 seconds ✓
- `sessionId` and `brokerRoot` are correctly read (from env or sidecar) ✓

## What's Still Unconfirmed

- `ctx.client.session.promptAsync(...)` success — no reply received from
  opencode-local after the test DM was drained. This could mean:
  (a) `promptAsync` was called but the `--fork` session is mid-run and will
      process the new turn when its current task completes; OR
  (b) `promptAsync` failed (session not in receptive state for new user turns).

## Known Limitation: Data Loss on promptAsync Failure

If `promptAsync` fails, the message is drained from the inbox but not
delivered. The plugin's comment acknowledges this:
```typescript
// Message was already drained — best-effort delivery; no retry here.
// Future: write to a spool file and retry on next idle.
```
For managed `--fork` sessions, the existing notify-only daemon provides a
reliable fallback. For persistent TUI sessions (Max's use case), the session
is typically idle when a new message arrives, so promptAsync should succeed.

## Fix Status

- CLI drain path: WORKING (proven)
- promptAsync for persistent TUI sessions: LIKELY WORKS (not yet live-tested)
- promptAsync for --fork managed sessions: UNCERTAIN (may need spool/retry)

## How to Prove promptAsync End-to-End

1. Start a persistent manual OpenCode TUI session (not `--fork`):
   ```bash
   OPENCODE_CONFIG=~/.config/opencode/opencode.json opencode
   ```
2. Ensure `~/.opencode/c2c-plugin.json` sidecar exists with correct session_id.
3. Send a DM from another agent to that session's c2c alias.
4. Without calling `poll_inbox`, verify the message arrives as a user turn in
   the TUI (not via PTY injection).
