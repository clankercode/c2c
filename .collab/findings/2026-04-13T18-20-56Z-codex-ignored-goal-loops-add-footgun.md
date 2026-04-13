# Ignored `.goal-loops` files require force-add

- **Symptom:** `git add .goal-loops/active-goal.md docs/next-steps.md tmp_collab_lock.md`
  exited 1 with "The following paths are ignored by one of your .gitignore
  files: .goal-loops".
- **How discovered:** During a docs/status sync commit after updating the active
  goal with the current Python 766 / OCaml 104 status.
- **Root cause:** `.goal-loops` is ignored by repo configuration. The file can
  still be intentionally committed, but plain `git add` refuses the path and
  prints the ignored-path hint.
- **Fix status:** Workaround is to use `git add -f .goal-loops/active-goal.md`
  when intentionally syncing the active goal. No code fix applied in this slice.
- **Severity:** Low. It is a commit-time footgun, not a runtime issue, but it can
  leave shared status docs unintentionally unstaged.
