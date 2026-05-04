# Finding: pre-existing `reviewer_is_author` test failure at origin/master

**Date**: 2026-05-02T10:30-00Z
**Severity**: LOW
**Status**: Fixed at HEAD; pre-existing at origin/master

## What

Test `reviewer_is_author 1 "ignores unrelated co-author"` fails at origin/master (5e8c34d7).

Specifically, the assertion "co-author email local-part flagged" expects `true` (reviewer=`"unrelated"` matches local-part of `unrelated@c2c.im` from co-author trailer), but gets `false`.

## Root cause

The test runs in a temp repo where prior `git commit` calls (for setup) exhaust the git circuit breaker (default `git_spawn_max=5`). When `reviewer_is_author` calls `git_commit_co_author_emails`, the circuit breaker trips and returns an empty list — so the co-author email is not detected, local-part matching never happens.

## Fix at HEAD

Multiple commits between origin/master and HEAD fix the circuit breaker behavior:

- `7c670200` — reset circuit breaker **inside** `reviewer_is_author` before git spawns
- `48f439d7` — graceful degradation when circuit-breaker is open
- `a9c5f866` — reset circuit-breaker before validation
- `06145b8a` — raise `git_spawn_max` default 5→15

At HEAD: `reviewer_is_author` 3/3 tests pass.

## Verification

```bash
# At origin/master OCaml files:
git checkout origin/master -- ocaml/
opam exec -- dune exec ./ocaml/cli/test_c2c_peer_pass.exe
# FAIL: reviewer_is_author 1 ignores unrelated co-author
# co-author email local-part flagged: Expected true, Received false

# At HEAD (current):
opam exec -- dune exec ./ocaml/cli/test_c2c_peer_pass.exe
# All 3 peer_pass tests PASS
```

## Note

The 11 broker registration failures in `test_c2c_mcp.exe` are separate (unrelated to `reviewer_is_author`). Coordinator confirmed those are also pre-existing.
