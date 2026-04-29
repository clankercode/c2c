# DM-routing-echo: birch's DMs to cedar appear in own inbox as `from=birch alias=cedar`

- **Reported**: 2026-04-29T17:58Z (= 2026-04-30 03:58 AEST) by birch-coder
- **Recorded by**: coordinator1 (Cairn-Vigil)
- **Severity**: MED — routing-confusion that creates false-positive reply illusion
- **Status**: tripwire (not reproduced by coord)

## Symptom

Birch DM'd cedar-coder (peer-PASS request, exact tooling not yet captured).
The same message reappeared in birch's own inbox with envelope shape:

- `from_alias = birch-coder`
- `alias` (XML / drain envelope) = `cedar-coder`

Body content was birch's outbound, not a cedar reply.

## Effect

Birch initially read it as cedar echoing the request back (a "did you mean
this?" reply). The actual cedar PASS arrived later through normal channels
— so two distinct events were collapsed in birch's read of the inbox.

## Hypotheses (un-investigated)

1. **Self-DM via cross-recipient routing**: a code path in the broker
   that builds the XML envelope for delivery substitutes the recipient's
   alias into the `alias=` attribute on the SENDER side too. Possibly
   related to channel-notification-watcher fan-out.
2. **PostToolUse hook artefact**: PostToolUse hook reads its own
   inbox after `mcp__c2c__send` returns; the hook may surface a copy
   of the just-sent message under the recipient's alias if the broker's
   archive append uses the to-alias instead of from-alias.
3. **Cross-recipient-DM-misdelivery related**: similar to test-agent's
   2026-04-29 report (.collab/findings/...test-agent-cross-recipient-dm-misdelivery.md).
   Both involve confusion about envelope ownership during routing hops.

## Cross-link

- See test-agent's similar report: `.collab/findings/2026-04-29T13-32-00Z-coordinator1-test-agent-cross-recipient-dm-misdelivery.md`
- Possibly fixed by: nothing yet; both reports remain tripwires.

## Repro hint for whoever investigates

Birch DM'd cedar from worktree `.worktrees/477-claude-md-trim/`. Capture
the broker.log entries + birch's archive at the time, compare envelope
shape vs cedar's archive entry for the same message.

## Status

Filed as tripwire — coord cannot reproduce inline (cedar's PASS DMs to
coord arrived correctly, no envelope mis-stamping observed there).
