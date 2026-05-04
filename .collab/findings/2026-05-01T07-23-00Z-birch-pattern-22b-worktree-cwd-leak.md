# Pattern 22b: worktree CWD state leaking into main tree working copy

**Filed**: 2026-05-01T07-23-00Z
**Severity**: medium — pollutes git status, causes cherry-pick failures without the audit gate
**Tags**: `worktree`, `git`, `pattern-14`, `shared-tree`, `cwd-leak`

## Symptom

`git status` in main tree shows modifications to files that belong to a worktree
(`M .collab/runbooks/git-workflow.md` appearing in main tree after editing from
within `.worktrees/runbook-pre-cherry-pick-audit/`). The modification belongs to
the worktree's view of the shared `.git` index, but bleeds into the main tree's
working copy.

## Observed frequency

Firing at multi-per-hour rate in this session:
- `c2b939cf` cherry-pick of S3a: 7 unexpected files in main tree
- `86b4149e` cherry-pick of runbook fix: `.collab/runbooks/git-workflow.md` M in main tree

Both caught by the pre-cherry-pick audit gate just landed.

## Root cause (working theory)

Shared-tree layout: all worktrees share the same `.git` directory. When an
agent's shell session has cwd inside a worktree path (e.g.
`.worktrees/runbook-pre-cherry-pick-audit/`), and runs a `git` command that
writes to the index (e.g. `git add`), the shared index absorbs the write.
Another agent's main tree sees those changes as modifications.

The **structural fix** would be one of:
1. **Separate index per worktree**: `GIT_INDEX_FILE` per worktree (but this
   requires each worktree to set the env var in all git invocations)
2. **Refuse edits to main tree from within a worktree path**: a pre-commit /
   pre-cherry-pick hook in the main tree that detects if cwd is inside a
   `.worktree/` path and refuses the operation
3. **Checkout worktrees with `--no-index`**: not applicable to `git add`

The simplest operational mitigation is the audit gate (already landed).

## Structural fix options (for future)

Option B (pre-commit hook refusing edits from worktree paths) seems most robust:
```
#!/bin/bash
# In main tree's .git/hooks/pre-commit
cwd="$(pwd)"
if echo "$cwd" | grep -q '\.worktrees/'; then
  echo "Refusing commit from worktree path: $cwd"
  exit 1
fi
```

But this needs coordination testing across all agents' hooks.

## Relationship to Pattern 14

Pattern 14 covers subagent `git add` from the wrong directory. This pattern
(22b) is the same root cause but manifests in the agent's own session when
editing from a worktree cwd — not just subagent delegation. Both share the
"shared-tree + worktree cwd" root cause.

## Status

Known. Audit gate landed as mitigation. Structural fix TBD.

## See also

- Pattern 14: subagent `git add` from wrong directory
- Pattern 22: rebase --ours/--theirs name inversion
- `.collab/runbooks/git-workflow.md` § Pre-cherry-pick audit gate