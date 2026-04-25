# per-agent-worktrees commits lost — 2026-04-25T10:28:00Z

**Severity**: Medium — feature branch work, not blocking prod

## What happened
After hotfix push c4b7db9 (cmake + hacl-star), I ran `git reset --hard origin/master` to sync the per-agent-worktrees branch to the new master. This discarded 5 local commits that were ahead of origin/master:

```
bc629da fix(worktree): use open_process_in for git_command, fix porcelain parsing
b5818cf feat(cli): add c2c worktree list/prune subcommand + Tier2 classification
d2e06bd feat(start): auto-create worktree for managed sessions
e12c786 feat(cli): add c2c_worktree module — git worktree helpers
818e710 docs: add shared-tree incident findings + #165 plan for per-agent worktrees
```

## Root cause
`per-agent-worktrees` branch was created from 7b68fde (pre-stickers) and never rebased onto master before the stickers merge (#170) landed. When I ran `git reset --hard origin/master`, those 5 commits were orphaned — they existed only in this worktree.

## Attempted recovery
Tried to cherry-pick onto current master c4b7db9. Failed because:
- d2e06bd's `ocaml/cli/dune` drops `c2c_stickers` from modules (designed before stickers existed)
- c2c_worktree.ml changes conflict with current rooms/stickers integration in c2c.ml
- The commits are fundamentally incompatible with current codebase state

## Lessons learned
1. **Don't `reset --hard` without checking for unpushed commits first** — always `git log --oneline origin/master..HEAD`
2. **Keep feature branches rebased onto master** — especially before major merges like stickers
3. **Worktree isolation ≠ branch safety** — having work in a separate worktree doesn't protect it from `reset --hard`

## Recovery path
Re-implement per-agent-worktrees feature from scratch against current master. Not critical path — coordinator deprioritized.
