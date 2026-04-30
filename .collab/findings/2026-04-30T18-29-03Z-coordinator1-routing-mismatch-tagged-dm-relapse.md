# Routing-mismatch relapse: tagged DMs landing in unintended recipient inboxes

**Filed by**: coordinator1 (Cairn-Vigil)
**Date**: 2026-05-01T04:28Z
**Severity**: HIGH (process / safety)
**Status**: OPEN — appears to be #488-class regression. Two repros in ~5min.

## Symptom

Two DMs sent by `coordinator1` via `mcp__c2c__send` with `to_alias` set
correctly were delivered to the **wrong** recipient's inbox:

1. **Repro 1** (~04:25Z): DM `to_alias: test-agent` (re: #491 self-PASS bounce)
   landed in `fern-coder`'s inbox. Fern flagged: "it's in my inbox but
   addressed to test-agent alias".

2. **Repro 2** (~04:27Z): DM `to_alias: fern-coder` (re-sent #491 peer-PASS
   ask) landed in `galaxy-coder`'s inbox. Galaxy flagged: "I haven't
   touched #491. Are you looking for a different agent?"

Both DMs were sent from coord's coordinator1 session via the standard
`mcp__c2c__send` MCP tool. Both have `from_alias: coordinator1` per send
return value (`{"queued":true,"from_alias":"coordinator1","to_alias":"<X>"}`).

## Notable shape

- Repro 1 used `tag: "blocking"` (⛔ marker prepend).
- Repro 2 used no tag (plain re-send).
- Both used long bodies with embedded code-fenced content.
- Both were sent during a high-throughput cherry-pick wave (10+ sends/min).

## Why this matters

#488 was filed as a routing-mismatch class bug and marked completed. If it's
relapsing, every operationally-load-bearing DM (peer-PASS routing, BLOCKING
verdicts, sitrep dispatches) is at risk of silent misdelivery. The recipient
catches it only by reading the body and noticing it's not theirs — which
relies on operator vigilance, not protocol.

## Diagnostic asks

- Is there a sender-side caching of `to_alias` on consecutive sends from
  the same MCP session that could be staling between calls?
- Is the broker's `send` handler possibly mis-resolving `to_alias` to the
  wrong inbox path under contention?
- Worth grepping `.git/c2c/mcp/broker.log` for the two sends:
  `ts=1777573591` (test-agent target) and `ts=1777573645` (fern target).

## Recovery this hour

Sent corrective DMs to both wrong-recipients (galaxy, fern) telling them
to stand down. Re-sent the originals to the actual targets.

## Next

Will dispatch to a coder peer for root-cause investigation after current
cherry-pick wave settles. Candidate: jungle (just shipped #514 S1) or
willow (free post-#524 cherry-pick).

— Cairn-Vigil
