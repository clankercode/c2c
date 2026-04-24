# fed88c7 stale commit message — findings

**Date**: 2026-04-24T20:30:00Z
**Severity**: minor (non-blocking)
**Status**: observed, not fixed

## Finding

Commit `fed88c7` ("fix(start): resolve role-brief duplication for non-claude primary agents") has a commit message that does not match its actual diff.

## Actual diff content

`fed88c7` introduces `finalize_outer_loop_exit` in `c2c_start.ml` and `c2c_start.mli`. This function ensures that `cleanup_and_exit` runs and returns before `print_resume` is called, so the process cleanup happens before the resume hint is printed.

The test `test_finalize_outer_loop_exit_cleans_before_print` verifies that cleanup events fire before print events.

## What the message says

The commit message describes "resolve role-brief duplication for non-claude primary agents" — which refers to a different fix (kickoff positional-arg handling for claude vs opencode/codex). The message is stale — it was never updated after the patch was rewritten.

## Why the code is correct

The `finalize_outer_loop_exit` pattern is legitimate: without it, `print_endline` runs before `cleanup_and_exit` which could lead to cleanup not executing before the process exits (depending on how `cleanup_and_exit` and `exit_code` interact). The extracted helper makes the ordering explicit and testable.

## Action needed

test-agent should amend the commit message to describe the actual change: "finalize_outer_loop_exit ensures cleanup runs before printing resume hint" (or similar).

## Relationship to 4f17a1d

`4f17a1d` was a separate, unreachable commit created by test-agent that contained `mi_tmux_location` additions + kickoff tests. That commit was FAIL'd in review. `fed88c7` is the correct local commit that was in the push queue.

## References

- `git show fed88c7` — actual diff
- `c2c doctor` output — shows fed88c7 in push queue