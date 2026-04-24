# Shared-worktree phantom dependency: build passes against peer's uncommitted changes

**Reporter**: coordinator1
**Date**: 2026-04-24T18:50 UTC
**Severity**: medium — silently creates broken commits; hard to detect

## Symptom

jungle-coder's commit bf12cf4 calls `C2c_start.repo_config_git_attribution()`
which doesn't exist in the committed tree. The build passed at commit time only
because galaxy-coder's uncommitted `c2c git` subcommand work (which adds that
function) was present in the shared working tree.

galaxy-coder's peer review caught this: `bf12cf4 doesn't build at its own commit`.

## Root cause

Multiple agents share the same git working tree. When agent A runs a build
check, it compiles against ALL files in the working tree — including unstaged
changes from agent B. If agent A then commits without including agent B's
files, the commit appears to build but actually has a phantom dependency on
B's uncommitted work.

## Fix for this instance

galaxy-coder commits their `c2c git` subcommand work (including
`repo_config_git_attribution`) before jungle's commits are reviewed further.
Once that lands, HEAD builds correctly.

## Prevention

- **Build check must be against a clean working tree.** Before committing,
  agents should run: `git stash && just build && git stash pop` (or equivalent)
  to verify the commit stands alone without other agents' uncommitted changes.
- **CLAUDE.md should note this.** Add a rule: before committing OCaml changes,
  verify the build passes with `git stash` to isolate your diff from the tree.
- Long-term: worktree-per-agent (each agent works in an isolated `git worktree`)
  would eliminate this class of bug entirely. Already recommended for codex.
  Should be the default for all concurrent OCaml work.

## Related

- CLAUDE.md: "use isolated worktree" recommendation for codex slices
- `git worktree` support in the tooling
