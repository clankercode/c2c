# Phase 2A: Git-spawn Circuit Breaker

## Problem
Runaway `git rev-parse` / `git config` / etc. invocations can wedge a node
(load 1600–8000, thousands of R-state processes). Once N processes pile up
on `.git/` locks, all git ops stall and zombify.

## Solution
A process-level circuit-breaker around git invocations:
- Track git spawns with a sliding window (timestamps array)
- If rate exceeds threshold (5/sec sustained over 3s), trip
- On trip: log to broker.log, sleep/backoff, then refuse with error
- Single chokepoint via `git_first_line` / `git_all_lines` wrappers

## Design

### Chokepoint
All git invocations go through `Git_helpers.git_first_line` or `Git_helpers.git_all_lines`.
These are the ONLY entry points; no caller spawns git directly.

### Counter struct
```ocaml
type git_spawn_counter = {
  mutable events : float list;  (* timestamps of recent git spawns *)
  mutable tripped : bool;       (* circuit is open *)
  mutable trip_epoch : float;  (* when it tripped *)
}
let counter : git_spawn_counter = {
  events = [];
  tripped = false;
  trip_epoch = 0.0;
}
```

### Thresholds
- **window**: 3.0 seconds
- **max_spawns**: 5 (per window)
- **backoff**: 2.0 seconds after trip
- **env overrides**: `C2C_GIT_SPAWN_WINDOW`, `C2C_GIT_SPAWN_MAX`, `C2C_GIT_BACKOFF_SEC`

### Behavior
1. `git_first_line` / `git_all_lines` call `check_and_record_git_spawn ()`
2. `check_and_record_git_spawn`:
   - If `tripped && (now - trip_epoch) < backoff`: raise `Git_spawn_throttled`
   - Prune events older than window
   - If `List.length events >= max_spawns`: trip, log, raise
   - Else: record this spawn, return
3. On throttle: log to broker.log (once per trip epoch), return error result

### Backward compatibility
- Existing callers of `git_first_line` / `git_all_lines` that pattern-match on `None`
  continue to work (throttle returns `None`/`[]`, same as git not available)
- No callers currently check for throttle-specific errors

## Files changed
- `ocaml/Git_helpers.ml` — add counter + throttle logic
- `ocaml/Git_helpers.mli` (new) — interface for Git_helpers

## Tests
- Synthetic spawn-storm fixture: rapid git calls verify trip + backoff
- Normal-rate calls verify no throttle
- Env var override verification
