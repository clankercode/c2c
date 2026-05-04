# Finding: `git add` ran against main tree index instead of worktree index

## Date
2026-05-01

## Symptom
After committing in `.worktrees/482-s1-justfile-learnings/`, coordinator1 reported that `.collab/ocaml-learnings.md`, `justfile`, and `CLAUDE.md` were staged in the **main tree's index** — requiring `git reset --hard` before cherry-picking.

## Root Cause
I was in the **main tree's working directory** when staging and committing:
```bash
cd /home/xertrov/src/c2c  # ← main tree working directory
git add justfile .collab/ocaml-learnings.md
git commit -m "fix: install OCaml c2c-deliver-inbox..."
```
The `git add` affected the main tree's `.git`, not the worktree's.

## Pattern 14 Relevance
Pattern 14 is about subagents `cd`ing out of their assigned worktree for git ops. I did the equivalent — I was the main-session agent (not a subagent) but I was in the main tree context for git operations when I should have been in the worktree.

## Fix
Always use explicit path when operating on worktree files:
```bash
# DO (explicit worktree path):
git -C .worktrees/482-s1-justfile-learnings add justfile .collab/ocaml-learnings.md
git -C .worktrees/482-s1-justfile-learnings commit -m "..."

# OR (cd into worktree before git ops):
cd /home/xertrov/src/c2c/.worktrees/482-s1-justfile-learnings && git add justfile ...
```
Never rely on cwd when switching between main tree and worktree contexts.

## Status
Fixed in practice. Coordinator did `git reset --hard` to recover — no data loss.

## Severity
Medium — caused coordinator extra step; recurring pattern (cedar hit same issue this morning per coordinator1's note).
