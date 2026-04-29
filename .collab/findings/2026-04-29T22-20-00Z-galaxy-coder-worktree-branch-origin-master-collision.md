# Finding: worktree branch named `origin/master` shadows remote-tracking ref

**Date:** 2026-04-29T22:20:00Z
**Agent:** galaxy-coder
**Severity:** MEDIUM — subtle footgun

## Symptom
When creating a worktree via `git worktree add .worktrees/<name> origin/master`, the new worktree's HEAD is detached at `origin/master`. Running `git checkout -b <name>` from that state creates a branch literally named `origin/master` (or whatever the remote-tracking ref was named). This branch name collides with the `refs/remotes/origin/master` namespace — `git fetch origin master` becomes ambiguous, and `git push origin <branch>` will refuse because the local ref `refs/heads/origin/master` shadows the remote-tracking ref `refs/remotes/origin/master`.

## Root Cause
`git worktree add <path> <branch>` checks out `<branch>` (creating a detached HEAD if it's a remote-tracking ref). Then `git checkout -b <name>` creates a new local branch — but if `<name>` is accidentally the name of a remote-tracking ref (e.g. `origin/master`), the new local branch shadows it.

The collision happens because git allows local branch names to collide with remote-tracking ref names. The namespace collision causes:
- `git fetch` becomes ambiguous (which `origin/master` do you mean?)
- `git push origin <branch>` refuses: "refusing to push to ref name '{branch}' outside of refs/heads/"
- `git branch -a` listings become confusing
- Scripts that assume `origin/*` = remote-tracking refs may break

## Mitigation
Always create worktrees with a named branch explicitly:
```bash
# Wrong — creates detached HEAD at origin/master, tempting you to then:
#   git checkout -b origin/master  ← BAD
git worktree add .worktrees/<name> origin/master

# Right
git fetch origin master
git worktree add .worktrees/<name> origin/master
git checkout -b slice/<feature-name>  # Use a branch name that doesn't collide
```

Or use `git worktree add -b <branch> <path> <ref>` directly:
```bash
git worktree add -b slice/<feature-name> .worktrees/<name> origin/master
```

## Status
Fixed: branch renamed to `slice/406-e2e-docker-mesh`.

## Pattern-16 Candidate
This is a **destructive-git-op-adjacent footgun** that doesn't fit existing patterns:
- Pattern 1-15 cover git reset/checkout/stash/detached-HEAD mistakes
- This is about branch-naming collisions with remote-tracking refs
- Recommendation for `.collab/runbooks/worktree-discipline-for-subagents.md`: add a "branch name must not collide with refs/remotes/" warning to the worktree creation checklist

Coordinator1 offered to file the seed if not addressed by me.
