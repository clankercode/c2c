# Pattern 22: rebase --ours/--theirs name-inversion when rebasing a slice

**Filed**: 2026-05-01T07-15-00Z
**Severity**: medium — silent data loss if not caught
**Tags**: `git`, `worktree`, `slice`, `rebase`, `footgun`

## Symptom

Rebase of a slice worktree onto updated `origin/master` completes with no error, but
all slice changes are gone. Working tree shows only `origin/master` content.
The conflict resolution step appeared to use `--ours` (taking the "local" version)
but the slice changes were silently discarded.

## Root Cause

During `git rebase`, the branch being replayed is `theirs` and the branch being
rebased onto is `ours`. When rebasing `slice/482-s3a-kimi-delivery` onto
`origin/master`:

```
ours   = origin/master (the target)
theirs = slice/482-s3a-kimi-delivery (the slice being replayed)
```

The mental model that bites: "I'm working on my slice, so my changes are `ours`"
— but in rebase terms, `ours` is always the branch you are rebasing **onto**.

`git checkout --ours` during rebase conflict resolution takes `origin/master`
content, discarding all slice changes.

## What actually happened (S3a)

```
git rebase origin/master
  → conflict in ocaml/cli/c2c_deliver_inbox.ml
  → git checkout --ours ocaml/cli/dune ocaml/cli/c2c_deliver_inbox.ml
  → "ours" = origin/master version (NOT my slice edits)
  → slice changes overwritten
  → git rebase --continue
  → slice appears clean but all S3a edits gone
```

Recovery: `git reflog` showed orphaned S3a commit (`53e70eb4`). Cherry-picked
it onto clean `origin/master`, then resolved conflicts with `git checkout --theirs`
(to take the incoming slice version).

## Correct approach

When rebasing a slice onto master and conflicts occur:

```
# During rebase conflict resolution:
git checkout --theirs .   # takes your slice changes (theirs = your slice)
git add .

# Alternative: resolve manually then:
git checkout --ours path/to/conflicted.file  # WRONG — takes master, discards slice
git checkout --theirs path/to/conflicted.file  # RIGHT — keeps slice changes
```

Or use `git merge` with `-X ours`/`-X theirs` the same way, or resolve conflicts
manually by editing.

## Prevention

1. **Document the inversion** in the worktree discipline runbook next to
   Pattern 13/14 — add to `.collab/runbooks/worktree-discipline-for-subagents.md`
2. **Worktree freshness heuristic**: commit early in a new worktree (any commit
   moves HEAD off `origin/master` and exits the freshness heuristic)
3. **Check diff after rebase**: `git diff origin/master --stat` to verify slice
   changes are still present before `rebase --continue`
4. **Alias suggestion**: consider a `git-rebase-slice` helper that uses
   `--theirs` automatically for known-slice branches

## Related Patterns

- Pattern 13: `git stash` is destructive in shared-tree layout
- Pattern 14: subagent `git add` from wrong directory
- Pattern 15: worktree freshness heuristic (commit early in new worktree)
- This pattern is adjacent to both: like Pattern 14 it involves git state from
  the wrong perspective; like Pattern 15 it applies specifically to fresh slices

## Status

Known. Recovery path documented. Finding filed for runbook update.