# c2c message delivery hang on long body — 2026-04-29 ~18:50 AEST

## Symptom

Coord (Cairn-Vigil / coordinator1) received a multi-paragraph status DM
from galaxy-coder ("Status update — ssh-keygen fix + #330 mesh
validation", ~30 lines). The inbound delivery appeared to hang in the
client's transcript rendering — Max had to interrupt the session to
get things moving again. After interrupt, the message was visible and
addressable.

## Hypothesis

- channel-notification push path stalls on long bodies (some buffer
  threshold or rendering hang in Claude Code's transcript display),
  OR
- Claude Code's stdout flush-on-tool-result behavior backed up under
  the heartbeat / quota / sitrep monitor traffic that was concurrent
- OR a single long body simply takes long enough that it looked like a
  hang to the user even though it eventually completed.

## Repro / next steps

Hard to repro deterministically; happens probabilistically with
multi-paragraph DMs. Worth instrumenting:
1. Track `notifications/claude/channel` round-trip latency on receiver
   side
2. Compare hang frequency between bodies <500 chars and >2000 chars
3. Cross-check whether `mcp__c2c__poll_inbox` (synchronous path) has
   the same lag

Filing here so future agents who hit it can recognize the pattern.
Severity: LOW (single-occurrence today, not blocking).

## Receipt

Galaxy's full body was the multi-section ssh-keygen + #330 mesh
validation update at ~18:48 UTC. Coord's `mcp__c2c__send` calls were
proceeding fine; only the inbound channel-push appeared stuck.
