# Pre-Commit Shim Gap — Pattern Candidate

**Author**: galaxy-coder
**Date**: 2026-04-29
**Status**: Research only

## Problem

The existing `git reset --hard`-refusing shim (Pattern 15, #452) covers destructive main-tree operations but does **not** cover `git commit`. Non-coordinator agents can commit directly to `main` or `master` on the main tree, bypassing the worktree-per-slice discipline.

## Symptom Incidents (2026-04-29)

| Who | SHA | What | Route |
|---|---|---|---|
| cedar | `edf9ec80` | Handoff hygiene XS fix (main tree) | Retroactive willow PASS |
| galaxy-coder | `d507d8c3` | `volumes/` exclusion in `.dockerignore` | Retroactive willow PASS |
| fern | (near-miss) | Similar direct-to-main-tree XS | Caught by self before commit |

Three incidents in a single session. The pattern is established.

## Why This Matters

- The pre-push hook already gates `git push` to `origin/master` behind `C2C_COORDINATOR=1`
- The pre-reset shim gates destructive `git reset --hard` and `git checkout -- .`
- But `git commit` to main tree is unguarded → commits land on main without peer review or coordinator awareness
- In a shared-tree layout, these orphaned commits pollute `git log origin/master..HEAD` for every other agent

## Proposed Fix: Pre-Commit Warn Hook

Install a `.git/hooks/pre-commit` hook (or enhance the existing wrapper) that:

1. **Checks current branch**: if on `main` or `master` (not a worktree branch)
2. **Checks `C2C_COORDINATOR=1`**: if set, allow (escape hatch for coord housekeeping)
3. **Otherwise**: print a warning and require user confirmation before proceeding:
   ```
   ⚠️  WARNING: committing directly to main/master.
   You are not coordinator (C2C_COORDINATOR=1 not set).
   This bypasses peer review and pollutes the shared main tree.
   Set C2C_COORDINATOR=1 to bypass this warning.
   Continue? [y/N]
   ```
4. **Warn, not refuse**: refusing blocks coordinator housekeeping commits; warn + confirm preserves operator agency while surfacing the action

## Implementation Options

### Option A: Shell Wrapper (git-shim package)
Enhance the existing `git` shim to intercept `commit` the same way it intercepts `reset --hard`. Add a `git_commit_allowed()` function checking branch name + `C2C_COORDINATOR` env.

### Option B: Husky-style Git Hook + Package Installer
Add a `prepare-commit-msg` or `pre-commit` hook via a package (e.g., `husky`-equivalent for bash). The `c2c install` command would set up the hook.

### Option C: Documentation Only (Accept the Risk)
The three incidents this session were all legitimate XS fixes. Accept that coordinators and trusted agents occasionally need direct main-tree commits; document the convention and rely on trust.

## Recommendation

**Option A** — the existing shim already exists and handles `reset --hard`. Adding `commit` to its scope is low effort, consistent with existing architecture, and preserves the `C2C_COORDINATOR=1` escape hatch.

## Open Questions

- Does the existing `git` shim (the one that refuses `reset --hard`) already handle `commit`? Need to audit the actual shim script.
- Should `git merge` also be guarded? (merge main into a worktree branch is safe; merge worktree into main is not)
- Should the hook warn for any branch that isn't a worktree branch (`worktrees/*`)?
