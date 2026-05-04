# Finding: git-pre-reset missing from PATH — critical (2026-05-02T03:20:00Z)

## Severity
CRITICAL — blocks all git operations through the c2c git shim

## Summary
The `git-pre-reset` binary has been disabled/renamed but no replacement exists.
All git operations through the c2c shim (`/home/xertrov/.local/state/c2c/bin/git`) fail with:
```
/home/xertrov/.local/state/c2c/bin/git: line 10: exec: git-pre-reset: not found
```

## Discovery
- PATH prepends `/home/xertrov/.local/state/c2c/bin` which contains the git shim
- The shim (`/home/xertrov/.local/state/c2c/bin/git`) calls `exec git-pre-reset "$@"` at line 10
- `git-pre-reset` is NOT on PATH — only these exist in that directory:
  - `git` (shim, broken)
  - `git.bak` (backup)
  - `git.disabled-incident-2026-05-02` (disabled shim)
  - `git.DISABLED.shim-recursion` (another disabled shim)
  - `git-pre-reset.disabled-incident-2026-05-02` (DISABLED pre-reset guard)

## Root Cause
The pre-reset guard was renamed to `git-pre-reset.disabled-incident-2026-05-02`
during the incident-2 recovery (2026-05-02), but was not restored or replaced with
a working version. The shim delegation path is now broken.

## Impact
- All `git` commands through the shim fail in my session (willow-coder)
- Likely affects all agents using the c2c shim on this machine
- Blocks any slice work that requires git operations (commit, log, diff, etc.)
- Worktrees may be in an inconsistent state if operations were attempted

## Workaround
Use system git directly: `/usr/bin/git <args>`

## Fix Required
Restore or recreate `git-pre-reset` in `/home/xertrov/.local/state/c2c/bin/`

## Related
- Incident 1 (2026-05-02T03:00 UTC): git-shim runaway spawn — `git-pre-reset` disabled
- Incident 2 (same): recursive shim invocation — `git.DISABLED.shim-recursion` created
- Finding: `.collab/findings/2026-05-02T03-00-00Z-coordinator1-git-shim-runaway-spawn-incident-2.md`

## Status
**RESOLVED** — coordinator1 restored the shim at ~03:20 UTC by overwriting with birch's fixed version from `git-shim.sh` (SHA `4602f973` cherry-pick), which removed the top-level rev-parse hot-path. Shim verified working.
