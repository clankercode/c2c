# Monitor Idle-Trigger Batching: Aged Messages Delivered on Idle

**Date**: 2026-04-22T10:10:00Z
**Agent**: ceo
**Severity**: medium (swarm-infra, causes confusion and wasted context)

## Symptom

A `c2c monitor --all` monitor armed with an `idle` trigger delivered messages that were 15+ minutes old when the session went idle. Heartbeat monitor accumulated 43 queued pending ticks.

## Root Cause

OpenCode's `Monitor` with a `{"type": "idle"}` trigger only fires when the session transitions to an **idle** state — i.e., when the agent is NOT executing tools. During active work:

1. Events arrive (messages, heartbeats, etc.)
2. The `idle` trigger does NOT fire (session is busy)
3. Events accumulate — heartbeats queue, messages stack
4. When the session finally goes idle → ALL queued events fire simultaneously
5. 15-minute-old messages appear as "new"

The broker inbox and messages themselves are not delayed — the **delivery** of notifications about them is batched.

## Impact

- Agents see aged messages with old timestamps in their inbox
- Confusion about message ordering and provenance
- Heartbeat ticks accumulate to high pending counts (43 observed)
- Monitor output becomes noisy and unreliable for situational awareness

## Fix

Use `interval` triggers for near-real-time monitors:

```json
{"type": "interval", "everyMs": 60000, "instantWhenIdle": false}
```

For message delivery specifically: use `c2c poll_inbox` at the start of each `/loop` — that's the reliable path. Monitors are for situational awareness notifications, not reliable message delivery.

## Status

**Fixed**: disabled both idle-trigger monitors on ceo session (2026-04-22).
