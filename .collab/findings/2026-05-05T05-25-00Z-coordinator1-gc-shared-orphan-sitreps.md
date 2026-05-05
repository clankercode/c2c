# GC Detection Gap: Shared Orphan Sitrep Commits

- **Discovered**: 2026-05-05 05:25 UTC
- **Agent**: coordinator1
- **Severity**: high (blocks all worktree cleanup)
- **Status**: fix in progress (2 slices dispatched)

## Symptom

`c2c worktree gc --verbose` classifies 595/596 worktrees as REFUSE
(0 REMOVABLE). The verbose output shows the same ~10 sitrep commit
SHAs appearing across 54 worktrees each.

## Root cause

Sitrep commits were committed to local master. Worktrees branched
from that local master, inheriting those SHAs. The sitreps never
made it to origin/master (or were rebased away). Now every worktree
that inherited them has "unmerged" commits that git-cherry doesn't
find on origin/master.

## Evidence

```
$ grep "^    + " /tmp/gc-verbose-output.txt | awk '{print $2}' | sort | uniq -c | sort -rn | head -5
     54 f9244c1f   # sitrep: 18 UTC
     54 94bded9c   # sitrep: 17 UTC
     54 741e988d   # sitrep: 19 UTC
     54 3d93013b   # sitrep: 16 UTC
     54 3a096bcb   # sitrep: 20 UTC
```

All are sitrep commits from April 27, appearing identically in 54 worktrees.

## Fix

Two complementary GC detection layers dispatched:
1. **Shared-orphan dedup** (cedar): SHA appearing in >5 worktrees = shared orphan
2. **Meta-path filter** (jungle): commits only touching .sitreps/ etc = meta-only

Combined should reclassify 200+ worktrees from REFUSE → REMOVABLE.

## Prevention

Stanza designing workflow improvement per Max's request: mandatory
pre-removal commit check + guidance to avoid committing sitreps
inside worktrees (or auto-cherry-pick them out before GC).
