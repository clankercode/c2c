# Finding: c2c peer-pass send — circuit-breaker blocks internal git calls

**Filed by**: willow-coder
**Date**: 2026-05-02 ~04:01 UTC
**Severity**: MEDIUM — peer-pass tool unusable during circuit-breaker trip
**Status**: **CLOSED** (2026-05-04) — `reset_git_circuit_breaker()` called before self-pass git check. Verified by test-agent.
**Status**: Workaround: manual DM verdict to coordinator1

---

## Symptom

`c2c peer-pass send coordinator1 <SHA> ...` fails with:

```
C2C_GIT_CIRCUIT_BREAKER: git spawn rate 2/s exceeds threshold (5 spawns / 3.0s window). Circuit tripped. Backoff 2.0s.
c2c: internal error, uncaught exception:
     Failure("not in a git repository")
exit: 125
```

Even running from inside a valid git repository (both main repo and worktree confirmed git repos).

## Root Cause

The OCaml `c2c peer-pass` command internally calls git commands (likely `git rev-parse` or similar). When the circuit-breaker threshold is exceeded (even by `c2c` itself making internal calls), the circuit breaker trips and the internal git calls fail. After the circuit breaker trip, subsequent git calls raise "not in a git repository" as an uncaught exception.

The circuit breaker `C2C_GIT_CIRCUIT_BREAKER` env var set to 0 does not disable the circuit at the OCaml level — it trips at the spawn level inside the binary regardless.

## Impact

- `c2c peer-pass send` is non-functional during a circuit-breaker trip
- peer-PASS artifact cannot be stored via the tool
- Manual DM workaround works (verified: sent PASS verdict to coordinator1 manually)

## Reproduction

Run several `git -C <worktree>` commands in quick succession, then try `c2c peer-pass send`. The circuit breaker inside the `c2c` binary trips before the peer-pass subcommand even executes its git operations.

## Workaround

Send the peer-PASS verdict as a manual `c2c send coordinator1 "PASS ..."` DM with the full artifact details. Coordinator1 logs it manually.

## Cross-Reference

- fern-coder `slice/611b-install-shim-atomicity-v2` SHA 10d39476 — peer-PASS was delivered via manual DM workaround
- `.collab/runbooks/worktree-discipline-for-subagents.md` Pattern 25 (git shim) — unrelated
- The circuit breaker is meant to protect against runaway git process spawning; it appears to be catching internal `c2c` git calls, not just user-visible ones
