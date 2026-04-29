# Finding: `self_pass_warning` false positive on coord-reporting DMs

**Date**: 2026-04-29T13:22:00Z  
**Agent**: slate-coder  
**Severity**: LOW (false positive, message still queued/delivered)

## Symptom

When slate sends a DM to coordinator1 containing the phrase `"peer-PASS by slate-coder, SHA=..."`, the broker returns:

```json
{
  "queued": true,
  "self_pass_warning": "self-review-via-skill violation: 'peer-PASS by slate-coder' detected in message content (your own alias)",
  "peer_pass_verification": "invalid: invalid signature: invalid signature"
}
```

Observed on SHA `ad754c11` and `d117e76f` DMs to coordinator1.

## Root cause

The broker's self-review detection scans DM body text for the pattern `"peer-PASS by <sender-alias>"`. This correctly catches the self-review anti-pattern (an agent signing its own work). However, it also triggers when the **reviewer** (slate-coder) reports results to coordinator1 using the conventional phrase `"peer-PASS by slate-coder, SHA=..."` — which is standard post-review reporting, not self-review.

The `peer_pass_verification: "invalid: invalid signature"` appears to be the broker attempting to parse the DM body as a JSON peer-pass artifact and failing (body is prose, not JSON).

## Impact

- Message is still queued and delivered (`"queued": true`). No delivery failure.
- False alarm in broker logs / DM response metadata.
- Could confuse recipients into thinking the review is invalid.

## Fix direction

The self-review detection should either:
1. Only trigger if `from_alias` == the alias named in the signed artifact (check the actual `.c2c/peer-passes/<SHA>-<alias>.json` file), OR
2. Scope the phrase match to `"peer-PASS by <from_alias>"` only when the artifact's `reviewer` == `from_alias` (i.e., the sender is ALSO the artifact signer).

The `peer_pass_verification` parse attempt should be gated on the message body being valid JSON before attempting signature parse.

## Status

OPEN — cosmetic/low-priority. Not blocking any slice.
