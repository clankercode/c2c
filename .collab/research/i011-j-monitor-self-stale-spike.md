# SPIKE: monitor/heartbeat self-detect-stale -> self-exit + exact relaunch hint

**Task:** P2.M3.E1.T003 (J)  
**Author:** pi-3b6265-ade0415 (subagent)  
**Date:** 2026-07-20  
**Branch:** `task/p2-m3-e1-t003`  
**Worktree:** `.worktrees/p2-m3-e1-t003`

---

## Summary

GO — the feature is feasible with one pure-stale-pattern + one new CLI flag on `c2c monitor`.  
No production code in this SPIKE; only architecture analysis, precedents, and an implementation sketch.

---

## What "stale" means for monitor/heartbeat

The `c2c monitor` process is event-driven (inotify on broker files + optional relay-peek thread).  
"Stale" is not a single concept — three orthogonal signals are available:

| Signal | Mechanism | Precedent |
|--------|-----------|-----------|
| **Orphan** (parent died) | `Unix.getppid () = 1` | Already in `c2c_monitor_cmd.ml`; exits 0 |
| **Binary upgrade** | SHA256 of `/proc/<pid>/exe` vs installed binary (`c2c_stale.ml`) | `c2c restart-stale`; relay connector B228 stale-exit |
| **Configured idle timeout** | Wall-clock without any event surfaced | Not yet implemented |
| **Broker unreadable** | inotifywait EOF → already exits | `c2c_monitor_cmd.ml`; B246 fix |

The task's "heartbeat self-detect-stale" is most naturally anchored to **binary upgrade** (the running
monitor binary is different from the installed one) and **orphan** (parent shell died).

The heartbeat binary (external; referenced in role templates as `heartbeat 4.1m "..."`) is a separate
process that fires on an interval. Its staleness = same signals as above, plus a **wall-clock idle
timeout** (no inbox message seen for N seconds).

---

## Hard constraint: external respawn is FORBIDDEN

The opencode plugin (`opencode-c2c/c2c.ts`) spawns the monitor with:

```typescript
proc.on("close", () => {
  if (!monitorStopped) { setTimeout(spawnMonitor, 5000); }
});
proc.on("error", () => { if (!monitorStopped) { setTimeout(spawnMonitor, 10000); } });
```

This is the **forbidden pattern**: if the monitor exits cleanly (0), the plugin immediately respawns it,
which defeats any self-exit.  
The constraint means: monitor must not rely on external respawn. It must print the exact relaunch
command and exit 0 so the **operator** (or a supervisory layer that respects the hint) decides
whether to restart.

The `c2c restart` / `c2c restart-stale` path uses owner-control (files under `.c2c/instances/<name>/`)
which is self-restart via `execve`, not external respawn. This is acceptable.

---

## Existing staleness patterns (prior art)

### 1. Orphan detection (c2c_monitor_cmd.ml)

```ocaml
(* Belt-and-braces startup orphan check *)
(if Unix.getppid () = 1 then exit 0);

(* In the main event loop *)
(if Unix.getppid () = 1 then exit 0);
```

Already implemented. No changes needed.

### 2. Binary staleness (c2c_stale.ml)

```ocaml
(* Pure, unit-tested. Returns Current | Stale | Unknown of string. *)
val classify : installed_exe:string -> pid:int -> verdict

(* Dev+ino of a running binary's /proc/<pid>/exe. *)
val sha256_file : string -> string option
```

This is exactly the pattern needed. Used by `c2c restart-stale` for managed clients and the relay
connector B228 stale-exit.

### 3. Relay connector stale-exit (c2c_relay_connector.ml)

```ocaml
(* B228: exit 3 when no progress for max(180s, interval*6) *)
val stale_exit_threshold_s : interval:float -> float
val should_exit_stale : now:float -> last_progress:float -> threshold:float -> bool
(* Sync pass counts as progress: ok | rate-limited. Other errors do not reset timer. *)
```

The pattern: pure predicate → wall-clock timer → print actionable line → exit 3.  
Extensible to monitor: pure staleness check → periodic timer → print relaunch hint → exit 0.

### 4. inotifywait EOF (c2c_monitor_cmd.ml, B246)

```ocaml
(* EOF on inotifywait stdout = process died or not installed *)
with End_of_file ->
  Printf.eprintf "%s inotify watch stream ended; monitor exiting\n%!" (now_hms ())
```

Clean exit with diagnostic message. Already done.

---

## GO: implementation sketch (no production code in this SPIKE)

### New CLI flag on `c2c monitor`

```ocaml
let self_stale_exit =
  Arg.(value & flag & info ["self-stale-exit"]
         ~doc:"Exit with an exact relaunch command when staleness is detected, \
               rather than continuing. For supervised sessions: the supervisor \
               must NOT auto-respawn — exit 0 so the operator decides.")
```

### Architecture

1. **Pure staleness core** — lives in `c2c_monitor_logic.ml` or a new `c2c_monitor_stale.ml`:
   ```ocaml
   type stale_signal =
     | Orphan                   (* ppid = 1 *)
     | Binary_upgraded of {
         running: string;       (* sha256 of /proc/self/exe *)
         installed: string;     (* sha256 of installed c2c binary *)
       }
     | Idle_timeout of {
         last_event_ts: float;
         idle_timeout_s: float;
       }

   (* Reconstruct the exact relaunch command from current argv + resolved env. *)
   val reconstruct_monitor_command : unit -> string
   (* Pure predicate: is the monitor stale right now? *)
   val is_stale : signal:stale_signal -> now:float -> bool
   ```

