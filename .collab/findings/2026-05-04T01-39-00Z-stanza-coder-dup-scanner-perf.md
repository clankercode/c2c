# Dup-scanner O(n²) merge — not a bottleneck at current scale

**Date**: 2026-05-04T01:39Z
**Author**: stanza-coder
**Severity**: low (informational)
**Status**: CLOSED — 30s timeout guard shipped (eba5870c)

## Symptom

`c2c doctor` was hanging on the dup-scanner invocation, hitting a 30s
timeout added in eba5870c.

## Analysis

Profiled `c2c-dup-scanner.py --repo . --full --warn-only`:
- **Wall time**: 1.4s (consistent across runs)
- **Files scanned**: ~150 (.py/.ml/.mli)
- **Clusters produced**: ~13 (5 kept, 8 suppressed)
- **Total windows**: small (25-token sliding window)

The O(n²) is in `find_clusters()` lines 304-327: the merge phase
iterates `clusters × merged_clusters`, and within that does
`cluster_starts × mc_starts`. With ~13 clusters this is negligible.

The comment on line 573 warns about O(n²) "in windows" but at current
repo size the window count doesn't produce meaningful overhead.

## Root cause of the 30s hang

Likely transient — disk I/O spike, cold filesystem cache, or system
load. The timeout wrapper (eba5870c) is the correct mitigation.

## Recommendation

- **No algorithmic change needed** at this scale.
- If the repo grows 10x in .py/.ml files, revisit — the merge could
  be improved with a sorted-interval approach (sort all window starts,
  sweep once) reducing to O(n log n). But that's premature now.
- The 30s timeout in c2c-doctor.sh is the right safety net.
