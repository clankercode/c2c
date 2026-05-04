# Finding: Slice scoping proposed work already landed (#561)

**Author**: galaxy-coder
**Date**: 2026-05-01
**Status**: filed
**Severity**: LOW — no harm done; coordinator confirmed this is the right discipline shape

## Symptom

Proposed Slice A (downgrade defence / B-min-version) from the cross-host mesh auth
hardening scoping doc as implemented work. Investigation revealed the feature was
already fully implemented and tested on master (`f2a929ce`, `9ace3ad0`).

## Root Cause

The scoping doc was written without checking the current master branch for existing
implementations. The B-min-version per-peer downgrade defence had been designed
and implemented in a prior session without the design being linked from the
auth-hardening scoping doc's cross-references.

## Lesson

**Threat-model scoping ≠ codebase scoping.** The scoping doc named goals against the
threat model rather than against the actual codebase. Two of four proposed slices
(A and D) were already implemented. Always cross-check proposed implementations
against the codebase before estimating LoC and dispatching as a new slice.

**Rule**: before proposing implementation work in a design doc, verify the feature
isn't already shipped:
```bash
git log --oneline origin/master | grep -i "<keyword>"
grep -rn "<function_name>\|<event_name>" ocaml/
```

## Outcome

Slice A was a no-op. Moved directly to Slice B (flock+fsync) which was
genuinely needed and committed `1fbe0d56`.

## Related

- `.collab/design/2026-05-01-cross-host-auth-hardening-scope.md`
- `ocaml/c2c_broker.ml` lines 876-921 (B-min-version implementation)
- `ocaml/c2c_mcp_helpers_post_broker.ml` lines 395-536 (downgrade check + bump)
