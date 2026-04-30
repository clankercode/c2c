# finding(HIGH): git-pre-reset `is_worktree_branch()` broken — ALL worktree commits refused

**Found**: 2026-05-01T17:xx UTC
**By**: cedar-coder
**Status**: open — fix needed

## Summary

`is_worktree_branch()` in the installed `git-pre-reset` (from #481) uses
`GIT_WORK_TREE` to detect worktrees, but `GIT_WORK_TREE` is NOT set by git
automatically when running inside a worktree. This causes ALL `git commit`
operations in worktrees to be refused for non-coordinators, even though worktree
commits are the correct and intended workflow.

## Root Cause

In `#481` (`910b2eae`), `is_worktree_branch()` was changed from a branch-name
heuristic to `GIT_WORK_TREE` detection:

```bash
# git-pre-reset, current (broken):
is_worktree_branch() {
    # GIT_WORK_TREE is set by git when operating inside a worktree.
    # In the main repo it is always empty/unset.
    [ -n "${GIT_WORK_TREE:-}" ]
}
```

But `GIT_WORK_TREE` is NOT set by git just by being in a worktree directory.
Verified: inside `.worktrees/slice/`, `echo "$GIT_WORK_TREE"` → unset.

Combined with `is_main_tree()` using `git rev-parse --show-toplevel` (which
returns the **worktree root** in a worktree), this means:

```
is_main_tree() = true  (cwd = worktree root = MAIN_TREE)
is_worktree_branch() = false  (GIT_WORK_TREE is unset)
→ guard fires → commit refused
```

## The Fix

Detect worktrees by `.git` type instead:

```bash
# Correct: .git as FILE = worktree; .git as DIRECTORY = main repo
is_worktree() {
    [ -f ".git" ] && [ ! -d ".git" ]
}
```

`is_main_tree()` should use `[ -d ".git" ]` instead of comparing `cwd` with
`MAIN_TREE` (which is unreliable across worktrees).

## Test Impact

Test 13 (`test_git_shim.sh`) passes because it explicitly sets
`C2C_GIT_SHIM_MAIN_TREE` to the clone path, bypassing the real-world
`git rev-parse --show-toplevel` fallback that returns the worktree root.

## Affected Systems

Any agent using `git commit` from inside a `git worktree` directory. This
includes ALL non-coordinator worktree-based slice work. Coordinators with
`C2C_COORDINATOR=1` are unaffected (bypass works).

## Fix Status

Fix needs to be applied to `git-shim.sh` in the c2c repo, then `c2c install self`
re-installs the shim. Alternatively, `git-pre-reset` can be patched in-place
at `~/.local/state/c2c/bin/git-pre-reset`.
