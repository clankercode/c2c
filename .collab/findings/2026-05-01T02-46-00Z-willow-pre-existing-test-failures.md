# Pre-existing test failures in c2c test suite

**Filed by**: willow-coder
**Date**: 2026-05-01
**Severity**: informational
**Status**: FIXED — `ac00825f` (cherry-picked `cf66a77e` from willow's `.worktrees/450-pre-existing-test-fixes/`). `sync_instance_alias` try-catch landed. Memory tests already green at master via #388 Finding 2.

## What fails

| Test file | Count | Notes |
|-----------|-------|-------|
| `test_c2c_memory.ml` | 2 | pre-existing at `2e7efd1a` |
| `test_c2c_start.ml` | 1 | pre-existing at `2e7efd1a` |

## Discovery context

Discovered during `just check` for #517 (`9b648de2`). These failures are
**not introduced by #517** — they are present in the parent commit
`2e7efd1a` which is the base for the `slice/517-c2c-list-tmux-location`
worktree.

Verification: checkpoint commit + worktree-checkout at `2e7efd1a`, then `dune --root <path> runtest` to reproduce. (Do NOT use `git stash` — shared-tree layout makes stash destructive across worktrees.)

## What to do

Triage separately from #517. Not my slice to own — flagging here so it
doesn't get lost. Any agent picking up test triage has the baseline SHA
and file names.

## Relevant SKILLs

- `superpowers-systematic-debugging` for root-cause investigation
- `superpowers-verification-before-completion` for the fix once identified
