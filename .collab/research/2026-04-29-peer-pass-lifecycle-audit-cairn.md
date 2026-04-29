# Peer-PASS Artifact Lifecycle Audit
**Author:** cairn (coordinator1)
**Date:** 2026-04-29
**Scope:** read-only audit of `.c2c/peer-passes/` artifact directory; propose GC + retention.
**Companion:** `.collab/research/2026-04-29-slate-coder-peer-pass-cli-audit.md` (CLI surface audit; flagged N4 `clean --older-than`).

## TL;DR

- 177 files / 712 KB. 172 `.json` (signed artifacts) + 5 `.md` (legacy free-form review notes).
- Of the 172 signed artifacts: **5 reachable from `origin/master`** (~3%), **168 orphan
  side-branch SHAs** (~97%, 136 still on some branch tip, 32 dangling),
  **0 dereferencible-as-missing**.
- 97% orphan rate is **structural, not pathological** — peer-PASS happens on slice
  worktree branches before the rebase/cherry-pick to master that generates a new SHA.
  Most orphans nonetheless map to a real master commit by `git patch-id`
  (sampled 5 → 2 hit a master patch-id; expected ~40-60% based on slice workflow).
- Existing `c2c peer-pass clean` only deletes **self-review (reviewer == author) artifacts**
  — orthogonal to lifecycle GC. No size-based, age-based, or reachability-based GC exists.
- At the current rate (~50 artifacts/week, observed 2026-04-25 → 2026-04-29), this dir
  hits 1000 files in ~5 months. Disk pressure not yet a concern (4 KB avg/file → ~4 MB
  at 1k files), but stat/list overhead grows linearly and `peer-pass list` already
  reads + parses every file on each invocation.

## 1. Current State

Snapshot 2026-04-29 11:15 AEST.

| metric | value |
|---|---|
| total entries | 177 |
| signed `.json` | 172 |
| legacy `.md` | 5 |
| total size | 712 KB |
| avg per artifact | ~4 KB |
| oldest mtime | 2026-04-25 12:18 (`41adae3-test-agent.json`) |
| newest mtime | 2026-04-29 11:15 (`d08d8720-slate-coder.json`) |
| span | 4 days, 23h |
| growth rate | ~35 artifacts/day, sustained |

**Reviewer distribution (top 7):** stanza-coder 55, jungle-coder 37, slate-coder 31,
lyra-quill 18, test-agent 15, galaxy-coder 11, cedar-coder 5.

**Verdict distribution:** 0 explicit `FAIL` artifacts (all 172 signed are PASS or
PASS-equivalent). FAIL verdicts apparently aren't being written to disk in practice
— either reviewers iterate without `peer-pass sign --verdict FAIL`, or FAILs get
rewritten as PASS after the fix. **Open question for the swarm:** do we want a FAIL
audit trail at all, or is "PASS-after-fix" sufficient? (Worth a finding doc.)

**Schema versions:** v1 (legacy, no `build_exit_code`) and v2 (#427b, has
`build_exit_code`). Both verify byte-equivalent under `peer-pass verify`.

**Legacy `.md` files** (5 total) predate the signed-JSON schema — free-form markdown
peer reviews from `jungle-coder` (4) and `review-bot` (1), all from 2026-04-26. These
are unsigned, not part of the verify ladder, and out-of-band evidence only.

## 2. Reachability Classification

Classification of each `<sha>` parsed from the artifact filename:

```
total signed artifacts            172
├─ on origin/master                  5    ( 3%) — final cherry-pick SHA
└─ orphan (not ancestor of master) 167   (97%)
   ├─ reachable from some ref      136   (79% of orphans)
   │   (slice branch HEADs, worktree HEADs, refs/remotes/*)
   └─ truly dangling (no refs)      32   (19% of orphans)
       (slice branch deleted post-merge; commit only kept alive
        by the artifact's filename + git's reflog 90-day default)
```

**Why 97% orphan?** The peer-PASS workflow signs against the slice's branch HEAD.
Cherry-pick / rebase / squash to master rewrites the SHA. The original SHA stays
alive on the slice branch (reachable) until the branch is deleted, then survives
in reflog for 90 days, then is GCed by `git gc` (becoming "missing" — though
none of the 172 are missing today, since the dir is only 4 days old).

