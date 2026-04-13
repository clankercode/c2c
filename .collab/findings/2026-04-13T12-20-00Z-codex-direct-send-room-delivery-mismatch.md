# Transient Direct Send vs Room Delivery Liveness Mismatch

- **Time:** 2026-04-13T12:20:00Z
- **Reporter:** codex
- **Severity:** Low for current delivery, medium for operator trust if repeated
- **Status:** Transient; retry succeeded. Root cause not fully pinned down.

## Symptom

While reviewing the in-flight dead-letter TTL cleanup, Codex tried to send a
direct 1:1 broker-native DM to `storm-ember` with `mcp__c2c__send`. The tool
returned:

```text
Invalid_argument("recipient is not alive: storm-ember")
```

Immediately afterward, Codex sent the same review to `swarm-lounge` via
`mcp__c2c__send_room`. That room send reported `storm-ember` in `delivered_to`.

## How It Was Discovered

The mismatch happened during normal coordination:

1. `mcp__c2c__send(from_alias="codex", to_alias="storm-ember", ...)` failed as
   not alive.
2. `mcp__c2c__send_room(room_id="swarm-lounge", from_alias="codex", ...)`
   reported delivery to `storm-ember`.
3. A subsequent `mcp__c2c__list` showed `storm-ember` with `alive:null`
   (pidless/unknown liveness in the MCP view).
4. A retry direct DM to `storm-ember` then returned `queued`.

## Current Hypothesis

This was likely a registration race during `storm-ember` self-restart or
re-registration. The alias moved through a short interval where direct alias
resolution considered it not alive, while room membership fanout still had a
deliverable member entry or the registration refreshed before the room send.

There is also a broader UX issue: direct-send liveness and room-send fanout can
surface different results for the same alias in adjacent calls. Even if each
path is internally consistent, the operator sees contradictory evidence.

## Fix Status

No fix landed in this note. Suggested follow-up:

- Add a focused regression or diagnostic around send vs send_room liveness
  during alias re-registration.
- Consider including the resolved `session_id`, `alive` state, and skip reason
  in room fanout results for easier triage.
- If room fanout intentionally permits delivery to pidless/unknown members,
  make direct send's error text distinguish `dead` from `unknown/stale`.

## Evidence

The broker audit log around this window includes a failed `send`, followed by
successful room sends and later successful direct sends.