2. **Staleness check loop** — new thread alongside the relay peek thread:
   - Check interval: configurable, default 60s
   - Check: orphan (fast path), then binary SHA (expensive, cached)
   - On stale: print relaunch hint to stderr + stdout as NDJSON event `monitor.stale-exit`
   - Exit 0: **clean** exit so supervisor (opencode plugin, etc.) sees exit 0

3. **Relaunch hint format**:
   ```
   [HH:MM:SS] c2c monitor: stale (binary upgraded: running=<hash> installed=<hash>)
   Relaunch with: c2c monitor --broker-root <path> --alias <alias> [--relay-interval N]
   Exiting cleanly (exit 0) — do not auto-respawn.
   ```

   NDJSON event:
   ```json
   {"event_type":"monitor.stale-exit","reason":"binary_upgraded","running_sha":"...","installed_sha":"...","relaunch_command":"c2c monitor ..."}
   ```

4. **Integration with opencode plugin**:
   - The opencode plugin's respawn loop is the forbidden external respawn
   - On exit 0 + `monitor.stale-exit` event: plugin must **not** respawn
   - On other exits (non-zero, or 0 without the event): respawn as before
   - Alternatively: add a flag `C2C_MONITOR_SELF_EXIT=1` that the plugin respects

---

## Invariants

1. **Exit code = 0 on self-stale-exit.** The monitor is not broken; it detected a legitimate
   staleness signal. Supervisor must not treat this as an error.

2. **Relaunch command is exact and reproducible.** Must include all resolved args
   (`--broker-root`, `--alias`, relay flags). The operator running the printed command
   must get identical behavior.

3. **Staleness is not false-positive on first run.** The stale-exit thread must wait at least
   one full check interval before emitting the signal. A monitor that starts stale because the
   binary was upgraded during startup must not immediately exit.

4. **Binary SHA comparison is cached.** `sha256_file /proc/<pid>/exe` is expensive (~23 MB binary).
   Cache result per-process lifetime (memoize on first check).

5. **No external respawn is triggered.** The opencode plugin respawn loop must be disabled when
   `monitor.stale-exit` is detected. This requires a coordination contract between monitor
   and plugin (env var `C2C_MONITOR_SELF_EXIT=1`, or NDJSON event detection).

6. **Orphan detection is always-on** (existing). The `--self-stale-exit` flag is additive to orphan.

7. **Idle timeout does not fire if events occurred recently.** The idle timer resets on every
   surfaced message. Only a sustained gap (no events for N seconds) triggers the exit.

---

## Follow-up if GO

**Production implementation plan:**

1. **Phase 1: Pure stale logic** — `ocaml/cli/c2c_monitor_stale.ml` + `.mli`
   - `stale_signal` type + `is_stale` pure predicate
   - `reconstruct_monitor_command` using `Sys.argv` + resolved env
   - Unit tests in `ocaml/test/test_c2c_monitor_stale.ml`

2. **Phase 2: CLI flag** — add `--self-stale-exit` to `c2c_monitor_cmd.ml`
   - New thread: staleness check loop (same pattern as relay peek thread)
   - On stale: emit `monitor.stale-exit` NDJSON event + print relaunch hint → `exit 0`

3. **Phase 3: OpenCode plugin integration** — `opencode-c2c/c2c.ts`
   - On monitor close: check if `monitor.stale-exit` event was emitted
   - If yes: log relaunch hint, do **not** respawn
   - If no: respawn as before

4. **Phase 4: Idle timeout** (optional extension)
   - Track `last_event_ts` in monitor state
   - Separate `idle_timeout_s` flag
   - Emit `monitor.idle-stale-exit` event

5. **Docs** — update `docs/monitor.md` with `--self-stale-exit` flag, staleness signals,
   and the coordination contract with supervising plugins.

---

## NO-GO triggers (not observed, but noted)

- If the monitor's argv is not reliably reconstructible (e.g. args come from a config file
  not reflected in argv): relaunch command would be approximate, not exact. **Not the case** —
  `c2c monitor` takes all relevant args as Cmdliner flags, all on argv.

- If the opencode plugin's respawn loop cannot be disabled from outside the plugin: the
  coordination contract must be explicit. **Workaround exists** — `C2C_MONITOR_SELF_EXIT=1` env
  var that the plugin checks before respawning.

---

## Verdict

**GO.** The existing codebase provides all necessary primitives:

- `c2c_stale.ml` for binary SHA comparison (pure, unit-tested)
- Orphan detection already in `c2c_monitor_cmd.ml`
- Relay connector stale-exit pattern (B228) as the exact precedent
- `c2c_monitor_logic.ml` as the pure home for staleness predicates
- No new external dependencies required

The hard constraint (no external respawn) is satisfied by:
1. Exiting 0 (so the opencode plugin respawn is clean but ineffective without an event)
2. Emitting a `monitor.stale-exit` NDJSON event that the plugin can detect to suppress respawn
3. Printing the exact relaunch command so the operator can restart manually

**Path:** `ocaml/cli/c2c_monitor_stale.ml` (new) + `c2c_monitor_cmd.ml` (flag + thread)  
**Estimated LOC:** ~200–300 lines OCaml + ~50 lines TypeScript plugin change  
**Risk:** Low — additive flag, pure predicates are unit-testable, event is backward-compatible
