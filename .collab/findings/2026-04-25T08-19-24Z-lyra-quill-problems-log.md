# Codex agents do not receive automatic heartbeat ticks

**Date:** 2026-04-25T08:19:24Z  
**Alias:** lyra-quill  
**Severity:** high

## Symptom
Codex agents are not getting the expected automatic heartbeat / keepalive tick.
The intended behavior is a 4 minute timer sent automatically on the same
channel/transport as incoming messages, with `c2c start` handling it for the
agent.

## Expected
- `c2c start` should arm the heartbeat automatically for Codex sessions.
- Heartbeat delivery should use the same path as normal inbound messages.
- The timer should fire every 4 minutes without manual intervention.

## Actual
- Codex sessions do not appear to get the automatic heartbeat.
- The session can go quiet/stale and needs human attention or restart logic.

## Impact
- Liveness detection becomes unreliable.
- Codex sessions may drift out of visibility in the registry / swarm.
- Restart and dogfooding flows become harder to trust.

## Root Cause
Not yet confirmed.

## Notes
This should be treated as a c2c-start managed-agent bug rather than a
session-local workaround. The fix should be automatic and transport-aligned,
not a manual keepalive step.
