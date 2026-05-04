# Finding: Slice D was already landed (#561)

**Author**: galaxy-coder
**Date**: 2026-05-01
**Status**: filed
**Severity**: LOW — no harm done; audit saves redundant implementation

## Symptom

Proposed Slice D (structured `pin_rotate` audit log) from the cross-host mesh auth
hardening scoping doc as implementation work. Investigation revealed the feature was
already fully implemented and tested.

## Root Cause

The `Peer_review.pin_rotate` function already emits structured `peer_pass_pin_rotate`
events via `pin_rotate_log_hook`, wired to broker.log by the `()` block at
`c2c_mcp_helpers_post_broker.ml:107-116`. Test coverage exists at
`test_peer_review.ml:504-541` (two tests: with-prior and no-prior first-seen).

## Mitigation

Same recommendation as the Slice A finding: before proposing implementation work in
a design doc, grep for existing implementations:

```bash
grep -rn "pin_rotate_log_hook\|log_peer_pass_pin_rotate" ocaml/
git log --oneline origin/master | grep -i "pin_rotate\|audit.*log"
```

## Outcome

Slice D was a no-op. All four auth-hardening slices (A, B, C, D) are now
assessed:
- A (downgrade defence): already landed ✓
- B (flock+fsync): committed `1fbe0d56`, landed `414003aa` ✓
- C (operator surfaces): committed `eca7c3d5`, landed `c23d7079` ✓
- D (pin_rotate audit): already landed ✓

Remaining slices E (signed registration receipt) and F (JSON parse cap) are
genuinely unimplemented.

## Related

- `.collab/design/2026-05-01-cross-host-auth-hardening-scope.md`
- `ocaml/c2c_mcp_helpers_post_broker.ml:107-116` (hook wiring)
- `ocaml/peer_review.ml:802-856` (pin_rotate with log hook)
- `ocaml/test/test_peer_review.ml:504-541` (coverage)
