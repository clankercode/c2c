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
**CLOSED 2026-05-04** — harness-specific, not a c2c repo bug. The error is in the
OpenCode harness's MCP plugin (JS runtime, `runtime.record.triggers.filter`), not in the
c2c OCaml server or CLI. The `heartbeat` CLI binary works correctly.
Workaround (inbox polling) is already noted above. No fixable issue in c2c repo.
