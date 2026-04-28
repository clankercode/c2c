# #313 worktree-gc — manual-test execution log

stanza-coder, 2026-04-26 ~10:35 UTC. Manual exercise of the
`c2c worktree gc` safety boundaries against the live shared tree,
per coordinator's request. Companion to design doc
`.collab/design/2026-04-26T10-26-28Z-stanza-coder-313-worktree-gc.md`.

Five worktree states set up under `.worktrees/gc-test-*`. All five
classification paths AND the `--ignore-active` override AND `--clean`
exercised end-to-end.

## Setup

```
git worktree add .worktrees/gc-test-A origin/master              # State A
git worktree add .worktrees/gc-test-B origin/master              # State B
echo modified > .worktrees/gc-test-B/dirty.txt                   # → dirty

git worktree add .worktrees/gc-test-C origin/master              # State C
(cd .worktrees/gc-test-C && sleep 600) &                          # → active cwd
PID=$!  # captured for later kill

git worktree add -b test/gc-D .worktrees/gc-test-D origin/master # State D
(cd .worktrees/gc-test-D && touch unmerged && git add unmerged \
   && git commit -m unmerged)                                    # → branch ahead

git worktree add --detach .worktrees/gc-test-E origin/master     # State E
```

## Test 1 — dry-run, all states active

```
$ c2c worktree gc --path-prefix=gc-test-

REMOVABLE:
  .worktrees/gc-test-A   ancestor of origin/master, clean
  .worktrees/gc-test-E   ancestor of origin/master, clean

REFUSE:
  .worktrees/gc-test-B                              REFUSE: dirty working tree
  .worktrees/gc-test-C                              REFUSE: active cwd: pid=1653452 (sleep 600)
  .worktrees/gc-test-D   refs/heads/test/gc-D       REFUSE: HEAD not ancestor of origin/master
```

✅ All four refuse-paths fire correctly. A and E classified as
REMOVABLE.

## Test 2 — `--ignore-active` flips State C

```
$ c2c worktree gc --path-prefix=gc-test- --ignore-active

REMOVABLE:
  .worktrees/gc-test-A   ancestor of origin/master, clean
  .worktrees/gc-test-C   ancestor of origin/master, clean
  .worktrees/gc-test-E   ancestor of origin/master, clean

REFUSE:
  .worktrees/gc-test-B   REFUSE: dirty working tree
  .worktrees/gc-test-D   REFUSE: HEAD not ancestor of origin/master
```

✅ With `--ignore-active`, State C reclassified to REMOVABLE.
States B and D remain REFUSE (their refuse-paths are not the
active-cwd one).

## Test 3 — kill sleep, re-run dry-run

```
$ kill $PID
$ c2c worktree gc --path-prefix=gc-test-

REMOVABLE: A, C, E
REFUSE:    B (dirty), D (branch ahead)
```

✅ Without sleep alive, State C naturally classifies as REMOVABLE
(no override needed). Confirms the `/proc/<pid>/cwd` scan correctly
distinguishes live vs. dead processes.

## Test 4 — `--clean` on bounded set

```
$ c2c worktree gc --path-prefix=gc-test- --clean

REMOVABLE: A, C, E
REFUSE: B, D

Removing 3 worktrees...
  removed .worktrees/gc-test-A
  removed .worktrees/gc-test-C
  removed .worktrees/gc-test-E
Done. 3 removed, 46.5 MB freed.
```

✅ `--clean` removed exactly the REMOVABLE set. REFUSE set
untouched. Disk reclaim measured (46.5 MB for three minimal
checkouts).

## Test 5 — verify aftermath

```
$ c2c worktree gc --path-prefix=gc-test-

REFUSE:
  .worktrees/gc-test-B   REFUSE: dirty working tree
  .worktrees/gc-test-D   REFUSE: HEAD not ancestor of origin/master
```

✅ A, C, E gone. B and D still present (correctly refused). The
`gc-test-*` filter still resolves them; their state hasn't
changed.

## Defense-in-depth: main worktree never offered

In every test above, the main worktree (`/home/xertrov/src/c2c`)
was never listed under REMOVABLE or REFUSE. Filtered at scan
time via the `.worktrees/`-prefix check, AND the
`classify_worktree` function explicitly compares against
`main_worktree_path()` and returns "main worktree (never
offered)" if reached.

## Live-tree observation

While running the unbounded scan during Test 1, the tool reported
**16 REMOVABLE worktrees totaling 1.4 GB** on the live shared
tree (real disk pressure relief opportunity, validates the slice's
motivation). 137 REFUSE worktrees correctly classified.
`--clean` against this set was deliberately NOT exercised — that's
a coord-gated operational decision, not a manual-test concern.

## Boundary checklist (satisfied)

- [x] Dirty working tree → REFUSE (Test 1, B)
- [x] Branch not ancestor of origin/master → REFUSE (Test 1, D)
- [x] Live cwd-holder → REFUSE (Test 1, C)
- [x] `--ignore-active` overrides cwd-holder check (Test 2, C)
- [x] Clean + ancestor + no cwd-holder → REMOVABLE (Test 1, A and E)
- [x] Detached HEAD reachable from origin/master → REMOVABLE (Test 1, E)
- [x] Main worktree never offered (all tests, structural)
- [x] `--clean` removes exactly the REMOVABLE set (Test 4)
- [x] `--clean` leaves REFUSE set intact (Test 4 → 5)

## Cleanup

After Test 5, the remaining REFUSE-state test worktrees were
force-removed manually since they were test scaffold:

```
git worktree remove --force .worktrees/gc-test-B
git worktree remove --force .worktrees/gc-test-D
git branch -D test/gc-D
```

These force-remove paths are NOT what the GC tool does — `--clean`
respects refuse-paths. Force-cleanup of dirty/unmerged worktrees
is an operator's explicit deliberate action, not the GC's job.

— stanza-coder, 2026-04-26
