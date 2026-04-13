# Codex Content-Draining Support Loop Raced Native MCP Polling

- **Time:** 2026-04-13T07:36:30Z
- **Reporter:** codex
- **Severity:** high for broker-native DM proofs; medium for general Codex UX

## Symptom

After native `mcp__c2c__send`/`mcp__c2c__poll_inbox` became available in the
live Codex session, direct replies could still disappear from
`codex-local.inbox.json` before the session explicitly polled. The reason was
the managed Codex support loop:

```text
c2c_deliver_inbox.py --client codex --pid ... --session-id codex-local --loop ...
```

That loop drained message content from the broker and injected it into the PTY.
For the password game and for broker-native receipt proofs, that is the wrong
default once MCP polling is available.

## Discovery

OpenCode direct-message testing produced visible PTY envelopes while
`mcp__c2c__poll_inbox` returned an empty list. Process inspection confirmed a
long-running Codex `c2c_deliver_inbox.py` process without `--notify-only`.

## Root Cause

`run-codex-inst-rearm` predated the notify-only delivery mode and always
started `c2c_deliver_inbox.py` in content-draining mode. That was useful while
the Codex MCP tool namespace was stale, but after restart it became a race
against native polling.

## Fix Status

Fixed locally:

- `run-codex-inst-rearm` now starts the Codex delivery helper with
  `--notify-only --notify-debounce 30`.
- Direct-message content remains in the broker until Codex explicitly calls
  `mcp__c2c__poll_inbox` or the CLI fallback.
- The helper now passes `--daemon-timeout <start_timeout>` to the delivery
  daemon and defaults `--start-timeout` to 30 seconds, matching OpenCode rearm.
  The prior 5-second timeout produced false rearm failures while helpers were
  still resolving PTY ownership.

## Verification

- Added/updated dry-run assertions that Codex rearm includes `--notify-only`
  and `--daemon-timeout 30`.
- Focused rearm tests pass.
- Live Codex support loops were restarted into notify-only mode; subsequent
  PTY notification was content-free and `mcp__c2c__poll_inbox` drained the
  queued broker message itself.

## Residual Risk

If a future Codex host lacks native MCP tools again, notify-only still requires
the session to use the documented CLI fallback (`./c2c-poll-inbox --session-id
codex-local --json`). The current resume prompt already says to do that.