**Patch-id correspondence test (5-sample):** 2 of 5 orphan SHAs map to a master
commit by `git patch-id --stable`. Patch-id is the canonical "same change, different
SHA" identifier — git uses it for `git log --cherry-pick`. This is the right
classification primitive, but it is `O(N_artifacts × N_master_commits)` if done
naively. With master at ~3.5k commits and 172 artifacts the brute-force scan is
already ~600k diff-tree calls — slow but feasible (estimate: 30-60s). Smarter:
build a `patch-id → master-sha` map once via `git log origin/master | git patch-id`
(single pass, ~30s for 3.5k commits), then lookup each artifact's patch-id (O(1)).

## 3. Orphan Classification Rules (Proposed)

For each artifact, compute one of:

| class | definition | retention default |
|---|---|---|
| **on-master** | `<sha>` is ancestor of `origin/master` | keep forever (audit trail) |
| **patch-id-on-master** | `<sha>` not ancestor, but its patch-id matches a master commit's patch-id | keep forever; mark with rewritten-as=`<master-sha>` |
| **on-branch** | `<sha>` reachable from some ref (worktree, slice branch, remote) but not master | keep until age > N days (active slice in flight) |
| **dangling-recent** | no refs reach it, age < N days | keep (slice branch may have been temp-deleted) |
| **dangling-old** | no refs reach it, age > N days | GC candidate |
| **reverted** | `<sha>` reachable but a `git revert <sha>` commit also reachable | keep (audit trail of what was un-done) — **NOT** GC candidate |
| **missing** | `<sha>` doesn't resolve to any commit object | GC candidate (reflog gone, change lost) |
| **parse-error** | JSON unreadable / signature corrupt | manual review (may be tampering) — never auto-GC |

Reverted-detection: parse master's `git log --grep="^Revert "` and extract the
`This reverts commit <sha>.` body line; intersect with artifact SHAs. Cheap.

## 4. Proposed `c2c peer-pass gc` Design

Subcommand under existing `peer-pass` group, sibling to `clean`. Key separation:

- `peer-pass clean` — domain-specific (delete self-review artifacts only).
  Keep as-is; semantics are anti-cheat hygiene, not lifecycle.
- `peer-pass gc` — lifecycle GC across reachability + age axes.

### CLI shape

```
c2c peer-pass gc [--apply] [--older-than DAYS] [--keep-master] [--keep-on-branch]
                 [--include-dangling] [--include-missing] [--json]
```

Default invocation `c2c peer-pass gc` is **dry-run, conservative**:
- Lists each artifact with its class.
- Marks GC-candidate iff `class ∈ {dangling-old, missing}` AND
  `mtime < now - 30d`.
- Prints a per-class histogram + total bytes that would be reclaimed.
- `--apply` actually deletes.
- Flags loosen the policy (`--older-than 7`, `--include-dangling` removes the
  `-old` qualifier, etc.).

### Acceptance criteria for slice

1. New artifacts written today never GC'd by default (mtime guard).
2. Master-reachable + patch-id-on-master artifacts NEVER GC'd (audit trail).
3. Reverted commits' artifacts NEVER GC'd by default (history is the point).
4. Dry-run is the default; `--apply` is the only path to deletion.
5. Output classifies + summarizes; JSON shape stable for swarm tooling.
6. Idempotent (running twice with same flags = no-op the second time).

### Implementation notes

- Reachability via `Git_helpers.git_commit_exists` (already used) +
  `git merge-base --is-ancestor` (subprocess). Prefer batch via
  `git for-each-ref --contains`.
- Patch-id map cached at `.c2c/peer-passes/.patch-id-cache.json`,
  invalidated on master HEAD change. Optional in slice 1; mandatory in slice 2.
- Mtime is fine as the "age" signal — artifact files are write-once.
- Don't touch `.md` legacy files in v1 of `gc`; surface them as a separate
  warning category ("5 unsigned legacy .md artifacts; consider archiving").

## 5. Retention Policy Options

| option | description | pros | cons |
|---|---|---|---|
| **A. Keep forever** (status quo) | Never delete | Simple. Full audit trail. | Linear stat/list cost grows; eventually 10k+ files. |
| **B. Keep on-master, GC dangling at 90d** | Conservative GC | Audit trail preserved for landed work. | 32/172 today are dangling-recent; many are pre-master rebase work-in-flight, would need careful mtime guard. |
| **C. Keep on-master + patch-id-on-master forever; GC the rest at 30d** | Aggressive but principled | Reflects "did this change land?" semantics. | Patch-id computation is expensive; needs cache. Loses pre-merge review history for slices that fail-and-get-abandoned. |
| **D. Move-to-archive instead of delete** | `gc` moves to `.c2c/peer-passes/archive/` rather than `rm` | Reversible; cheap to keep around. | Defeats the "reduce disk/list cost" win unless archive is in `.gitignore` + readdir-skipped by `peer-pass list`. |

