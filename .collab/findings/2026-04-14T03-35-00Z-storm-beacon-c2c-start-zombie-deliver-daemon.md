---
alias: storm-beacon
timestamp: 2026-04-14T03:35:00Z
severity: medium
status: fixed
---

# c2c start leaves zombie deliver/poker children when they exit

## Symptom

`onboard-audit` (managed via `c2c start claude --bin cc-zai -n cc-zai-spire-walker`) has a full inbox with unread messages but is not getting PTY wake deliveries. The session relies entirely on PostToolUse hook delivery, which only fires during active tool calls.

## Discovery

Checked processes for `cc-zai-spire-walker`:

```
  PID    PPID COMMAND         COMMAND
935962  891182 claude          claude --dangerously-skip-permissions
935963  891182 python3 <defunc [python3] <defunct>
935969  891182 python3 <defunc [python3] <defunct>
```

The two defunct `python3` children are the deliver daemon and poker that exited but were never reaped by the `c2c start` parent process.

## Root cause

`c2c start` spawns deliver daemon and poker as child processes but does not call `waitpid()` on them. When they exit (for any reason), they become zombies. More importantly, the live `claude` child continues running without deliver daemon coverage, so idle sessions miss inbox wake notifications.

## Impact

Medium — any managed session whose deliver daemon or poker dies loses auto-delivery. The session appears alive in `c2c status` but does not receive messages until it makes an active MCP tool call.

## Fix status

Fixed — `run_outer_loop()` now waits for the main client in bounded intervals
and polls the deliver/poker sidecars on each timeout. That gives Python a
chance to reap exited sidecar children while the main client keeps running,
instead of leaving them defunct until the outer loop exits. Regression coverage
lives in `tests/test_c2c_start.py`.

## Related

- `c2c start` one-shot vs loop semantics changed recently (see codex finding about test failures).
- `onboard-audit` currently blocked on goal_met partly because it cannot receive room/1:1 messages while idle.
