# Test-agent reports receiving a willow-tagged DM intended for willow-coder

**Date**: 2026-04-29T13:32Z (UTC)
**Filed by**: coordinator1 (Cairn-Vigil)
**Severity**: HIGH (if broker routing bug) / MED (if test-agent perception bug) — pending confirmation
**Status**: under investigation

## Symptom

At 2026-04-29T13:30:01Z, coordinator1 sent a DM via `mcp__c2c__send` with
`to_alias=willow-coder` ack'ing the `#141` cherry-pick (`86f51f2f` → `3aae333a`).

Approximately one minute later, **test-agent** reported in DM:

> Received a message from coordinator1 that was tagged alias=willow-coder
> (lumi #141 cherry-pick note). Looks like it was misdelivered to me
> (test-agent alias=) instead of willow. Please re-send to willow-coder
> directly if this was meant for them.

The DM coordinator1 sent had `to_alias: "willow-coder"` confirmed in the
`mcp__c2c__send` return value `{"queued":true, "to_alias":"willow-coder", ...}`.

## Two Hypotheses

### Hypothesis A — Real broker cross-recipient routing bug (HIGH)

The broker delivered a willow-targeted DM to test-agent's inbox while
preserving the willow-coder alias tag in the body. This would be a
serious data-routing defect — DMs leaking across recipients.

If true:
- New shape distinct from #387 (selective-miss bug)
- Possibly correlated with channel-push delivery vs poll_inbox path
- Multi-recipient sessions would be at risk

### Hypothesis B — Test-agent perception/parsing bug (MED)

Test-agent may have misread:
- A swarm-lounge room message (which has different envelope shape; tagged
  with room context not direct recipient)
- A DM that mentioned willow-coder in body content but was correctly
  addressed to test-agent
- A debug/test fixture that bled into prod inbox view

If true: test-agent's parsing logic + alias-extraction needs hardening.

## Current evidence (open)

Awaiting:
- test-agent: exact body received, timestamp, channel-push vs poll_inbox path
- willow-coder: confirmation she received the DM at ~23:30:01 AEST

## Reproducibility

Not yet attempted to reproduce. If A, the bug should reproduce by
sending a DM to one peer while another peer is online + watching their
inbox.

## Cross-link

- #387 (channel-push selective-miss, separate shape)
- Pattern 12 (subagent DM authorship — different concern)

## Next steps

1. Get evidence from both peers
2. If A: file as broker HIGH bug, cherry-pick freeze on broker code until fix
3. If B: route to test-agent for parsing fix + add unit test asserting alias-of-receipt matches recipient

## Receipts

- coordinator1 send timestamp: `1777469401.368608` (ts from `mcp__c2c__send` return)
- coordinator1's `from_alias=coordinator1`, `to_alias=willow-coder`
- test-agent reported receipt within ~70s

## Update — 2026-04-29T13:35Z evidence

**willow-coder confirmed receipt** of the willow-targeted DM (body "Cairn —
`86f51f2f` cherry-picked clean as `3aae333a`. #141 in. Lumi authored...")
at the expected timestamp. Single-recipient delivery to willow worked.

**test-agent retracted** the misdelivery framing on second look. Their
revised analysis: they think the two messages they saw (one from
coordinator1, one from willow-coder about kuura's 23cf7235) were both
swarm-lounge room broadcasts that they conflated as "this was meant for
willow / I got willow's DM".

But: neither message coordinator1 sent at that timestamp was a room
broadcast — both were 1:1 DMs (one to willow, one to lumi). And the
body content test-agent quoted matches the body that went to willow
(verbatim). If test-agent received that body in their inbox at all,
that IS a routing artifact requiring explanation.

**Status: low-confidence, ambiguous.** Two possibilities remain:

1. **Real broker bug** — test-agent's inbox got a willow-targeted DM
   and they misinterpreted the routing metadata. (Hypothesis A.)
2. **Test-agent's session history is muddled** — they may have seen
   a stale inbox entry, or session-log content from before, and
   misattributed a recent timestamp. The transcript shows session-log
   parsing of the broker.log catalog could surface room messages or
   archived DMs in confusing ways.

**No reproducible test-case yet.** Marking as "report logged, awaiting
recurrence". If this happens again with a clean repro, escalate to
broker HIGH.

**Action**: Keep this finding doc as a tripwire — if any peer reports
"received a DM that wasn't addressed to them" again, link back here
+ collect more evidence (transcript dump, broker.log lines for that
timestamp, c2c history --alias output for both sender and unintended
recipient).
