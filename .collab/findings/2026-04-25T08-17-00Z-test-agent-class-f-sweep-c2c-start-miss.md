# Class F: Sweep drops `c2c start` managed sessions

**Author**: test-agent
**Date**: 2026-04-25
**Status**: Root cause identified — fix designed

## Root Cause

The `sweep` command in `c2c.ml:740` checks for old-style outer loops only:
```ocaml
let outer_loops_running =
  Sys.command "pgrep -c -f 'run-(kimi|codex|opencode|crush|claude)-inst-outer' > /dev/null 2>&1" = 0
```

This misses `c2c start` managed sessions (the current preferred path). As a result, `c2c start` sessions are silently swept when their PID becomes stale — even though the outer loop (`c2c start`) would relaunch the inner client on the next tick if the operator ran the printed resume command.

## Why This Is Structural

The sweep guard exists to prevent dropping live sessions. It guards against old-style outer loops (`run-*-inst-outer`) which DO auto-restart. But `c2c start` sessions are NOT guarded — and they DO have a restart path (operator re-runs `c2c start`). So sweep drops them as "dead" even though they're recoverable.

## The Fix

`c2c start` writes `<instances_dir>/<name>/config.json` with the `session_id` field. This is the canonical source of truth for which sessions are managed by `c2c start`.

**Approach**: teach `sweep` to treat `c2c start`-managed sessions as alive by reading their session_ids from `instances_dir/config.json` files.

1. Add a helper `read_c2c_start_session_ids () : string list` that:
   - Reads all `instances_dir/*/config.json`
   - Extracts the `session_id` field from each
2. In the sweep guard, after the existing pgrep check, also read c2c_start session_ids
3. In `sweep`'s `registration_is_alive` partition: a registration is also considered "alive" if its session_id is in the c2c_start session_id set
4. The existing outer-loop warning remains for `run-*-inst-outer` style loops

**Key invariant preserved**: sweep still correctly drops truly dead sessions (no c2c start, no outer loop). It just stops dropping the recoverable `c2c start` managed ones.

## Files to Change

- `ocaml/cli/c2c.ml` — `sweep_cmd` and/or the `sweep` tool in `c2c_mcp.ml`

## Scope

~20-30 LOC. No wire format change. Backward-compatible.

## Related

- `c2c instances` already reads `instances_dir` to list managed instances — reuse that read logic
- `prune_rooms` already handles c2c_start sessions differently (room memberships, not registrations)
- The fix does NOT address `run-*-inst-outer` style loops — those are already guarded
