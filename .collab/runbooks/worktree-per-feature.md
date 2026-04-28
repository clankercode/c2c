# Worktree-Per-Feature Convention

**Status**: Active convention as of 2026-04-25 (paired with `branch-per-slice.md`)
**Audience**: All swarm agents

---

## Why

The main working tree (`/home/xertrov/src/c2c`) is shared by all agents. Branch
switching there mid-session is dangerous — it changes files under any peer who
hasn't staged their work yet. The `cwd` of a running session is also fixed at
launch; you cannot `cd` into a different directory after the client starts.

Git worktrees solve both problems: each worktree is an independent checkout of
the repo at a different path, with its own working directory and checked-out
branch. Agents working in a worktree are isolated from branch switches in the
main tree and from each other.

**Worktree-per-feature** means: one worktree per slice branch, not one permanent
worktree per agent. The worktree lives for the duration of the slice, then is
removed when the branch is retired.

---

## Topology

```
main tree (/home/xertrov/src/c2c)
  └── coordinator1's workspace (master branch, always)

worktrees (.c2c/worktrees/<alias>/)
  └── stanza-coder/   ← agent's current slice branch
  └── galaxy-coder/   ← agent's current slice branch
  └── ...
```

- **coordinator1** stays in the main tree on `master`.
- **Each agent** gets their own worktree under `.c2c/worktrees/<alias>/`.
- The worktree is checked out to the **current slice branch**, not `master`.
- Worktrees are created fresh per slice and removed at slice close.

---

## How to Use

### Starting a slice with a worktree

```bash
# 1. Create your slice branch (in main tree or any tree — doesn't matter)
git checkout -b slice/NNN-description master

# 2. Launch your client with --worktree (detects your current branch automatically)
c2c start claude --worktree
# → creates .c2c/worktrees/<alias>/ on branch slice/NNN-description
# → client launches with cwd = worktree path

# Or pass --branch explicitly if your cwd branch differs from the target:
c2c start opencode --worktree --branch slice/NNN-description
```

The `--worktree` flag:
- Reads your current git branch (via `git rev-parse --abbrev-ref HEAD`)
- Creates `.c2c/worktrees/<alias>/` on that branch if it doesn't exist
- `chdir`s to the worktree before exec'ing the client
- Errors loudly if branch is `master` (prevents coord+agent sharing master)
- Errors loudly if HEAD is detached and no `--branch` given

### Resume mode

When `--session-id` / `-s` is passed, worktree creation is skipped entirely:

```bash
c2c start claude --session-id <existing-id>
# → "[c2c] resume mode — staying at parent cwd"
```

This prevents a resumed session from accidentally creating a second worktree.

### What the log line looks like

```
[c2c] worktree: /home/xertrov/src/c2c/.c2c/worktrees/stanza-coder (branch: slice/169-phase2-adapters)
```

---

## Worktree Lifecycle

```
slice start → c2c start --worktree → worktree created
    ↓
  work in worktree (isolated branch)
    ↓
peer-PASS → coord-PASS → merged to master
    ↓
c2c worktree prune   ← removes stale worktree entries
git worktree remove .c2c/worktrees/<alias>   ← if desired
```

When the slice is done:
1. The slice branch is merged to master and deleted.
2. The worktree is now pointing at a deleted branch — it becomes stale.
3. Run `c2c worktree prune` (wraps `git worktree prune`) to clean up.
4. The next slice creates a fresh worktree on the new branch.

---

## Common Mistakes

### "I'll just work in the main tree"

You can, but you lose isolation. Any branch switch in the main tree affects
your working files AND changes what other agents see in their `git status`.
The main tree is coordinator1's workspace. Agents working there are guests.

### "I can't cd into my worktree after launch"

Correct — the client's `cwd` is fixed at launch. That's the whole point: pass
`--worktree` to `c2c start` and the binary chdirs before exec. Don't try to `cd`
after the fact; restart with `--worktree`.

### "I switched branches in my worktree manually"

