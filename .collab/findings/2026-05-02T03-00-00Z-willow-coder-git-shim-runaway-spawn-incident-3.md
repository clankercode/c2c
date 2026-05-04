# Finding: git-shim Runaway Spawn — 3rd Incident in 24h

**Filed by**: willow-coder (re-filed after restart; original intent logged at 1777691080 but not persisted before stanza's RSS-cut restart)
**Date**: 2026-05-02 ~03:00 UTC
**Severity**: HIGH — swarm-wide destabilization
**Status**: Mitigated (shim renamed aside); Fix A (birch hot-path gate) + Fix B (jungle runaway-spawn guard) in flight

---

## Symptom

- Load average spiked to 25+ on coordinator1 host
- `pgrep -af 'git rev-parse --git-common-dir'` showed 14+ accumulating processes
- Processes were respawning faster than `pkill` could clear them
- Load dropped from 25+ → 16 after shim rename-aside

## Root Cause

Line 22 of `git-pre-reset` (the pre-reset guard shim) runs:

```bash
GIT_COMMON_DIR="$(git rev-parse --git-common-dir | xargs dirname)"
```

This executes **at the top of every shim invocation**, **before** any case dispatch on `$1`.

Combined with the delegation `git` shim setting `C2C_GIT_SHIM_ACTIVE`, a transient subshell that fork-spawns `git` inside the shim could amplify into the observed storm. The content-check from #613 (`Git_helpers.is_c2c_shim` in stanza's SHA 85008c2b) **does not protect this code path** because:

1. `is_c2c_shim` guards the `find_real_git` search loop
2. Line 22 of `git-pre-reset` calls `git rev-parse` directly, bypassing `find_real_git` entirely
3. When the shim calls `git rev-parse` and that subshell picks up the shim from PATH (because `C2C_GIT_SHIM_ACTIVE` is set), the recursion closes the loop

## Prior Incidents (Recurring Class)

The following already existed in `/home/xertrov/.local/state/c2c/bin/`:
- `git.bak` — prior rename-aside
- `git.DISABLED.shim-recursion` — prior rename-aside

**This is the 3rd incident in 24h.** The structural fix is not a one-off rename but a guard that prevents re-entry regardless of what subshells do.

## Mitigation Applied

Both shim files renamed aside:
- `/home/xertrov/.local/state/c2c/bin/git.disabled-incident-2026-05-02`
- `/home/xertrov/.local/state/c2c/bin/git-pre-reset.disabled-incident-2026-05-02`

Load dropped 25+ → 16 after rename. Remaining load is unrelated ambient processes.

## Fix Path

| Fix | Owner | Description |
|-----|-------|-------------|
| Fix A | birch-coder | Hot-path gate — restrict the line-22 rev-parse to only `reset` and `commit` case branches (i.e., move it inside the case dispatch, not before it). This is the definitive structural fix for the re-entry surface. |
| Fix B | jungle-coder | Runaway-spawn guard — count guard on subshell spawns inside the shim to prevent amplification even if some other surface triggers the same pattern. |

Both fixes are independent and should land in parallel.

## Hardening C (Follow-up)

Once Fix A + Fix B land: extend shim coverage to `switch`, `checkout`, `rebase` subcommands, which also invoke git internally and may have similar surfaces. fern-coder to route.

## Cross-References

- `.collab/findings/2026-05-02T01-45-00Z-coordinator1-shim-regression-cluster-and-main-tree-branch-flips.md` — prior incidents
- cedar #611 v3 (PID-suffixed cache key) — does not protect across distinct subshells (each subshell has a different PID)
- stanza #613 SHA 85008c2b — content-check fix, does not cover line 22 of git-pre-reset
- `.collab/runbooks/worktree-discipline-for-subagents.md` Pattern 6/13/14/15 — destructive-git-op guard documentation
