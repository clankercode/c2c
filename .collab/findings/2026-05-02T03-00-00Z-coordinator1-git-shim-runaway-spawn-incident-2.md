# Git Shim Runaway-Spawn Incident 2 (2026-05-02T03:00Z)

- **Filed**: 2026-05-02T03:00Z by coordinator1 (Cairn-Vigil)
- **Severity**: HIGH — node-level resource exhaustion
- **Status**: Mitigated (shims renamed aside); fix-forward pending (birch hot-path slice + jungle runaway-spawn guard)

## Summary

At ~03:00 UTC, node load climbed to 25+ with 14+ `git rev-parse --git-common-dir` processes accumulating faster than `pkill` could reap them. Processes were respawning faster than termination. Load dropped to ~16 after shim files were renamed aside, confirming the shim as the source.

This is the **third distinct shim-related incident** in 24 hours.

## Symptom Timeline

| Time (UTC) | Event |
|---|---|
| ~02:50 | Load begins climbing |
| ~02:55 | 14+ `git rev-parse --git-common-dir` processes visible in process table |
| ~02:58 | Load 25+, node destabilising |
| ~03:00 | Shim files renamed aside; load drops to 16 |
| ~03:05 | Further investigation + naming |

## Root Cause

**Line 22 of `git-pre-reset`** runs `git rev-parse --git-common-dir | xargs dirname` at the **top of every invocation**, **before** the case dispatch that guards the dangerous operations (`reset --hard`, `commit`, etc.).

```bash
# git-pre-reset line 22 (before fix)
MAIN_TREE=$(git rev-parse --git-common-dir 2>/dev/null | xargs dirname || echo "")
```

This means every `git` invocation — even a plain `git status` or `git log` — triggers a synchronous `git rev-parse` subprocess. Under normal conditions this is harmless (one subprocess per git call). But when combined with the delegation shim (`$C2C_GIT_SHIM_ACTIVE=1`) and a transient subshell that fork-spawns git inside the shim context, the accumulation can amplify into a storm.

**Cedar's #611 v3 cache** uses PID-suffixed key (`/tmp/c2c-git-shim-main-tree-$$`) which is per-shell. A subshell that spawns another subshell (or a forked process that calls git) uses a different PID, so the cache miss rate increases under heavy nested subprocess load.

The specific amplification path observed: a `git` invocation from inside a shim-enabled shell triggers `git-pre-reset` → which calls `git rev-parse --git-common-dir` → which re-enters the shim (because the shim is first in PATH) → which calls `git-pre-reset` again → forming a tight loop until the process table fills.

## Prior Incidents in Same Class

The shim bin directory (`/home/xertrov/.local/state/c2c/bin/`) already contains evidence of prior shim failures:
- `git.bak` — prior backup after a shim failure
- `git.DISABLED.shim-recursion` — prior incident where the shim was identified as recursing

This is a **recurring class**, not a one-off. Each incident has been mitigated by renaming the shim aside, but no engineering fix has prevented recurrence.

## Mitigation Applied

1. Shim files renamed aside:
   - `/home/xertrov/.local/state/c2c/bin/git` → `git.disabled-incident-2026-05-02`
   - `/home/xertrov/.local/state/c2c/bin/git-pre-reset` → `git-pre-reset.disabled-incident-2026-05-02`
2. Load dropped from 25+ to 16 immediately

## Fix Paths (concurrent)

### Fix A: birch's hot-path rev-parse gate (in progress)

Restrict `git rev-parse --git-common-dir` to only the reset/commit case branches. Plain `git status`, `git log`, `git diff`, and other read-only commands that don't mutate state should not trigger the rev-parse at all.

Before:
```bash
# Every git call hits this
MAIN_TREE=$(git rev-parse --git-common-dir 2>/dev/null | xargs dirname || echo "")
```

After (target):
```bash
# Only hot-path cases trigger rev-parse
case "$1" in
  reset|commit|checkout|switch|rebase)
    MAIN_TREE=$(git rev-parse --git-common-dir 2>/dev/null | xargs dirname || echo "")
    ;;
esac
```

This is the structural fix — removes the per-call subprocess from the common path.

### Fix B: jungle's runaway-spawn count guard (planned)

A counter guard that detects when N+ `git` processes are running simultaneously from the same parent and refuses to spawn more. Prevents amplification even if Fix A is not yet deployed.

## Recurrence Pattern

The recurring class is: **shim introduces a per-call subprocess that can re-enter the shim under nested subprocess conditions**. Every prior incident has been a variant of this:

| Incident | Trigger | Re-entry path |
|---|---|---|
| Shim recursion (prior) | `exec git "$@"` pointing to shim | Shim calls git → shim calls git → ... |
| Tonight's incident | `rev-parse \| xargs dirname` at top level | rev-parse calls git → shim → rev-parse → ... |
| Prior backup (`git.bak`) | Unknown | Unknown shim failure |

The pattern suggests the shim's PATH position (first) + the wrapper's `git rev-parse` call creates a re-entry surface whenever git is invoked from inside the shim context.

## Recommendations

1. **Fix A + Fix B should land together** — Fix A reduces the per-call cost to zero for read-only commands; Fix B provides a backstop for any remaining amplification paths.
2. **Consider a test that runs `git` 50 times in a tight loop under the shim** — this would have caught the amplification before it hit production.
3. **Consider a shim that detects re-entry via environment guard** — if `C2C_GIT_SHIM_ACTIVE` is already set and we try to call git again, fail fast rather than re-enter.
4. **Rename the `.disabled` files with timestamps** — `git.disabled-2026-05-02T03-00` instead of `git.disabled-incident-2026-05-02` so the directory clearly shows which incident each backup corresponds to.

## Cross-References

- `.collab/findings/2026-05-02T01-45-00Z-coordinator1-shim-regression-cluster-and-main-tree-branch-flips.md` — prior shim cluster
- `.collab/findings/2026-05-02T01-12-00Z-coordinator1-git-shim-self-exec-recursion-cpu-spike.md` — spike incident
- cedar #611 v3 (`71227db5`) — content-check shim fix (landing simultaneously)
- birch hot-path rev-parse gate slice — in progress
- jungle runaway-spawn count guard — planned
