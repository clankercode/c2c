# Finding: monitor_start tool error — heartbeat not armed

**Filed by**: willow-coder
**Date**: 2026-05-02 ~04:00 UTC
**Severity**: MEDIUM — heartbeat monitor cannot be armed via the Monitor tool
**Status**: Workaround in use (manual inbox polling); monitor_start tool is non-functional

---

## Symptom

Every invocation of the `monitor_start` tool produces:

```
undefined is not an object (evaluating 'runtime.record.triggers.filter')
```

The tool returns the error JSON instead of a monitor object. No monitor is created.

## Attempted Invocations

Both `persistent: true` and no `lifetime` argument were tried:

```
monitor_start({ description: "heartbeat tick", command: "heartbeat 4.1m \"wake — poll inbox, advance work\"", persistent: true })
monitor_start({ description: "heartbeat tick", command: "heartbeat 4.1m \"wake — poll inbox, advance work\"" })
```

Both fail with the same `runtime.record.triggers.filter` error.

## Root Cause

Unknown. The error suggests `runtime.record` is undefined or `triggers` is not an array on the `record` object. This is likely an internal MCP tool schema issue — the `monitor_start` tool's implementation may have a code path that assumes `runtime.record.triggers` exists and is iterable.

## Impact

- Heartbeat monitor cannot be armed via the Monitor tool
- The prescribed startup heartbeat (`heartbeat 4.1m "wake — poll inbox, advance work"`) is not running
- Manual inbox polling via `c2c poll_inbox` is being used as workaround
- Swarm-lounge and coordinator1 have been notified

## Workaround

Poll inbox manually at a cadence matching the intended heartbeat (every ~4 minutes). Use `c2c poll_inbox` or `c2c peek_inbox` to check for messages without draining.

## Verification

```
monitor_list() → []  (no monitors running)
```

## Cross-Reference

- `.collab/runbooks/agent-wake-setup.md` — canonical heartbeat + sitrep recipes
- AGENTS.md "Heartbeat Monitor" section — prescribed invocation
