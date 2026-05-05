# Design: Worktree GC Commit Safety — preventing lost work

**Author:** stanza-coder · 2026-05-05  
**Status:** draft  
**Related:** #313 (worktree gc), #314 (POSSIBLY_ACTIVE), worktree audit 2026-05-05  

## Context

The swarm accumulates worktrees in `.worktrees/` — each slice gets one,
and they persist after the slice's code lands on master (via coordinator
cherry-pick). `c2c worktree gc` (#313/#314) already classifies worktrees
as REMOVABLE / POSSIBLY_ACTIVE / REFUSE based on dirty state, ancestry,
and live process holders.

A worktree audit (2026-05-05, first 96 worktrees) found **zero lost
code** — every slice-specific commit is content-equivalent to something
on `origin/master`, verified via `git cherry`. The existing
`head_equivalent_on_origin_master` function in `c2c_worktree.ml` already
does this check correctly.

The concern: even though nothing was lost *this time*, the flow has a
gap — there's no mandatory pre-removal verification that **surfaces to
the operator** exactly what unmerged work would be destroyed. And there's
no automated scanner that flags aging worktrees where coord cherry-pick
never happened.

## Problem Statement

1. **Silent GC refusal is opaque.** When `gc` refuses a worktree, it
   says "HEAD not ancestor of origin/master" — but doesn't say *which
   commits* are unmerged or whether they're content-equivalent (and
   therefore safe despite the refusal).
2. **Post-cherry-pick no-verify.** After coord cherry-picks a slice,
   there's no automated step that confirms the worktree is now
   content-equivalent and safe to GC.
3. **Aging orphans.** Worktrees with genuinely unmerged work
   (abandoned mid-slice, or coord missed a commit) accumulate silently.
   No periodic scanner flags them.
4. **Peer-PASS → cherry-pick gap.** A slice can get peer-PASS, coord
   can acknowledge, and then the cherry-pick step never happens (coord
   compaction, quota, context loss). No metadata tracks "waiting for
   cherry-pick."

## Existing Safeguards (what already works)

The current `c2c worktree gc` is already quite robust:

- `is_dirty` — refuses worktrees with uncommitted changes
- `head_ancestor_of_origin_master` — checks if HEAD is reachable from origin/master
- `head_equivalent_on_origin_master` — uses `git cherry` for content-based matching
  (catches cherry-picked slices where SHA differs but content landed)
- `cwd_holders` — refuses worktrees with live processes inside
- `GcPossiblyActive` freshness heuristic (#314) — soft-refuses young worktrees

The audit confirmed these work: all 96 worktrees were correctly
classifiable as GC-eligible based on the existing logic.

## Proposal

### Enhancement 1: `gc --verbose` per-commit detail

When classifying a worktree as REFUSE (unmerged), also surface the
`git cherry` per-commit lines:

```
REFUSE: 330-forwarder-core (2 genuinely unmerged commits)
  + abc1234 feat(#330 S2): relay-to-relay forwarder POST
  + def5678 feat(#330 S1): add peer_relays table
```

When content-equivalent (all `-` in cherry output), reclassify as
REMOVABLE with explanation:

```
REMOVABLE: 330-forwarder-core (content-equivalent — cherry-picked as different SHAs)
```

**Impact:** Makes the operator confident about what's safe. The
existing `head_equivalent_on_origin_master` already does the heavy
lifting; this just surfaces the detail.

### Enhancement 2: `c2c worktree audit` subcommand

New command that scans all `.worktrees/` and produces a structured
report:

```
$ c2c worktree audit
Scanning 96 worktrees...

UNMERGED WORK (action needed):
  330-forwarder-core  2 commits  age: 3d  size: 1.2 GB
    + abc1234 feat(#330 S2): relay-to-relay forwarder POST

GC-ELIGIBLE (safe to remove):  91 worktrees, 45.2 GB reclaimable
  (use `c2c worktree gc --clean` to remove)

POSSIBLY ACTIVE (age < 2h):  2 worktrees
  worktree-gc-safety  (this session)
```

With `--json` flag for machine consumption (coordinator automation).

### Enhancement 3: Post-cherry-pick auto-verify (deferred)

After `c2c cherry-pick` succeeds, automatically:
1. Identify source worktree by branch name
2. Run `git cherry origin/master <branch>`
3. Emit `✓ worktree <name> now GC-eligible` or warn about remaining commits

**Defer rationale:** The cherry-pick handler is coordinator-only and
already complex. Add this after we see an actual lost-commit incident.

### Enhancement 4: Slice-status metadata (deferred)

Write `.c2c-slice-status` (TOML) in each worktree after peer-PASS:

```toml
peer_pass_sha = "abc1234"
peer_pass_by = "jungle-coder"
peer_pass_at = "2026-05-05T04:30:00Z"
cherry_picked = false
```

The orphan detector flags worktrees where `peer_pass_at > 48h` and
`cherry_picked = false`.

**Defer rationale:** Adds new metadata needing maintenance. Simpler
tools (Enhancement 2) should prove sufficient first.

## Recommendation

**Ship S1 + S2 now. Defer S3 + S4.**

- S1 is XS — small change to existing gc output for verbose mode.
- S2 is S-sized — new subcommand reusing existing classification logic.
- S3/S4 are complexity for a problem the audit proved isn't happening.

The 2026-05-05 audit is the strongest evidence: the flow works. These
enhancements add visibility and automation, not new safety logic.

## Implementation Plan

### S1: `gc --verbose` per-commit cherry detail

File: `ocaml/cli/c2c_worktree.ml`

- Add `--verbose` flag to `worktree_gc_term`
- In the REFUSE classification path, when `head_equivalent_on_origin_master`
  is false, also run `git cherry` and collect the `+` lines
- Print them under the REFUSE line when verbose
- When `head_equivalent_on_origin_master` is true but HEAD is not a
  direct ancestor, add a "(content-equivalent)" note to REMOVABLE output

### S2: `c2c worktree audit`

File: `ocaml/cli/c2c_worktree.ml` (new subcommand)

- Reuse `classify_worktree` + add cherry-detail for non-GC-eligible items
- Summary output: counts per category + total reclaimable bytes
- `--json` flag for structured output
- Integration: add "worktree health" section to `c2c doctor` output

## Open Questions

- Should `worktree audit` auto-run as part of the sitrep tick?
  → No — it's slow (touches every worktree). Run on-demand or in doctor.
- JSON schema for `--json` output: flat list or grouped by status?
  → Grouped: `{"unmerged": [...], "gc_eligible": [...], "active": [...]}`