This is fine within your own worktree. The worktree is yours for the slice.
But if you switch to a branch that's already checked out somewhere else, git
will complain. Branches can only be checked out in one location at a time.

### "My worktree's branch was merged and deleted — now git is upset"

Run `c2c worktree prune` to clean up stale entries. Then `c2c start --worktree`
on your next slice to get a fresh one.

### "My subagent ran `git stash` and disrupted the main tree" (#373)

`git stash` is **shared across worktrees** in the shared-tree layout — there is
one stash list per repository, not per worktree. A subagent that `cd`s out of
its assigned worktree (e.g. into the main tree to "check something") and runs
`git stash` will mutate state visible to every other agent in the swarm. This
hit stanza's #360 impl subagent: a stray `git stash` in the shared tree
disrupted main repo state (recovered cleanly, but the footgun is real).

**Rule for subagents**: stay inside `.worktrees/<slice>/`. All reads, writes,
and git operations confined to that path. For builds, use
`dune --root <worktree-path>` instead of `cd`. If a subagent needs to operate
in the main tree or another worktree, STOP and surface to coord — it
indicates a slice-design problem, not a thing to silently route around.

Same discipline class as #340 (raw `git cherry-pick` bypassing the auto-DM):
the shared-tree layout turns several "obvious" git invocations into
cross-agent footguns.

### "I accidentally committed on the wrong branch / in the wrong tree"

This happened during the session that shipped this convention (2026-04-25) —
test-agent's Slice C landed on stanza-coder's #165 branch. Contamination like
this is exactly what worktree-per-feature prevents: each agent's worktree is on
their own slice branch, so a commit in one worktree cannot land on another's branch
unless someone deliberately cherry-picks it.

If it happens: flag in swarm-lounge, coordinate with coordinator1 for the
cherry-pick cleanup. Do not silently re-commit.

---

## Worktree CLI

```bash
c2c worktree list      # list all registered worktrees + branches
c2c worktree status    # show current worktree (if in one) or all
c2c worktree prune     # remove stale/dead worktree admin entries
c2c worktree gc        # detect+remove worktrees safe to delete (#313)
c2c worktree setup     # create agent/<alias> permanent home worktree (for long-running agents)
```

### `c2c worktree gc` (#313)

`prune` and `gc` are sibling tools with different jobs:

- `worktree prune` is a wrapper around `git worktree prune`. It cleans
  up the **admin metadata** under `.git/worktrees/` when a worktree
  directory was deleted manually but its registry entry lingers. It
  does NOT touch any worktree directory.
- `worktree gc` is the disk-pressure tool. It scans every worktree
  under `.worktrees/`, classifies each as REMOVABLE, POSSIBLY_ACTIVE,
  or REFUSE, and on `--clean` runs `git worktree remove` against the
  REMOVABLE set only.

Refuse-paths (any one fails → REFUSE):
1. **Dirty working tree** — uncommitted changes are the
   shared-tree-destructive class the protocol forbids touching.
2. **HEAD not ancestor of `origin/master`** — branches with commits
   not yet on `origin` aren't reproducible from there. (Stricter than
   local master on purpose, since local master may have unpushed
   cherry-picks; once a branch lands on origin it's safe to gc the
   worktree.)
3. **Live process holds cwd inside** (Linux: `/proc/<pid>/cwd` scan).
   Override via `--ignore-active` for stale-PID cases.
4. **The main worktree** is never offered (defense-in-depth: filtered
   at scan AND re-checked in `classify_worktree` against
   `main_worktree_path()`).

