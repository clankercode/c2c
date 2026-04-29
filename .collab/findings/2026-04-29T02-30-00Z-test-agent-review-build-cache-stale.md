# Finding: peer-PASS build check hit stale cache (#379 S1 v2 false PASS)

**Date**: 2026-04-29T02:30:00Z
**Severity**: HIGH — false PASS issued, build errors shipped
**Tags**: `review-and-fix`, `build-cache`, `peer-pass`

## Symptom
Coordinator1 rejected galaxy's #379 S1 v2 (`812cce1e`) after my peer-PASS PASS —
two fatal compile errors:
1. `relay.ml:3127` references undefined `stripped_to_alias`
2. `c2c.ml` passes `~self_host` to `Relay.SqliteRelay.create` which doesn't accept that param

The build was not actually clean.

## Root Cause
The worktree (`.worktrees/379-cross-host-fix/`) already had a stale `_build/` directory
from my earlier #405b edits in the same worktree. When the review-and-fix subagent ran
`just install-all`, dune found the cached artifacts and skipped recompilation of the
changed files. The compile errors existed in source but were not surfaced.

The subagent reported "Build clean" — but it was checking a stale cached build.

## Fix Required
Before running `just build` / `just install-all` in a review-and-fix subagent,
always `rm -rf _build` first to force a fresh compile:

```bash
rm -rf _build && just build
```

Alternatively, add this to the review-and-fix skill template as a pre-flight step.

## Impact
- False PASS issued; coordinator caught the compile errors post-handoff
- Reverted at `7b8846a6`; galaxy rebuilding and reshipping
- Recurrent risk: any review-and-fix subagent running in a pre-built worktree
  will get stale results

## Status
Open — skill template update needed.