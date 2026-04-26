# #313 — `c2c worktree gc` design

stanza-coder, 2026-04-26 10:26 UTC. Design pass for the worktree
GC tool. Real disk pressure: `.worktrees/` accumulates ~25 GB
across the swarm; old slice branches that landed on origin/master
weeks ago still keep their full checkouts on disk.

## Goal

Identify worktrees safe to remove and remove them on `--clean`.
Refuse anything not provably safe. Surface the analysis so an
operator can audit before deleting.

This is **detection + safe-delete**, not "auto-clean everything
that looks old." Safety boundaries are the load-bearing piece.

## CLI surface

```
c2c worktree gc [--clean] [--json] [--ignore-active]
```

| Flag | Default | Effect |
|---|---|---|
| `--clean` | off | Actually remove worktrees that pass safety checks. Without this, output is dry-run. |
| `--json` | off | Machine-readable output. |
| `--ignore-active` | off | Override the "process has cwd inside" refuse. Use only when you know the cwd-holding process is dead. |

Anchored under existing `c2c worktree` group (`C2c_worktree`).
Sibling to existing `c2c worktree prune` (which is just a `git
worktree prune` wrapper for stale admin entries).

## Safety boundaries (refuse-paths)

For each worktree under `.worktrees/`, check four conditions. If
any fails, refuse to delete and explain why.

### 1. REFUSE on dirty working tree

`git -C <worktree> status --porcelain` non-empty → REFUSE. Means
uncommitted changes exist (peer-unstaged work, half-edited file,
unsaved test scaffold). Removing a dirty worktree IS the
shared-tree-destructive class the protocol forbids.

### 2. REFUSE on branch not fully merged into origin/master

For the worktree's HEAD:

- If HEAD is on a named branch B: require `git merge-base
  --is-ancestor B origin/master`. If false → REFUSE (branch has
  commits not yet on origin).
- If HEAD is detached: require `git merge-base --is-ancestor
  HEAD origin/master`. Detached + reachable from origin/master
  is fine to delete.

The "fully merged into origin/master" boundary is the right
choice — local master may have cherry-picks not yet pushed, but
those land on origin/master eventually; a worktree branch that's
already on origin is provably reproducible from there.

### 3. REFUSE on active process holding cwd inside

Scan `/proc/*/cwd` (Linux) or fall back to `lsof +D <worktree>`.
If any live process has cwd inside the worktree, REFUSE. Means a
shell/agent is actively working there.

`--ignore-active` overrides this for cases where the cwd-holding
process is dead (PID reaped, /proc entry stale).

### 4. REFUSE on the main worktree itself

Never offer to delete the repo's main worktree. Skip during
scanning.

## Candidate-pass conditions

A worktree IS safe to delete when ALL of:
- Clean working tree
- HEAD branch (or detached SHA) is ancestor of origin/master
- No live process holds cwd inside
- Not the main worktree

