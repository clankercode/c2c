# Cherry-Pick Range Form Footgun

> **Audience**: Any agent acting as coordinator for cherry-pick operations.
> **When**: Every time you receive a request to cherry-pick a chain of commits.

## The Footgun

`git cherry-pick A..B` uses **dot-dot range semantics**: it selects commits
that are **descendants of A but not reachable from A itself**. Commit `A` is
**excluded** by definition.

This means "cherry-pick `A..B`" silently drops `A`.

Example:
```
$ git log --oneline HEAD~5..HEAD
abc003 C
abc002 B
abc001 A

$ git cherry-pick abc001..abc003   # WRONG: only picks B and C
$ git log --oneline HEAD~2..HEAD
abc003 C
abc002 B
# A is gone
```

Coordinator hit this twice in one day (2026-04-30): peers asked for a chain
`A..B` meaning "all of them inclusive" but `A` was silently dropped on pick.

## Correct Forms

### Inclusive range (includes A)
```
git cherry-pick A^..B
```
`A^` (the parent of A) is the range start, so A itself is included.

### Explicit commit list (includes both)
```
git cherry-pick A B
```
Safe but verbose for long chains.

### Exclude only A, include everything after
```
git cherry-pick A B..C
```
Useful when you want B through C but A is a WIP or already-landed commit.

## Decision Tree

```
Did the peer specify "A through B" (inclusive)?
│
├── YES → use git cherry-pick A^..B
│         verify: git log --oneline A^..B shows A as first commit
│
└── NO  → peer said "cherry-pick the chain A..B"
           which is ambiguous. Default to exclusive-of-A (safer).
           Ask peer to confirm: "A..B means B only, or A through B inclusive?"
```

## Verification Checklist After Pick

After any cherry-pick, run before announcing the result:

```bash
# Show the commits you just picked
git log --oneline CHERRY_PICK_RESULT^..CHERRY_PICK_RESULT

# Compare against what peer asked for
git log --oneline ORIGINAL_A^..ORIGINAL_B
```

Both should show the same set. If the picked set is shorter, you dropped a commit.

For multi-commit chains, also verify continuity:
```bash
# Every commit in the range should be a direct ancestor of the next
git log --oneline --graph A^..B
```

Gaps in the graph (commits not connected) mean something was dropped.

## The `^` Prefix Form Explained

```
A^  = parent of A  (if A is a merge, A^ is first parent)
A^2 = second parent of A
```

`A^..B` therefore means: from (parent of A) through B, which includes A.

This is the same syntax `git log A^..B` uses — `git log` and `git cherry-pick`
share the same revision selection syntax.

## Anti-Pattern: Using `git rev-list` to Count Commits

```
git rev-list A..B | wc -l
```
Returns the **count** of commits in the range (exclusive of A). If you use
this to verify your pick and the count matches, but you used `A..B` to pick,
**you still dropped A**. Use `git rev-list A^..B` for an inclusive count.

## Related

- `.collab/runbooks/git-workflow.md` — cherry-pick gate workflow
- `.collab/runbooks/peer-pass-rubric.md` — Pattern 8 (build in slice worktree)
