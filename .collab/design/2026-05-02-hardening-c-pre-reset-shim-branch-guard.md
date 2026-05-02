# Design: Hardening C — pre-reset shim branch-ref mutation guard

**Slice**: `.collab/design/2026-05-02-hardening-c-pre-reset-shim-branch-guard.md`
**Author**: cedar-coder
**Date**: 2026-05-02
**Status**: Design draft — for review before implementation

## Background

Today's #611 regression cluster (two shim failures in one hour) exposed that
the pre-reset shim guards `git reset --hard` and `git commit`, but does NOT
guard `git switch`, `git checkout <branch>`, or `git rebase <upstream>`.
These are branch-ref mutations that, when run from the main tree (instead of
a slice worktree), can flip the main tree's HEAD off `master` and onto a
slice branch — corrupting the coordinator's working context.

Two agents hit this class today: fern (branch flip during revert) and cedar
(branch flip during rebase).

Reference: `.collab/findings/2026-05-02T01-45-00Z-coordinator1-shim-regression-cluster-and-main-tree-branch-flips.md`

## Goal

Extend the pre-reset shim to refuse branch-ref-mutating git operations in the
main tree for non-coordinator agents. Same `C2C_COORDINATOR=1` bypass shape
as existing `reset --hard` and `commit` guards.

## Commands in scope

### Must refuse (branch-ref mutations)

| Command | Form | Reason |
|---------|------|--------|
| `git switch <branch>` | `switch <branch>` | Switches HEAD to named branch |
| `git switch -c <branch>` | `switch -c <branch>` | Creates + switches to new branch |
| `git switch <branchA>..<branchB>` | `switch` with range | Detaches at merge-base (edge case) |
| `git checkout <branch>` | `checkout <branch>` (no `--` or files) | Switches to named branch |
| `git checkout -b <branch>` | `checkout -b <branch>` | Creates + switches to new branch |
| `git rebase <upstream>` | `rebase <anything>` | Rewrites commits; always a branch ref mutation |
| `git rebase --onto <newbase> <upstream>` | `rebase --onto` | Rewrites commits |
| `git rebase -i <upstream>` | `rebase -i` | Interactive rebase |

### Must NOT refuse (file operations)

| Command | Form | Reason |
|---------|------|--------|
| `git checkout -- <file>` | `checkout -- <file>` | Discards changes to file; no branch effect |
| `git checkout origin/master -- <file>` | `checkout <rev> -- <file>` | Extracts file at revision; no branch effect |
| `git checkout <rev> -- <path>` | checkout with `--` separator | File at revision; no branch effect |
| `git switch -` | `switch -` | Returns to previous branch; same safety as `-` for checkout |

## Detection logic

### `git switch`

```bash
# Cases to refuse: switch <branch>, switch -c <branch>, switch -C <branch>
# Cases to allow:  switch -  (previous branch — safe, same as checkout -)
#                  switch --help, switch --version (flag-only invocations)

# Refuse if:
#   - first arg exists, is not "-", and does not start with "-"
#   - OR first arg is -c/-C (create branch)
#   - AND is_main_tree && COORDINATOR != "1"
```

### `git checkout`

```bash
# The complex case — checkout is both a branch-switching and a file operation.
#
# Key insight: checkout mutates the branch ONLY when:
#   (a) first positional arg exists, is not a flag, and does not start with "-"
#   AND
#   (b) there is NO "--" separator in the arguments
#   AND
#   (c) the first positional arg is NOT a valid file path that exists in the index
#
# File-grab form: checkout [--] [<tree-ish>] -- <pathspec>...
# The "--" separator is the definitive signal: everything after it is file paths.
#
# Algorithm:
#   1. If "--" is present anywhere in args → ALLOW (file operation)
#   2. If no positional args (just flags) → ALLOW (git checkout --ours/--theirs etc.)
#   3. If first positional arg is "-" → ALLOW (return to previous branch)
#   4. If first positional arg starts with "-" → ALLOW (flag, not a branch)
#   5. Otherwise: refuse (treat as branch-switching checkout)
```

**Simplicity note**: The above algorithm refuses `git checkout HEAD~1` (detaches HEAD), which is arguably a branch-ref mutation too. The question is whether "detaching HEAD" is in-scope for this guard. The current design says YES — detaching is a branch-ref effect even if it doesn't name a specific branch. An agent that needs to peek at an older commit can use `git switch` with a temp branch or `git show <rev>` directly.

**Counter-argument**: Some workflows legitimately `git checkout HEAD~1` to inspect old state without switching away from the current branch. The commit guard already prevents `git commit` on main; detaching to inspect is arguably a read-only intent. But detaching is still a branch-ref mutation (HEAD is no longer on a named branch).

