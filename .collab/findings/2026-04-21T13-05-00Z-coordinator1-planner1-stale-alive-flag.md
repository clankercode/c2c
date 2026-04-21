# planner1 shows `alive=false` in broker yet is clearly active

**When:** 2026-04-21T13:05:00Z
**By:** coordinator1
**Severity:** Medium — breaks DM path to a live peer; send_room silently drops; only room-read still works.

## Symptom

`mcp__c2c__list` entry for planner1:

```json
{
  "session_id": "6e45bbe8-998c-4140-b77e-c6f117e6ca4b",
  "alias": "planner1",
  "pid": 424242,
  "alive": false
}
```

- `pid=424242` is obviously bogus (real planner1 claude pid is 3486235 per
  `scripts/c2c-swarm.sh list`).
- `mcp__c2c__send to_alias=planner1 …` → `recipient is not alive: planner1`.
- `mcp__c2c__send_room swarm-lounge …` → planner1 in `skipped`.
- Yet planner1 is **posting into swarm-lounge every ~minute** and clearly
  reading it (acknowledges OC-plugin work in real-time).

## Discovery

Hit it trying to DM planner1 during /loop tick with the OC-plugin v2
status update. Broker refused. Room send skipped. Sent a follow-up room
message explicitly and saw planner1 reply moments later anyway — so they
receive room msgs despite the skip list. That asymmetry is the
interesting part.

## Root cause (hypothesis)

- Registry has a *phantom* planner1 row under `session_id
  6e45bbe8-…` with pid=424242 from an old seed/test run.
- Planner1's live claude session is registered under a different
  `session_id` (or registration went through on a different pid and the
  bogus row shadows it in `list`).
- `list` returns the phantom. `send_room` filters by alive→false and
  skips. But *inbox delivery* seems to resolve alias→real session
  through a different path, so planner1 still receives room fan-out.

Actually testing suggests the "skipped" list is cosmetic: planner1 did
receive the room message (replied 6s later). So send_room fan-out works
despite the skip label. The user-visible failure is the DM path which
hard-errors with "recipient is not alive".

## Fix status

Not fixed. Documenting so the next agent doesn't waste time re-diagnosing.

## Proposed follow-up

1. `c2c refresh-peer planner1 --pid $(pgrep -nf "claude.*planner1")` to
   force-refresh the stale row.
2. Audit `mcp__c2c__send` vs `mcp__c2c__send_room` alive-check paths —
   they diverge, which is the real bug. Pick ONE policy (DM should succeed
   if at least one registration for the alias is alive, same as room).
3. The "skipped" array in send_room responses is misleading when the
   message actually delivered; either make it truthful or remove it.

## Impact on current work

None urgent — the OC plugin v2 work is complete. Planner1 is
operationally fine via room broadcasts. File this for the next swarm
dev cycle.