Plus implicit: the worktree is at a path under `.worktrees/`
(don't touch ad-hoc external worktrees).

## Output shape

### Human-readable (default)

```
Worktree GC scan (38 worktrees, 25.3 GB total)

REMOVABLE (12 worktrees, ~7.4 GB):
  .worktrees/302-binary-race            slice/302-binary-race  ancestor of origin/master, clean
  .worktrees/303-channel-push           slice/303-channel-push  ancestor of origin/master, clean
  ...

REFUSE (24 worktrees):
  .worktrees/galaxy-coder               slice/177-codex-headless-fifo-deadlock  REFUSE: dirty (3 modified files)
  .worktrees/feat-mobile-s5b            feat/mobile-s5b-device-login-web-ui     REFUSE: 4 commits ahead of origin/master
  .worktrees/stanza-coder               slice/107-envelope-emit                 REFUSE: live process pid=1169738 cwd inside

Run with --clean to remove the REMOVABLE set. (Dry-run by default.)
```

### --clean output

```
Removing 12 worktrees, freeing ~7.4 GB...
  removed .worktrees/302-binary-race
  removed .worktrees/303-channel-push
  ...
Done. 7.4 GB freed.
```

### --json

```json
{
  "scan": {
    "total_worktrees": 38,
    "total_bytes": 25300000000
  },
  "removable": [
    { "path": "...", "branch": "...", "size_bytes": 600000000,
      "reason": "ancestor of origin/master, clean" }
  ],
  "refused": [
    { "path": "...", "branch": "...",
      "refuse_reason": "dirty" }
  ]
}
```

## Implementation sketch

OCaml under `ocaml/cli/c2c_worktree.ml` (existing module). New
function `gc_cmd` registered into the worktree group.

Per-worktree scan helpers:
- `is_dirty path` — `git -C path status --porcelain` non-empty
- `branch_ancestor_of_origin_master path` — git merge-base check
- `cwd_holders path` — scan /proc/*/cwd for paths under
  worktree, return list of (pid, cmdline)
- `worktree_size_bytes path` — `du -sb` or
  walk-and-sum-st_size; cache or stream-skip lazy

Listing all worktrees: parse `git worktree list --porcelain`.
Filter to paths under `.worktrees/`.

## Manual test plan (5 states, exercising boundaries)

Per coordinator's request, manually exercise each safety boundary
before peer-PASS. Each state uses a throwaway test worktree.

### State A — Clean & merged → REMOVABLE
1. `git worktree add /tmp/gc-test-A origin/master`
2. `cd /tmp/gc-test-A && touch x && git add x && git commit -m x`
3. Cherry-pick that commit onto local master OR push and refetch
4. `c2c worktree gc` shows /tmp/gc-test-A under REMOVABLE
5. `c2c worktree gc --clean` removes it

### State B — Dirty → REFUSE
1. `git worktree add /tmp/gc-test-B origin/master`
2. `echo dirty > /tmp/gc-test-B/x.txt`
3. `c2c worktree gc` shows REFUSE: dirty
4. `c2c worktree gc --clean` does NOT remove it

### State C — Active process holding cwd → REFUSE
1. `git worktree add /tmp/gc-test-C origin/master`
2. Open a shell with cwd inside /tmp/gc-test-C in another tmux pane
3. `c2c worktree gc` shows REFUSE: live process pid=N cwd inside
4. `c2c worktree gc --clean` does NOT remove it
5. Close the shell; re-run; now REMOVABLE
6. `--ignore-active` override works while shell is open (sanity)

### State D — Branch not merged → REFUSE
1. `git worktree add -b test/gc-D /tmp/gc-test-D origin/master`
2. `cd /tmp/gc-test-D && touch unmerged && git add unmerged && git commit -m unmerged`
3. `c2c worktree gc` shows REFUSE: ahead of origin/master
4. `c2c worktree gc --clean` does NOT remove it

### State E — Detached HEAD reachable from origin/master → REMOVABLE
1. `git worktree add --detach /tmp/gc-test-E origin/master`
2. (No commits, HEAD = origin/master SHA, reachable)
3. `c2c worktree gc` shows REMOVABLE
4. `c2c worktree gc --clean` removes it

After all five: rerun `c2c worktree gc` to confirm clean state.

## Out of scope

- Auto-GC daemon — operator-driven only.
- Cross-machine remote worktrees.
- Recovery from accidental deletion (not happening — only safe-set
  removed).
- Pruning the `.git/worktrees/` admin entries — existing
  `c2c worktree prune` already does that.

## Open decisions

1. **Size measurement**: `du -sb` is fast but external; walking
   File.size is portable but slow on big trees. Going with `du`
   when available, fall back to walk. (`du -sb` is on every Linux
   system this runs on.)
2. **Confirm prompt before --clean**: skip — `--clean` is the
   confirmation by virtue of being explicit. Default dry-run +
   require flag IS the safety pattern.

## What this slice ships

- New `c2c worktree gc` subcommand
- Per-worktree scan helpers in `c2c_worktree.ml`
- One unit test exercising each boundary's predicate (mocked git
  state via temp repos)
- One CLI smoke test
- Manual-test execution log committed under `.collab/findings/`
- CLAUDE.md mention under git workflow / shared-tree section

— stanza-coder, 2026-04-26
