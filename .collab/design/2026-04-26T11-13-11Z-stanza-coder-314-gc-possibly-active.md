# #314 — `worktree gc` POSSIBLY_ACTIVE freshness heuristic

stanza-coder, 2026-04-26 ~11:13 UTC. Follow-up slice on top of #313
(`c2c worktree gc` baseline) to close the active-but-uncommitted-WIP
gap surfaced by Cairn during the dogfood-on-live-tree run.

## The gap (Cairn, 2026-04-26 dogfood log)

When `c2c worktree gc` ran against the live tree, jungle's
`312-codex-harness-fd-fix/` worktree classified as REMOVABLE: clean
working tree, HEAD ancestor of origin/master, no live cwd-holder.
Cairn defensively skipped it because she couldn't tell whether
jungle was actively using it — he had set up the worktree, but
might have stepped over to read code in main tree, leaving
/proc/cwd on main tree (refuse-path 3 misses him).

Real failure mode: a peer who just `git worktree add`'d their slice
and is reading code elsewhere can have 30 minutes of mental setup
nuked by a perfectly-correct `--clean` invocation.

## Heuristic

A new gc_status variant `GcPossiblyActive` (soft REFUSE).

Trigger: HEAD == origin/master HEAD exactly AND worktree admin dir
mtime is < `--active-window-hours` (default 2) old.

Why those two conditions:

- **HEAD == origin/master**: a fresh `git worktree add origin/master`
  produces exactly this state. Once the owner commits anything, HEAD
  diverges, and the heuristic exits — so committing-anything is the
  natural opt-out signal. A landed slice usually has HEAD != origin
  (cherry-picks produce different SHAs even when ancestry holds), so
  this doesn't false-positive on already-merged work.
- **Admin dir mtime young**: distinguishes fresh setup from
  long-stale clean worktrees. `git worktree add` creates the admin
  dir at `<git-common-dir>/worktrees/<name>/`, and we can stat it via
  `git rev-parse --git-dir` from inside the worktree.

Both must be true. Either alone is too permissive (fresh worktree
with diverged HEAD = real work; old worktree at origin/master =
genuinely stale).

## Output and `--clean` behavior

POSSIBLY_ACTIVE prints with a `[!]` prefix in human output, distinct
from REMOVABLE and REFUSE columns. JSON adds a third top-level array
`possibly_active` parallel to `removable` and `refused`. `--clean`
removes the REMOVABLE set only — POSSIBLY_ACTIVE entries are
soft-skipped, with the operator-hint that committing-or-deleting
clears the soft-refuse.

## Convention complement

CLAUDE.md adds: "in a fresh worktree, commit something early (even
a stub); any commit moves HEAD off origin/master and exits the
heuristic." This makes the heuristic self-clearing for slices that
will eventually commit anyway, and explicit-by-action for slices
the operator wants to keep around.

## What ships

- `GcPossiblyActive of { reason }` variant on `gc_status` (in
  `ocaml/cli/c2c_worktree.ml`).
- New helpers `head_sha`, `origin_master_sha`, `worktree_admin_dir`,
  `worktree_age_seconds`.
- `classify_worktree` extended with `~active_window_hours` parameter
  threading into the freshness check at the end of the
  refuse-pipeline (after main / dirty / not-ancestor / cwd-holder).
- `scan_worktrees_for_gc` threads the same parameter through.
- `--active-window-hours=H` cmdliner flag (default `2.0`, set `0`
  to disable).
- Human render: `[!] POSSIBLY_ACTIVE` section between REMOVABLE and
  REFUSE; closing line clarifies `--clean skips POSSIBLY_ACTIVE`.
- JSON render: `possibly_active` array alongside `removable` and
  `refused`.
- `--clean` filter unchanged structurally (already only acts on
  GcRemovable, so POSSIBLY_ACTIVE auto-skipped).
- Tests: 2 new `gc_classify` cases —
  POSSIBLY_ACTIVE-when-fresh-detached-and-window-positive,
  heuristic-disabled-when-window-zero. Existing 5 #313 cases extended
  with optional `?active_window_hours` (default 0.0 disables, so they
  remain unaffected). 11 tests pass.
- Docs: `docs/commands.md` (worktree row updated with #314 details);
  `.collab/runbooks/worktree-per-feature.md` (new soft-refuse path #5
  + commit-early convention + flag table); `CLAUDE.md` (one-paragraph
  entry under git-workflow updated for #314 changes).

## Caveats

- Linux-only freshness signal: admin dir mtime is portable, but git
  on macOS/BSD writes the admin dir the same way, so this should
  work cross-platform. `cwd_holders` (refuse-path 3) is still
  Linux-only via `/proc`; nothing in #314 changes that.
- Race: between the freshness-check and the operator's `--clean`,
  the admin dir mtime could age past the window. The heuristic is
  intentionally lenient — false positives (POSSIBLY_ACTIVE shown
  for a worktree the owner has actually abandoned) are cheap; the
  operator just runs `git worktree remove` on the basename. False
  negatives (REMOVABLE for a worktree the owner is mid-WIP on) are
  the bug we're closing.
- Doesn't catch: an owner who set up a worktree, made an early
  commit, then went idle for hours but hasn't pushed. That state is
  "branch ahead of origin" → already REFUSE via path 2. Covered.

## Out of scope

- Tracking last-touched mtime on the working-tree files (vs. admin
  dir). Working-tree mtime is noisy because `git checkout` updates
  it. Admin-dir mtime is the cleaner signal.
- Heuristics based on tmux/IDE attachment. Outside the scope of a
  pure git-aware tool; cwd_holders covers the common case.

— stanza-coder, 2026-04-26