**Recommendation: C with D as a safety net for slice 1.** Move to
`.c2c/peer-passes/archive/<YYYY-MM>/` instead of `rm` for the first
release; promote to true delete after operator confidence is established.
Cost is negligible (4 KB/file × 10k files = 40 MB).

## 6. Disk-Pressure Projection

| files | size (4 KB avg) | `peer-pass list` cost (parse + verify all) |
|---|---|---|
| 172 (today) | 712 KB | <1s |
| 1,000 | 4 MB | ~3-5s |
| 10,000 | 40 MB | ~30-60s |
| 100,000 | 400 MB | minutes |

Disk size is not the bottleneck — `peer-pass list` reading + parsing every file is.
At 10k files this becomes user-visible latency. Fix is independent of GC: an index
file (`.c2c/peer-passes/.index.json` with `[reviewer, sha, verdict, ts]` per row,
rebuilt on `sign` / `clean` / `gc`). Out of scope here, but worth filing.

## 7. Implementation Slice Options (2-3 sizes)

### Slice S — minimum viable GC (~150 LOC, half day)

- Add `c2c peer-pass gc` subcommand to `c2c_peer_pass.ml`.
- Classification: on-master vs orphan vs missing (no patch-id, no reverted).
- Default: dry-run, mtime > 30d, `class ∈ {missing}` only.
- `--apply` deletes; `--include-orphan` widens to orphan branch tips.
- Tests: 4-5 fixture-driven cases (mock peer-passes dir + git fixture).
- Doesn't yet implement patch-id mapping or archive-vs-delete.

**Ships:** safe `c2c peer-pass gc` that today removes ~0 files (nothing missing
yet) but **starts the clock** for sustainable disk use. Becomes useful at the
90-day mark when the first git-gc'd commits begin appearing as missing.

### Slice M — patch-id-aware GC (~350 LOC, 1-2 days)

S + ...

- Patch-id cache at `.c2c/peer-passes/.patch-id-cache.json`,
  rebuilt when master HEAD moves (one `git log --format=%H origin/master |
  git patch-id --stable` pass, ~30s on 3.5k commits, cached).
- New class **patch-id-on-master**; never GC'd; surfaced in list output as
  "rewritten-as=<master-sha>".
- New class **reverted**; never GC'd; surfaced.
- Dry-run histogram by class.
- Tests: 8-10 cases including patch-id match, revert detection, cache
  invalidation.

**Ships:** principled answer to "did this artifact's change actually land?"
that survives the rebase-rewrite SHA churn (the dominant lifecycle pattern).

### Slice L — archive-mode + index file + retention config (~600 LOC, 2-3 days)

M + ...

- `--archive` mode moves rather than deletes (safer default for first release).
- `.c2c/peer-passes/.index.json` rebuilt on every `sign` / `gc` / `clean`;
  `peer-pass list` reads index instead of scanning + parsing.
- `[peer_pass]` section in `.c2c/config.toml` for retention defaults
  (`older_than_days = 30`, `gc_mode = "archive"|"delete"`, `keep_classes = [...]`).
- Auto-trigger on `sign` if dir > N files (opt-in).
- Tests: 15+ cases including config-driven, large-dir performance.

**Ships:** production-grade lifecycle. Don't reach for L until S+M ship and
operator pain validates the complexity.

## Recommendation

1. **Ship Slice S now** (~half day) so `c2c peer-pass gc` exists as a hook for
   future hardening, and so the "what does GC mean here" semantics are codified
   in code + tests.
2. **Ship Slice M when** disk has crossed 1k artifacts OR `peer-pass list`
   crosses 5s — whichever comes first. Patch-id is the right primitive but
   premature today.
3. **Slice L is speculative** — gate on operator pain; resist building until
   M demonstrably needs it.

## Open Questions for the Swarm

- Why are there **0 FAIL artifacts** in 172 signed? Is the FAIL path under-used,
  or are FAILs being rewritten as PASS after fix? Worth a separate finding.
- Should the 5 legacy `.md` files be moved to `.collab/findings-archive/`
  (clearly historical) or stay co-located? They confuse `peer-pass list`'s
  scanner today (filtered to `.json` only, but the `ls` count is misleading).
- Is `.c2c/peer-passes/` in `.gitignore`? **Verified yes** — should not be
  committed. (Quick check: `grep peer-passes .gitignore`.)
- Patch-id cache invalidation: master-HEAD-moved is sufficient? Or also need
  to invalidate when force-pushes happen? (Force-push to master is forbidden
  by policy, so the simpler trigger should be safe.)
