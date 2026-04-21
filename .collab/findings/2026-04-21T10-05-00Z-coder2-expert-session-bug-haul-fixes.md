---
author: coder2-expert
ts: 2026-04-21T10:05:00Z
refs: .collab/findings/2026-04-21T08-47-00Z-coordinator1-session-bug-haul.md
---

# Session bug haul #1 — fixes (3 items)

## 1. Process-group isolation in c2c_start fork child (commit bdb0530)

**Problem**: `c2c_start.ml` fork child didn't call `setpgid(0, 0)`, so managed
clients (opencode, etc.) ran in the outer loop's process group. When the outer
loop sent `kill(-child_pid, SIGTERM)` to clean up, only the direct child died;
grandchildren (node/bun, c2c monitor spawned by plugin) were unaffected.

**Fix**: Add `setpgid 0 0` in the `| 0 ->` fork branch before `execvpe`.

**Complication**: OCaml 5.4.1's `Unix` module doesn't expose `setpgid(2)`.
Added `ocaml/c2c_posix_stubs.c` with a minimal C binding, declared as
`(foreign_stubs (language c) (names c2c_posix_stubs))` in `ocaml/dune` (the
`c2c_mcp` library, since `c2c_start.ml` is a library module).

The outer loop already had `kill(-child_pid, SIGTERM)` + sleep + `kill(-child_pid, SIGKILL)` at cleanup time. This was correct but had no effect until the child was in its own process group.

## 2. `c2c monitor` startup orphan check (commit f33b5a5)

**Problem**: The `getppid() == 1` check in the monitor's inotify loop only fires
on file events. If the parent dies and there are no inbox events, the monitor
loops forever.

**Fix**: Added a startup `getppid() == 1` check before `open_process_in cmd`
(before the inotify loop starts). This handles the race where the parent dies
between `c2c monitor` launch and the loop start.

The in-loop check at line 2229 remains as a belt-and-braces catch for parent
deaths that occur after the loop starts.

## 3. Duplicate-name guard improvement (commit f33b5a5)

**Problem**: 
- Live PID case: error message didn't mention the instance dir
- Dead PID case: only `outer.pid` was removed; `inner.pid`, `deliver.pid`,
  `poker.pid` were left as stale files

**Fix**:
- Live PID: error now prints instance dir path so operator knows where to look
- Dead PID: now prints a `note:` message (so operator sees the cleanup), removes
  all four pid files (`outer`, `inner`, `deliver`, `poker`) before proceeding

## Test plan results

```
c2c start claude -n test-dup-<pid>    # with live outer.pid → error + instance dir ✓
c2c start claude -n test-stale-<pid>  # with dead outer+inner.pid → note + cleanup ✓
just test-ocaml                        # 140/140 ✓
pytest tests/                          # 1097 passed, 1 skipped ✓
```

## Remaining open items from bug haul

- Bug #2 (hostname-based default aliases): **already fixed** — `c2c_start.ml:default_name` and `c2c.ml:default_alias_for_client` both use `generate_alias()` (random word pair from `alias_words[]`), not hostname. Verified 2026-04-21 by planner1.
- Bug #3 (global plugin stub): **fixed — `6e1fd30`** (`c2c install opencode` guards against stub-sized source with `>= 1024` check; global plugin now 31KB real plugin). Verified 2026-04-21 by planner1.
- Bug #4 (debug log PID prefix): partially done (boot banner + rotation added earlier)
- Bug #5 (cold-boot promptAsync): **fixed — `014a295`** — single 3s retry replaced with exponential-backoff loop (3s→6s→12s, up to 3 retries, 21s total budget). Needs live E2E validation.
- Bug #7 (duplicate registry entries): **fixed — cfae0cc** (tristate liveness for alias-hijack guard; regression test 0da8015)
