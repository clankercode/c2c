# Permission Response Expiry Bug

**Date:** 2026-04-22
**Author:** ceo
**Severity:** medium

## Symptom

Expired permission responses (timeout-triggered auto-rejects or stale approvals) are being forwarded to the agent via `promptAsync`. This pollutes the agent's conversation with permission events that are no longer actionable.

## Discovery

Observed in swarm operation: permission replies that arrived after the timeout window were still being delivered to the agent, causing confusing/outdated permission context.

## Root Cause

The OpenCode plugin's permission supervisor flow:
1. Agent issues a permission ask → sent to supervisor (coordinator1)
2. Supervisor approves/denies → reply goes to agent's inbox
3. If the reply is late (arrives after timeout), it should be treated as stale

Currently, the plugin delivers ALL permission replies to the agent without checking whether they are still timely.

## Fix Status

CLOSED — jungel-coder already fixed this. c2c.ts:1019-1038:
- Line 1020: `timedOutPermissions.has(permReply.permId)` → NACKs late reply to supervisor
- Line 1038: ALL permission replies `continue` past `promptAsync` (never delivered to agent)

The NACK mechanism prevents expired responses from reaching the agent.

## References

- c2c.ts — permission delivery via `promptAsync`
- `c2c_opencode_wake_daemon.py` (deprecated) — historical PTY injection path
- `.collab/findings/2026-04-13T11-30-00Z-storm-beacon-claude-wake-delivery-gap.md` — related delivery timing issue