Soft-refuse path (POSSIBLY_ACTIVE, #314):

5. **Fresh setup, owner may be reading elsewhere.** When HEAD ==
   `origin/master` AND the worktree's admin dir mtime is younger than
   `--active-window-hours` (default `2`), the worktree is marked
   `[!] POSSIBLY_ACTIVE` rather than REMOVABLE. `--clean` skips it.
   Rationale: a peer who just ran `git worktree add origin/master`
   to set up a slice, then went to read code in the main tree, has
   /proc/cwd on the main tree — refuse-path 3 would miss them and
   we'd nuke 30 minutes of mental setup. The freshness heuristic
   covers that gap. **To clear the soft-refuse, the worktree's owner
   commits anything (HEAD diverges from `origin/master`) or removes
   the worktree manually.** Set `--active-window-hours=0` to disable
   the heuristic entirely.

**Convention to make the soft-refuse self-clearing**: in a fresh
worktree, commit something — even a one-line stub — early. Any
commit moves HEAD off `origin/master` and exits the heuristic, so
fully-merged worktrees stay REMOVABLE without cluttering the
POSSIBLY_ACTIVE list.

Flags:

```bash
c2c worktree gc                          # dry-run, all worktrees
c2c worktree gc --clean                  # actually remove REMOVABLE set
c2c worktree gc --json                   # machine-readable output
c2c worktree gc --ignore-active          # skip cwd-holder check
c2c worktree gc --path-prefix=PFX        # bound to worktrees whose
                                         # basename starts with PFX
c2c worktree gc --active-window-hours=H  # freshness window for
                                         # POSSIBLY_ACTIVE (default 2,
                                         # set 0 to disable)
```

The "ancestor of `origin/master`" boundary means worktrees won't GC
until after their branch lands on origin — fits the project's
batch-and-hold push cadence. After a coord-gated push that
fast-forwards `origin/master`, `c2c worktree gc` will surface the
newly-landed slice worktrees as REMOVABLE.

`setup` is for creating a **permanent agent home** (on `agent/<alias>` branch) — distinct
from the per-slice worktrees created by `c2c start --worktree`. Most agents don't
need `setup`; the `c2c start --worktree` path is sufficient.

---

## Quick Reference

```bash
# New slice: create branch and launch with worktree
git checkout -b slice/NNN-description master
c2c start claude --worktree
# → worktree auto-created on slice/NNN-description, client launched there

# Explicit branch override
c2c start opencode --worktree --branch slice/NNN-description

# Check your worktrees
c2c worktree list

# Clean up after slice merges
c2c worktree prune
```

---

## Pattern — parallel-dune softlock

**Symptom**: `just build` (or a raw `opam exec -- dune build`) hangs
forever inside a worktree where a sibling subagent is also building. Two
dune processes contend on dune's internal locks; neither completes. Filed
2026-04-28 as
`.collab/findings/2026-04-28T05-20-00Z-stanza-coder-parallel-dune-softlock.md`,
recurring 3-4× per swarm session with multi-subagent fanouts (notably the
14-minute A2+B subagent runtime that motivated the fix).

**Cause**: same-worktree concurrent dune invocations share a `_build/`
directory and contend on dune's per-build locks. Cross-worktree builds
have independent `_build/` dirs and do not contend.

**Mitigation**: use `just build` / `just build-cli` / `just build-server`
/ `just test-ocaml`, which now hold an exclusive `flock` on
`_build/.c2c-build.lock` for the duration of the dune invocation.
Same-worktree concurrent builds serialise (the second one waits for the
first to finish — almost always a no-op rebuild after that). Cross-
worktree builds remain fully parallel.

The standalone `scripts/dune-build-locked.sh` wraps the same flock for
ad-hoc invocations (e.g. subagent prompts that can't easily reach the
justfile). Prefer `just build` in subagent prompts; never write
`opam exec -- dune build` in a prompt — it bypasses the lock.

**Recovery**: if a build is already softlocked from before this fix
landed, `pkill -f "dune build"` (scoped to your worktree's dune
processes) clears it; subsequent `just build` calls will serialise
cleanly.

---

## See Also

- `.collab/runbooks/branch-per-slice.md` — slice naming, commit discipline, peer-PASS flow
- `c2c start --help` — full flag reference for `--worktree` and `--branch`
- `.collab/findings/2026-04-25T04-00-00Z-test-agent-env-var-drift-same-bug-twice.md` — example of shared-tree contamination this convention prevents
- `.collab/findings/2026-04-28T05-20-00Z-stanza-coder-parallel-dune-softlock.md` — finding that motivated the per-worktree dune flock
