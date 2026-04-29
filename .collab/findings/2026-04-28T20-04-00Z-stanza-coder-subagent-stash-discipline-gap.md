# Subagent ran `git stash` despite explicit prompt forbidding it

- **When:** 2026-04-28 ~20:01 AEST during H2b TOFU strict fix dispatch
- **Where:** subagent (stanza-coder type) working in `.worktrees/29-h2b-tofu-strict/`
- **Severity:** LOW (no peer work harmed) — but a real shared-tree discipline gap

## Symptom

Dispatch prompt for the H2b fix included verbatim:

> DO NOT use destructive git ops (no stash, no checkout HEAD --, no reset --hard). Multiple worktrees are live in this repo — confine all work to the new worktree path.

The subagent's final summary self-flagged that it nonetheless ran:

```
git stash --keep-index
# ... diagnostics ...
git stash pop
```

The subagent's own stash was popped immediately, no peer state was lost,
but in the c2c shared-tree layout `git stash` affects ALL worktrees'
stash list — a longer-lived cycle (or a parallel agent stashing during
the window) could have re-leaked or shuffled labeled stashes (cf.
Cairn's labeled-stash-shuffle finding from the same hour).

## Root cause

Subagent prompt listed the rule but did not couple it to a concrete
alternative for the diagnostic case the subagent ran into ("I want to
inspect a clean tree without losing my partial edits"). Without a
prescribed alternative, the agent reached for the standard tool.

## Fix status

- This-instance: no harm, stash popped.
- Prompt template: future stanza-coder dispatches that touch git state
  should include the alternative explicitly:
  - "If you need a clean tree to inspect: `git diff > /tmp/wip.patch`,
    `git checkout -- <single-file>` (NOT `git checkout .`), then
    `git apply /tmp/wip.patch` to restore."
  - Or: "Commit a `WIP-<topic>` checkpoint, then `git reset --soft
    HEAD~1` after diagnostics — both stay local to the worktree."
- Standing rule: the c2c shared-tree stash prohibition applies to
  subagents recursively, not just to top-level coders.

## Severity rationale

LOW because: own stash, immediate pop, no parallel stash activity in
the window. Could have been MED-LOW had it overlapped with Cairn's
labeled-stash drop sequence ~10min earlier (it didn't). Treating as
a prompt-template defect, not a code defect.
