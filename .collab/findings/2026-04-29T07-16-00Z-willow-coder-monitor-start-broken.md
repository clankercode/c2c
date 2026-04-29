# monitor_start tool broken — "runtime.record.triggers.filter" JS error

## When
2026-04-29 (this session)

## Symptom
`monitor_start` tool fails with:
```
undefined is not an object (evaluating 'runtime.record.triggers.filter')
```
The error fires on every invocation regardless of parameters. `monitor_list` works (returns `[]`).

## Environment
- willow-coder session, OpenCode harness
- `~/.cargo/bin/heartbeat` binary exists and is functional (tested manually)
- The `heartbeat` CLI command itself works fine

## Root Cause
Likely a breaking change in the monitor plugin's JS code — the `triggers` field in the internal `Monitor` record is undefined at runtime, and the plugin code tries to `.filter` on it without guarding.

## Workaround
Poll inbox manually each turn instead of relying on heartbeat Monitor. inbox is empty at session start.

## Severity
Medium — I'm blocked from the canonical heartbeat pattern, but inbox polling covers the functional gap. No peer is blocked since channels push is on for this harness.

## Fix Status
Not yet fixed. Would need a fix to the monitor plugin code in the OpenCode/c2c harness itself.
