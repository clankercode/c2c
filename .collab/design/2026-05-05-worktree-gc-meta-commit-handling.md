# Design: Worktree GC — meta-commit handling for safe cleanup

**Author:** stanza-coder · 2026-05-05  
**Status:** draft  
**Related:** worktree-gc-commit-safety design doc, S1 `--verbose` (1aba1047)  
**Builds on:** `head_equivalent_on_origin_master` + `unmerged_cherry_commits`  

## Problem

Running `c2c dev worktree gc --verbose` against 598 worktrees shows:
- **0 REMOVABLE** 
- **595 REFUSE**

But a manual `git cherry` audit proved all *code* content already
landed on master. The discrepancy: worktrees accumulate **meta commits**
(sitreps, docs, findings, design docs, todo updates) during active work.
These meta commits are never cherry-picked because the coordinator only
cherry-picks feature/fix code. When `head_equivalent_on_origin_master`
runs `git cherry` and sees `+` lines for these meta commits, it returns
`false`, classifying the worktree as REFUSE.

**Result:** 595 worktrees that are genuinely safe to delete are stuck
as REFUSE because of orphaned meta commits nobody needs.

## Analysis: what's unmerged

From the 595 REFUSE'd worktrees:
- 4,378 unique unmerged SHAs total
- 2,328 meta commits (sitreps, docs, chore, research, findings, todo, design)
- 2,050 code-looking commits (feat, fix, refactor, perf, test) — these
  are **shared history** (same commit appearing in many worktrees that
  branched from the same point; the content IS on master via cherry-pick
  but the SHA doesn't match because `git cherry` in the worktree doesn't
  resolve the indirection correctly for deep shared history)

68 worktrees have ONLY meta commits. The remaining 527 have shared
history code commits that also appear "unmerged" by SHA but are
content-equivalent when tested from the main tree (as proven by the
2026-05-05 audit).

## Root Cause

Two issues:

### Issue 1: Meta commits are orphaned by design

The coord cherry-pick flow only picks *feature code*. Meta commits
(sitreps, findings, design docs) committed inside worktrees during
active development are intentionally left behind — they served their
purpose in-context and don't need to land on master. But `git cherry`
flags them as unmerged → REFUSE.

### Issue 2: Shared-history depth confuses `git cherry`

When a worktree was branched from an old point (pre-push), it carries
hundreds of ancestor commits that are on master via cherry-pick but
have different SHAs. Running `git cherry` from *within the worktree*
against `origin/master` shows these as `+` because `git cherry` uses
patch-id matching, and cherry-picked commits with conflict resolution
produce different patch-ids than the original.

The earlier audit worked because it ran `git cherry origin/master <branch>`
from the *main tree* (where the object DB sees both sides clearly).
But the gc runs from within each worktree where the view is narrower.

## Proposed Solution

### Approach: "meta-safe" classification

Add a new classification step between the current REFUSE check and the
final verdict:

1. If `head_equivalent_on_origin_master` returns false (some `+` commits):
2. Collect the `+` commits via `unmerged_cherry_commits`
3. Classify each as **meta** or **code** based on commit message prefix
4. If ALL unmerged commits are meta → classify as `GcRemovable` with
   reason "only meta commits unmerged (safe to lose)"
5. If there are code commits: run a *second-pass* check from the main
   tree's perspective to handle Issue 2 (shared history)

### Meta commit patterns (safe to lose)

A commit is "meta" if its subject matches any of:
- `sitrep*`, `docs*`, `chore*`, `research*`, `findings*`
- `todo*`, `collab*`, `design*`, `log(*`
- `wip(*` (work-in-progress checkpoints)
- `add .collab/*`, `update .collab/*`

### Second-pass check for code commits

For worktrees that have unmerged "code" commits, run a more expensive
but accurate check:

```
git cherry origin/master <worktree-HEAD-sha>
```

Run this from the **main tree** (not from within the worktree) so the
object DB has full visibility. If all code commits show `-` from this
vantage point, the worktree is safe — the code landed via cherry-pick
with minor conflict resolution that changed the patch-id.

### New gc_status variant

```ocaml
type gc_status =
  | GcRemovable of { reason : string }
  | GcRefused of { reason : string; unmerged_commits : (string * string) list }
  | GcPossiblyActive of { reason : string }
  | GcMetaOnly of { reason : string; meta_commits : (string * string) list }
    (* All unmerged commits are meta — safe to remove, but surfaced
       separately so the operator sees what's being lost *)
```

Or simpler: just fold into GcRemovable with a distinct reason string
and leave the meta commits in the verbose output.

## Implementation Plan

### S2a: Meta-commit safe-to-lose classification

File: `ocaml/cli/c2c_worktree.ml`

1. Add `is_meta_commit : string -> bool` that pattern-matches subject prefixes
2. In `classify_worktree`, when the 3-way check fails:
   - Collect `unmerged_cherry_commits`
   - If ALL are meta → `GcRemovable { reason = "only meta commits unmerged (safe to lose)" }`
   - If some are code → proceed to second-pass (S2b) or REFUSE
3. Update verbose output to show meta commits being discarded

**Size: XS** — simple string matching + logic change in classify.

### S2b: Main-tree perspective cherry check (deferred?)

For worktrees with "code" unmerged commits:
1. Resolve the worktree HEAD SHA
2. Run `git cherry origin/master <sha>` from the repo root (not worktree)
3. If all `-` → reclassify as REMOVABLE
4. If still `+` → genuine REFUSE

**Size: S** — needs to invoke git from a different cwd than the
worktree being classified. May require refactoring `git_command` to
accept an explicit object-db path or running from the main tree.

**Alternative:** Just mark the 527 "code-unmerged-but-actually-landed"
worktrees as needing manual verification, and let the operator pass
`--force` to delete them after the meta-only ones are cleaned up.

### S2c: `--force-meta` flag for gc --clean

Add `--force-meta` (or just make it default behavior): when `--clean`
is passed, also remove worktrees classified as "meta-only unmerged."
Without this flag, they'd show as REMOVABLE in dry-run but still need
explicit `--clean` to actually delete.

## Recommendation

**Ship S2a immediately** — it unblocks 68 worktrees that are purely meta.
**Ship S2b next** — it should unblock the remaining 527.
**S2c is just a flag** — trivial once the classification is right.

The 68 meta-only worktrees prove the approach works. The 527 need the
main-tree-perspective cherry check (S2b) to avoid false "code unmerged"
verdicts caused by shared-history depth.

## Open Questions

- Should meta commits be auto-cherry-picked to master before deletion?
  → **No.** Sitreps/findings from 3 weeks ago inside a feature worktree
  are contextual artifacts, not canonical docs. If they're important,
  they were already captured in `.collab/` on master separately.
- Should there be a `--preserve-meta` flag that cherry-picks them?
  → Maybe as a future enhancement, but not for the initial cleanup.
- Is the meta pattern list complete?
  → Start conservative; expand if gc still shows unexpected REFUSE.
