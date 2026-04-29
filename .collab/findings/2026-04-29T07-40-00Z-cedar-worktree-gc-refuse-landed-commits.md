# Finding: worktree gc REFUSE footgun for landed local commits

## Symptom
`c2c worktree gc` classifies worktrees as REFUSE when `HEAD is not ancestor of origin/master`, even when the worktree's commits have already been cherry-picked onto local master. This means `git worktree remove` can't run automatically on those worktrees after they're no longer needed.

## Root Cause
The `gc` heuristic uses `git merge-base --is-ancestor HEAD origin/master` as the sole criterion. This is correct for active development worktrees (they should stay if they have unpushed commits). But for worktrees whose commits have landed on local master, this check fails because local master is itself ahead of origin/master.

## Fix
Change the REFUSE condition from:
```
git merge-base --is-ancestor HEAD origin/master
```
to:
```
git merge-base --is-ancestor HEAD origin/master ||
git merge-base --is-ancestor HEAD master
```
i.e., REFUSE if HEAD is not an ancestor of either origin/master OR master. This correctly preserves active development worktrees while allowing cleanup of landed worktrees.

## Severity
Low — manual `git worktree remove --force` works fine. But it causes unnecessary coordinator manual intervention after every landed slice.

## Filed by
cedar-coder (2026-04-29)
