# Crush Interactive TUI Wake Proof

- **Time:** 2026-04-13T17:35:58Z
- **Agent:** codex
- **Severity:** Medium until proven; now resolved for Codex<->Crush live TUI delivery
- **Status:** Live-proven and documented

## Symptom

Crush MCP setup and one-shot `crush run` poll-and-reply were already proven, but
the remaining gap was active-session delivery: could an already-running Crush TUI
receive a broker-native DM after only a PTY notification, then poll and reply
through MCP itself?

## How I Discovered It

After fixing `run-crush-inst-outer` to refresh the broker registration after
child spawn, I found a live Crush registration:

- alias/session: `crush-xertrov-x-game`
- broker session_id: `crush-xertrov-x-game`
- active room: `swarm-lounge`

There was no Crush notify daemon running, so the active TUI still needed a wake
path before the proof could be attempted.

## Proof Path

1. Armed notify-only delivery against the live Crush process with
   `run-crush-inst-rearm`.
2. Sent a direct 1:1 broker-native DM from Codex to `crush-xertrov-x-game` using
   `mcp__c2c__send`.
3. The DM body included marker `CRUSH_INTERACTIVE_WAKE_ACK 1776101709`.
4. The notify-only daemon injected only a poll notification into the Crush PTY;
   it did not inject the message body.
5. Crush called `mcp__c2c__poll_inbox`, read the broker-native DM, and replied
   directly to Codex with `mcp__c2c__send`.
6. Codex drained the direct reply via `mcp__c2c__poll_inbox`:
   `CRUSH_INTERACTIVE_WAKE_ACK 1776101709`.

## Root Cause / Risk

The implementation already had the right pieces, but the proof was blocked by
process identity drift and lack of a live notify daemon. `run-crush-inst-outer`
now refreshes broker registration after each child spawn, which closes the stale
PID window for managed restarts. The interactive proof used the same notify-only
pattern as the managed harness.

## Fix Status

- `run-crush-inst-outer` refresh-peer fix committed in `8f549d5`.
- Live Codex<->Crush interactive TUI wake proof succeeded.
- Message content stayed broker-native; PTY carried only the wake notification.

## Remaining Follow-up

Keep the distinction clear in docs and tests:

- Codex<->Crush active TUI delivery is proven.
- Other sender pairs into Crush still need their own live active-session proof
  if the matrix requires per-pair validation.
- Managed outer-loop relaunch behavior should continue to be watched because
  Crush process PIDs rotate quickly.
