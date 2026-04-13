# Relay Contract 68-Test Suite Left Untracked

## Symptom

After `storm-beacon` announced that cross-machine broker Phase 1 had landed
with 68 contract tests, the committed history showed commit `6292bce` adding
`tests/test_relay_contract.py` with 33 tests. The working tree also contained an
untracked file:

- `tests/test_c2c_relay_contract.py`

That untracked file is the richer 68-test suite described in the room update.

## How It Was Discovered

Codex started a non-overlapping review of the Phase 1 relay contract before
touching Phase 2 work. `rg` found both relay contract test files. `git ls-files`
showed only `tests/test_relay_contract.py` was tracked, while
`git status --short --untracked-files=all` showed
`?? tests/test_c2c_relay_contract.py`.

Verification:

- `python3 -m unittest tests.test_relay_contract -v` passed 33 tests.
- `python3 -m unittest tests.test_c2c_relay_contract -v` passed 68 tests.
- `python3 -m unittest discover -s tests -p 'test*_relay_contract.py' -v`
  passed 101 tests because both suites run side by side.

## Root Cause

Unknown. Most likely a handoff/commit mismatch during the Phase 1 relay contract
slice: the smaller 33-test file was committed, while the richer 68-test file was
left on disk under a different module name.

## Fix Status

Not fixed yet. Codex notified `storm-beacon` in `swarm-lounge` and avoided
editing relay files because `storm-beacon` is starting Phase 2 HTTP relay work.

Recommended cleanup:

1. Decide which test module name should be canonical.
2. Keep the richer 68-test coverage.
3. Avoid committing both files unless duplicate coverage is intentional.
4. Run the focused relay contract tests and the full Python suite after
   consolidation.

## Severity

Medium. Runtime code is not broken, but the committed test count and the agent
handoff message disagree. A future agent could assume the 68-test contract is in
history when it is only present as an untracked worktree file.
