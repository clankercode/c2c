# Git Circuit Breaker — Threshold Design Note

**Author**: stanza-coder  
**Date**: 2026-05-02  
**Status**: Research / proposal — not a committed design

## Problem

The git circuit breaker (5 spawns / 3s sliding window, 2s backoff)
trips in legitimate CLI paths because many c2c operations compose
multiple git queries that individually make sense but collectively
exceed the threshold.

Three incidents in one session (2026-05-02):

1. **Test isolation** (89c582dd): `test_c2c_peer_pass.ml` runs 2
   `reviewer_is_author` calls × 3 spawns = 6 spawns per test, tripping
   within a single test.

2. **peer-pass sign** (7c670200): `validate_signing_allowed` calls
   `git_commit_exists` (1 spawn) + `reviewer_is_author` (3 spawns) = 4
   spawns. Combined with any prior git activity in the same process,
   trips the threshold.

3. **peer-pass list** (not yet hit, predicted): iterates N artifacts,
   each calling `git_commit_exists` + `reviewer_is_author` = 4 spawns.
   With N ≥ 2 in rapid succession, guaranteed trip.

## Current Architecture

```
Git_helpers.ml:
  git_first_line / git_all_lines
    └─ check_and_record_git_spawn()  ← sliding window counter
       events: float list (timestamps)
       tripped: bool
       threshold: 5 spawns / 3.0s window (env-overridable)
       backoff: 2.0s after trip
```

All git spawns go through `git_first_line` or `git_all_lines`. The
breaker is process-global (mutable record, not per-thread or
per-logical-operation).

## Why 5/3s?

The breaker was added to catch runaway git loops — e.g. a recursive
`find_real_git` that keeps spawning itself, or a polling loop that
hammers `git status`. The threshold was set conservatively: 5 spawns
in 3 seconds is a lot for an interactive CLI that typically does 1-2
git operations per command.

But c2c is not a typical CLI. Many subcommands are *composite* —
they do multiple git queries as part of a single logical operation:

| Path | Git spawns | Notes |
|------|-----------|-------|
| `reviewer_is_author` | 3 | author_email + author_name + co_author_emails |
| `validate_signing_allowed` | 4 | commit_exists + reviewer_is_author |
| `peer-pass verify` (anti-cheat) | 4 | commit_exists + reviewer_is_author |
| `peer-pass list` (N artifacts) | 4N | per-artifact self-review check |
| `c2c doctor` | 3+ | HEAD sha + common-dir + toplevel + more |

## Options

### A. Raise the default threshold

**Change**: `git_spawn_max` default from 5 → 20 (or 30).

**Pro**: Fixes all paths at once, no code changes needed elsewhere,
doesn't require callers to know about the breaker.

**Con**: Weakens the safety net. A genuine runaway loop that spawns
10 git processes before being caught is 2× worse than one caught at 5.
But in practice, runaway loops spawn unbounded — 20 vs 5 doesn't
meaningfully change the blast radius.

**Assessment**: Probably fine. The breaker is a safety net, not a
precision instrument. The legitimate use cases comfortably fit under
20, and runaway loops blow past any reasonable threshold.

### B. Reset-before-each-logical-op (current approach)

**Change**: Callers of `reviewer_is_author` (and similar composite
functions) call `reset_git_circuit_breaker()` before their burst.

**Pro**: Surgical. Each call site opts in. Doesn't weaken the safety
net for genuinely unexpected git spawns.

**Con**: Every new composite function needs a reset. Easy to forget.
Tests need resets too (7 resets in `test_c2c_peer_pass.ml` alone).
The reset-before-call pattern is boilerplate that obscures intent.

**Assessment**: Works but doesn't scale. We're already at 9 reset
calls across 3 files after just 2 slices.

### C. Per-operation scoped breaker

**Change**: Introduce `Git_helpers.with_git_burst n f` that
temporarily raises the threshold for the duration of `f`.

```ocaml
let with_git_burst max_spawns f =
  let saved = git_counter.events in
  let saved_tripped = git_counter.tripped in
  git_counter.events <- [];
  git_counter.tripped <- false;
  Fun.protect ~finally:(fun () ->
    git_counter.events <- saved;
    git_counter.tripped <- saved_tripped) f
```

**Pro**: Composable. Callers declare "I need N git spawns" and the
breaker is scoped. No global threshold change.

**Con**: More complex API. Callers need to know their spawn count.
Nesting is tricky (inner scope restores outer state, potentially
re-tripping).

**Assessment**: Over-engineered for current needs. Revisit if the
codebase grows significantly more composite git operations.

### D. Raise threshold + keep reset in reviewer_is_author

**Change**: Bump default from 5 → 15, AND keep the reset inside
`reviewer_is_author` (since it's the most-composed function).

**Pro**: Belt-and-suspenders. Higher threshold prevents most trips;
the reset handles the worst-case (list iterating many artifacts).

**Con**: Two mechanisms for one problem.

**Assessment**: Pragmatic. My recommendation.

## Recommendation

**Option D: raise to 15 + keep reviewer_is_author reset.**

Rationale:
- 15 handles `c2c doctor`, multi-query subcommands, and test suites
  without resets
- The `reviewer_is_author` reset stays because `peer-pass list` with
  N > 3 artifacts would still trip at 15 (4N spawns)
- Runaway loops still get caught — 15 spawns in 3 seconds is still
  fast enough to detect `while true; do git ...; done` patterns
- Test resets can be simplified (remove per-call resets, keep only
  per-test resets)

## Non-recommendation

Don't remove the breaker entirely. It caught a real issue during
development (recursive `find_real_git` loop) and will catch future
ones. The question is threshold tuning, not existence.

## Follow-up work if adopted

1. Bump `git_spawn_max` default from 5 → 15
2. Remove unnecessary reset calls from `test_c2c_peer_pass.ml` (keep
   per-test resets, remove per-call resets since 15 > 7)
3. Keep `reviewer_is_author` internal reset (belt-and-suspenders for
   `peer-pass list` with many artifacts)
4. Update env-var docs in `.collab/runbooks/c2c-env-vars.md`
5. Update finding: `.collab/findings/2026-05-02T04-27-00Z-stanza-coder-circuit-breaker-trips-peer-pass-sign.md`
