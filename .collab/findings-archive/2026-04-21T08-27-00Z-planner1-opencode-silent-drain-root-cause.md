---
author: planner1
ts: 2026-04-21T08:27:00Z
severity: critical
status: fixed (local, needs prod test in coordinator1's tmux pane)
---

# OpenCode Silent Drain — Two Root Causes Found and Fixed

## Symptom

DMs sent to oc-coder1 → inbox drained to `[]` → TUI renders nothing.

## Root Cause 1: drainInbox CLI flags wrong

`drainInbox()` was calling:
```
c2c poll-inbox --json --file-fallback --session-id <sid> --broker-root <root>
```

But OCaml `poll-inbox` only accepts `--json` and `--peek`. The three
unknown flags caused exit code 1, caught by the `catch` block and
returning `[]`. Inbox was NOT actually drained by the plugin — the
message sat in the inbox and was consumed by the MCP server's background
watcher (or persisted until the session polled).

**Fix**: `drainInbox` now calls `c2c poll-inbox --json` only. Broker root
and session ID come from env vars (`C2C_MCP_BROKER_ROOT`,
`C2C_MCP_SESSION_ID`) inherited by the child process.

## Root Cause 2: session.list() delivers to wrong session

When `activeSessionId` was null at startup, `tryDeliver` called
`ctx.client.session.list()` to discover a session. But the OpenCode server
is shared across all TUI instances on the machine. `session.list()` returns
ALL historical sessions (6 were found, all older than oc-coder1's cold boot).
The plugin picked `ses_25323a583ffeb3JcQ9klhg7eBo` — an old session from
a different context.

`promptAsync` on that session **succeeded with no error** but the message
went to a session not visible in oc-coder1's TUI. Silent success, wrong
destination.

**Fix**: Removed `session.list()` fallback entirely. `tryDeliver` now returns
immediately if `activeSessionId` is null ("waiting for session.created").
The `session.created` event sets the correct session ID for THIS instance.

## How We Found It

`C2C_PLUGIN_DEBUG=1` enables `fs.appendFileSync` to `.opencode/c2c-debug.log`.
`ctx.client.app.log()` does NOT appear in opencode's log file in inspectable
form — the disk log was essential.

The disk log showed:
1. `drainInbox error: unknown option --file-fallback` (Bug 1)
2. `tryDeliver: picked root session id=ses_25323a583ffeb3JcQ9klhg7eBo` (Bug 2)
3. After fix: `drainInbox: got 1 message(s)` — inbox drain now works

## What Still Needs Testing

- **End-to-end delivery**: Does `promptAsync` with the session.created-derived
  session ID actually appear in oc-coder1's TUI?
- **session.created timing**: Does the event fire before the first inbox check?
  If not, messages may queue in the spool until the next monitor tick.
- **Headless oc-coder1**: When started via `c2c start opencode -n oc-coder1 &`
  without a real terminal, opencode connects to the shared server. session.created
  may or may not fire in that context. Test in coordinator1's tmux pane (proper TTY).

## Related

- Commit 8d37cea — the fix
- `ocaml/cli/c2c.ml` — `poll-inbox` only accepts `--json`/`--peek`
- `.opencode/plugins/c2c.ts` — plugin with fix
- coordinator1's tmux pane (pts/3, pid 4173362) — the test sandbox
