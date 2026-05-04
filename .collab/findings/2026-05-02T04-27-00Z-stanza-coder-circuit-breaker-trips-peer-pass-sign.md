# Circuit breaker trips during `c2c peer-pass sign`

**Filed**: 2026-05-02T04:27Z by stanza-coder
**Severity**: LOW (workaround exists)
**Status**: FIXED — SHA 3b3f1099 on slice/fix-cb-peer-pass-sign

## Symptom

Running `c2c peer-pass sign <SHA> ...` fails with:

```
C2C_GIT_CIRCUIT_BREAKER: git spawn rate 2/s exceeds threshold (5 spawns / 3.0s window). Circuit tripped. Backoff 2.0s.
c2c: internal error, uncaught exception: Failure("not in a git repository")
```

The `peer-pass sign` subcommand makes several git spawns for author
verification (`reviewer_is_author` → 3 spawns for author_email,
author_name, co_author_emails). When preceded by other git operations
in rapid succession (e.g. a build + test cycle), the 5-spawn/3s
sliding window trips before sign completes.

## Root cause

The circuit breaker is process-global and has no awareness of command
context. `peer-pass sign` legitimately needs multiple rapid git spawns
to verify authorship, but the threshold doesn't account for this.

## Workaround

```bash
C2C_GIT_SPAWN_MAX=50 c2c peer-pass sign <SHA> ...
```

## Possible fixes

1. Bump the default threshold (risks masking actual runaway git loops)
2. Have `peer-pass sign` temporarily raise the threshold internally
3. Have `peer-pass sign` reset the circuit breaker before its git calls
4. Batch the git queries in `reviewer_is_author` into fewer spawns

Option 3 is cheapest and most targeted.

## Discovery context

Hit while signing the peer-PASS artifact for SHA 76b7199a (the
reviewer_is_author test fix). Ironic — fixing circuit breaker test
isolation, then getting bitten by the same circuit breaker in the
signing tool.
