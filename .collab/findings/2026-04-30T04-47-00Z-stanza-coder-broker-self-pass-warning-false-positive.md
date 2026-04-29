# Broker self-pass-warning false-positives canonical "peer-PASS by <reviewer>" DMs

- **Date:** 2026-04-30 04:47 UTC
- **Filed by:** stanza-coder
- **Severity:** Low (false-positive warning, no functional harm)
- **Cross-references:** slice 3 of #142 peer-PASS (fern→stanza review of `77bfc2bd`)

## Symptom

When a reviewer DMs the coordinator with the canonical peer-PASS handoff
text, the broker's anti-self-pass heuristic adds a warning that's a
false positive:

```json
{
  "queued": true,
  "ts": ...,
  "from_alias": "stanza-coder",
  "to_alias": "coordinator1",
  "self_pass_warning": "self-review-via-skill violation: 'peer-PASS by stanza-coder' detected in message content (your own alias)"
}
```

## Mechanism

The canonical handoff for peer-PASS reviewing is:
- Reviewer runs `review-and-fix` against another agent's SHA.
- Reviewer DMs coordinator with `peer-PASS by <reviewer-alias>, SHA=<X>`.
- Coordinator picks up cherry-pick.

The broker detects "peer-PASS by <sender-alias>" in the DM body and
flags it as "self-review-via-skill violation". But the canonical
phrasing IS "peer-PASS by <reviewer>", and when the reviewer is the
DM sender (which it always is), `<reviewer>` == sender by definition.

The detection rule is too aggressive — it can't distinguish between:
- (legitimate) "peer-PASS by stanza-coder, SHA=`<work I reviewed>`"
- (illegitimate) "peer-PASS by stanza-coder, SHA=`<work I authored>`"

Without knowing the SHA's author, the broker can't tell if it's a
self-pass. The current implementation false-positives the legitimate
case.

## Impact

- No functional harm: DMs deliver, peer-PASS artifacts sign correctly.
- Noise in DM tool output (the `self_pass_warning` field).
- Potential operator confusion if anyone takes the warning at face
  value.
- Coordinator may discount legitimate peer-PASSes if the warning is
  parsed automatically downstream.

## Suggested mitigation

Option A — Suppress the warning when the DM is to coordinator alias
AND the body matches the canonical "peer-PASS by <sender>, SHA=<X>"
shape: that's the legitimate handoff pattern.

Option B — Cross-check the SHA's git author against the reviewer alias
in the DM body: if author != reviewer, the peer-PASS claim is
legitimate (reviewer is reviewing someone else's work).

Option C — Drop the warning entirely; rely on the signed peer-PASS
artifact (which IS author-vs-reviewer-checked) as the canonical
gate. The DM warning is purely advisory anyway.

Option B is the most informative; option C is the simplest. Option
A is fast but doesn't fully solve it (operators may use non-canonical
phrasing).

## Action items

- [ ] Locate the warning logic (likely in `c2c_mcp.ml`'s send-handler
  or a peer-pass-aware filter; grep for `self_pass_warning` /
  `self-review-via-skill`).
- [ ] Pick Option B or C, file as a small slice.
- [ ] Update CLAUDE.md / role files if peer-PASS handoff phrasing
  changes (currently canonical is "peer-PASS by <alias>, SHA=<X>").

🪨 — stanza-coder
