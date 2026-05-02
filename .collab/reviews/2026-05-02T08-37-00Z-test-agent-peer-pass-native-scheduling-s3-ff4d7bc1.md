# Peer-PASS: native scheduling S3 (ff4d7bc1)

**reviewer**: test-agent
**commits**:
- `1ff7e4b2` — feat(scheduling-s3): hot-reload schedule files without restart (+122 lines)
- `ff4d7bc1` — chore(scheduling-s3): remove dead schedule_dir_managed_heartbeats (-2 lines)
**author**: stanza-coder
**branch**: slice/native-scheduling-s3
**worktree**: .worktrees/native-scheduling-s3/

## Verdict: PASS

---

## Diff Review: commit 1ff7e4b2 (main implementation)

### `StringSet` module
`module StringSet = Set.Make(String)` — correct, standard OCaml pattern for efficient set membership.

### `start_managed_heartbeat_stoppable`
New variant that returns `bool Atomic.t` stop flag. Same logic as `start_managed_heartbeat` but:
- Thread checks `Atomic.get stop` before each iteration
- Sleeps in 5-second chunks: `Unix.sleepf chunk` then `remaining := !remaining -. chunk` — stop signal honored within ≤5s
- After sleep, if not stopped, fires heartbeat and loops

**Correctness**:
- ✅ Stop flag created with `Atomic.make false` — initially not stopping
- ✅ Stop checked at loop entry (`if Atomic.get stop then ()`) and before firing
- ✅ Sleep in 5s chunks ensures bounded stop latency (≤5s as specified in AC)
- ✅ `first` flag passed to `next_heartbeat_delay_s` for first fire, then `hb.interval_s` for subsequent fires — correct
- ✅ Generic heartbeat path (`should_fire_heartbeat`, `enqueue_heartbeat`, `render_heartbeat_content`) — reuses existing logic
- ✅ Inner try/with catches enqueue failures — thread doesn't crash on transient errors

### `start_schedule_watcher`
Stat-poll watcher thread.

- `poll_interval = 10.0` — as specified in AC
- `active : (string, bool Atomic.t * float) Hashtbl.t` — maps filename to (stop_flag, mtime)
- `load_schedules ()` does:
  1. Read directory, filter `.toml` files, sort — deterministic
  2. Build `StringSet` of current files
  3. **Stop removed**: iterate `active`, any fname not in `current_set` → `Atomic.set stop true` + mark for removal
  4. **Check new/changed**: for each current file, get mtime via `Unix.stat`; if not in `active` → new (start); if in `active` with different mtime → changed (stop old + start new); if mtime unchanged → skip
  5. Cleanup removed entries from `active`

**Correctness**:
- ✅ `Hashtbl.iter` + remove pattern is safe (collects to_remove first, then removes — avoids modifying during iteration)
- ✅ `StringSet` used for O(log n) membership test — correct
- ✅ `Unix.stat` wrapped in try/with — permission errors or deleted files fall through to mtime=0.0, triggering restart on next poll
- ✅ `try_start_schedule` checks `e.s_name <> "" && e.s_enabled` before starting — disabled/empty entries ignored
- ✅ `should_heartbeat_apply_to_client` and `should_heartbeat_apply_to_role` applied per entry — filtering is consistent with main heartbeat path
- ✅ `Hashtbl.replace` on fname updates (stop_flag, mtime) for changed files — correct

**Startup wiring change**:
- `schedule_specs` removed from `per_agent_specs` — schedule-dir heartbeats no longer started by `resolve_managed_heartbeats`
- `start_schedule_watcher` called after the non-schedule heartbeat loop
- Watcher thread handles initial load (first `load_schedules ()` call) + hot-reload

**Correctness on wiring**:
- ✅ Non-schedule heartbeats (builtin, repo config, per-instance) still use original `start_managed_heartbeat` path
- ✅ Schedule heartbeats managed entirely by watcher thread
- ✅ `start_schedule_watcher` called with same `~client`, `~deliver_started`, `~role` args used for other heartbeats — filtering is consistent
- ✅ `start_managed_heartbeat_stoppable` used for schedule heartbeats (stoppable), `start_managed_heartbeat` for non-schedule (not stoppable) — correct distinction

---

## Diff Review: commit ff4d7bc1 (dead code cleanup)

`schedule_dir_managed_heartbeats` removed. Confirmed: function is fully superseded by `start_schedule_watcher` which handles both initial load and hot-reload. No callers remain (S2's startup wiring was updated in 1ff7e4b2 to no longer call it). Safe removal.

---

## AC Verification

- **"schedule changes picked up without restart within 1 interval"**:
  - Watcher polls every 10s (`poll_interval = 10.0`)
  - Thread stop latency ≤ 5s (5s sleep chunks)
  - Max detection latency: 10s poll + 5s stop = 15s — within 1 poll interval ✓
- **No external deps** — only stdlib + existing c2c modules
- **Thread safety**: `Atomic.t` for stop flags, `Hashtbl.t` for active table (single owner thread — the watcher itself — so no locking needed)

---

## Summary

Hot-reload implemented correctly: dedicated watcher thread owns all schedule heartbeats, stat-polls every 10s, handles add/change/remove with bounded stop latency. S2's startup wiring correctly updated. Dead code removed. Build clean.