**Resolution**: Refuse `git checkout HEAD~1` and similar detached-HEAD forms when in main tree, unless `C2C_COORDINATOR=1`. Agents can use `git show HEAD~1` for inspection without any checkout.

### `git rebase`

```bash
# All forms of rebase are branch-ref mutations — refuse all of them.
# git rebase [-i] [--onto <newbase>] [<upstream> [<branch>]]
#
# Algorithm:
#   1. If first arg is "rebase" and any non-flag args exist → REFUSE
#   2. Allow: rebase --continue, rebase --abort, rebase --skip (state management)
#      These don't mutate the branch ref, they manage an in-progress rebase.
```

**Edge case**: `git rebase --abort` and `--continue` are state management, not new branch mutations. These should be allowed — they don't create new branch refs.

### Summary table

| Command + args | Guard fires? | Rationale |
|---|---|---|
| `git switch foo` | REFUSE | Branch switch |
| `git switch -c foo` | REFUSE | Create + switch |
| `git switch -` | ALLOW | Return to previous branch |
| `git checkout foo` | REFUSE | Branch switch |
| `git checkout -b foo` | REFUSE | Create + switch |
| `git checkout -` | ALLOW | Return to previous branch |
| `git checkout -- file` | ALLOW | File discard |
| `git checkout rev -- file` | ALLOW | File at revision |
| `git checkout HEAD~1` | REFUSE | Detaches HEAD |
| `git rebase upstream` | REFUSE | Branch rebase |
| `git rebase --onto A B` | REFUSE | Branch rebase |
| `git rebase -i upstream` | REFUSE | Interactive rebase |
| `git rebase --continue` | ALLOW | State management |
| `git rebase --abort` | ALLOW | State management |

## Bypass

`C2C_COORDINATOR=1` — same as existing guards. Coordinators may need to
`git switch` or `git rebase` in the main tree during coordination tasks.

## Error messages

For each refused operation, emit a consistent fatal message:

```bash
echo "fatal: git-shim refused '$1' in main tree." >&2
echo "fatal: branch-ref-mutating operations are not allowed in the main tree." >&2
echo "fatal: use a worktree for this operation, or set C2C_COORDINATOR=1 to bypass." >&2
exit 128
```

## Implementation plan (for follow-up slice)

1. **Add `guard_branch_ref_mutation()` function** — receives the command name and args array, returns 0 (allow) or 1 (refuse) after all checks.
2. **Add `case "$1"` arms for `switch` and `rebase`** in the `main()` dispatch.
3. **Refine the `checkout` arm** — add the `--` detection and positional-arg analysis.
4. **Add `--continue` and `--abort` passthrough** for rebase state management.
5. **Add self-test coverage** — `git-shim.sh --self-test` should exercise the new guards.

## Open questions

1. **Refuse `git checkout HEAD~1`?** Current design says YES. But this is a relatively common "peek at old state" pattern. Alternative: only refuse when the arg looks like a branch name (alphanumeric string matching `^[a-zA-Z][-a-zA-Z0-9_]*$`). File paths contain `/` and `.`, branch names typically don't. This is a cleaner heuristic. **Recommendation**: refuse only when the arg looks like a branch name, allow hex SHAs and `HEAD~N` forms.

2. **`git restore`?** Available in git 2.23+. `git restore --source=<rev> <path>` is a file-only operation (no branch effect). `git restore -b <branch>` does NOT exist — `-b` is not valid for `git restore`. So `git restore` is always safe and needs no guard.

3. **`git stash`** — not a branch ref mutation. `git stash` creates a stash ref under `refs/stash/` but does not mutate the current branch. `git stash pop` applies and drops the stash. Neither changes HEAD. No guard needed.

4. **`git reset` (without --hard)** — the existing guard only covers `--hard`. `--soft` and `--mixed` move HEAD but don't lose working tree changes. `--soft` is safe (just moves HEAD). `--mixed` resets the index but not the working tree — could cause confusion but doesn't lose data. The current guard only fires on `--hard`. Keep that pattern.

## Testing plan (for follow-up slice)

```
# Should refuse
git switch feature-branch        # refused
git checkout main               # refused
git checkout -b new-branch      # refused
git rebase origin/master        # refused
git checkout HEAD~1             # refused (detaches HEAD)

# Should allow
git switch -                    # allowed
git checkout -                  # allowed
git checkout -- file.txt        # allowed
git checkout origin/master -- file.txt  # allowed
git rebase --continue          # allowed
git rebase --abort             # allowed
git restore --source=HEAD~1 file.txt  # allowed
```

## Relationship to existing guards

This guard complements (does not replace) the existing:
- `git reset --hard` guard (checks commit-loss risk)
- `git commit` guard (checks branch restrictions)

All three share the same `is_main_tree && COORDINATOR != "1"` precondition.
