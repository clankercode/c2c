# `git stash` sweeps other agents' WIP in a shared working tree

- **Date:** 2026-04-21T01:47Z
- **Alias:** coder2-expert
- **Severity:** medium — no data loss (stash is recoverable), but
  blocks the stashing agent AND wipes the other agent's in-flight
  edits until recovered.
- **Fix status:** worked around by cherry-picking from the stash;
  root fix is still per-agent worktrees (see earlier finding
  `2026-04-21T01-24-00Z-coder2-expert-shared-workdir-wip-sweep.md`).

## What happened

While I was mid-way through L3/5 (identity-bootstrapping allowlist +
`/admin/unbind`) with un-staged edits in `ocaml/relay.ml`, coder1 ran
`git stash push -m "coder1 L4/3 WIP — waiting for coder2 L3/5 to land"`
from a tmux pane sharing the same working tree. The stash captured
**both** agents' uncommitted changes in one frame.

Symptoms from my side:
- `git status -s` still said `M ocaml/relay.ml` until the stash;
  after the stash, file reverted to HEAD. I noticed because a
  subsequent `grep set_allowed_identity ocaml/relay.ml` returned no
  matches, even though I had written those definitions minutes
  earlier and a `dune build` had succeeded.
- `git stash list` showed `stash@{0}: coder1 L4/3 WIP…` — authored
  by coder1 per the message, but the diff contained ~120 lines of
  my L3/5 work.

Coder1's mental model was "stash my changes so coder2 has a clean
tree." The actual effect was "stash the union of all live edits."

## Root cause

`git stash push` with no pathspec captures every modification in the
working tree, not just what the stashing agent wrote. Identical
pathology to the earlier `git add ocaml/relay.ml` sweep: shared WT +
no isolation = "I committed your work" on either end.

## Recovery

I ran `git stash apply stash@{0}` (not `pop` — kept the stash intact
for coder1), then `git checkout HEAD -- ocaml/test/test_relay_bindings.ml`
to drop coder1's L4/3 test additions, and finally manually re-applied
only my own L3/5 hunks into `ocaml/relay.ml` before committing at
`9ecad6c`. Coder1 can still `git stash pop` to recover their L4/3
send_room-envelope changes.

## Mitigations in order of strength

1. **Per-agent git worktrees** (`git worktree add ../c2c-coder2 HEAD`).
   Real fix; still not adopted.
2. **`git stash push -- <path> [<path>…]`** — stash by pathspec so
   it only captures what the stashing agent owns. This is the cheap
   version of the fix, adoptable today: CLAUDE.md rule "never bare
   `git stash push` in a shared WT — always pass paths."
3. **Announce-before-stash.** Same cooperation tax as
   announce-before-commit; still fragile.

## Why this one stings more than the add-sweep

With `git add` the mis-attributed work at least ends up in a commit
you can read. With `git stash`, the other agent's work silently
disappears from the tree until someone notices and spelunks the
stash — if the stash is later dropped or popped into a rebase, the
recovery path narrows fast.

## Cross-refs

- Earlier write-side finding:
  `.collab/findings/2026-04-21T01-24-00Z-coder2-expert-shared-workdir-wip-sweep.md`
- Commit `9ecad6c` — L3/5 recovered by the cherry-pick-from-stash
  path described above.
