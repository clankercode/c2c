# Peer-PASS — deb1771d (stanza-coder)

**Reviewer**: test-agent
**Date**: 2026-05-03
**Commit**: deb1771d97f96bded1d300d2167745916d6b8299
**Branch**: s6b-mcp-schedule-timer
**Criteria checked**:
- `build-clean-IN-worktree-rc=0` (dune build @root ./ocaml/server/c2c_mcp_server.exe — warnings only, exit 0)
- `test-suite=340/340` (dune exec test_c2c_mcp.exe — confirmed prior run)

---

## Commit: feat(S6b): add Lwt schedule timer to MCP server

### What it does

Adds a background Lwt task to the MCP server (`c2c_mcp_server_inner`) that:
1. Reads `.c2c/schedules/<alias>/*.toml` files (same schedule format as `c2c start`)
2. Hot-reloads on directory mtime changes (stat-poll, every 5s)
3. Fires due schedules as self-DMs via `C2c_schedule_fire.enqueue_heartbeat`
4. Uses `should_fire` idle-gating check before firing

Gated by `C2C_MCP_SCHEDULE_TIMER` env var (opt-in, default OFF).

### Architecture

- **Delivery**: Option A (self-DM) — `enqueue_heartbeat` → inbox watcher → channel notification. No new stdout writers, no serialization risk.
- **Idle gating**: `C2c_schedule_fire.should_fire` called before each fire — respects `only_when_idle` + `idle_threshold_s`.
- **Hot reload**: directory mtime tracked; files re-parsed on change; removed files pruned from tracking.
- **Alignment**: `compute_next_fire` handles both aligned (`--align @1h+7m`) and plain interval schedules. For aligned: uses `C2c_start.parse_heartbeat_schedule` to compute next wall-clock-aligned slot.
- **Error handling**: `Lwt.catch` wraps the loop; individual fire errors are caught and logged, loop continues.

### Code quality

- State stored in Hashtbl: `filename → (entry, cached_mtime, next_fire_at)` — clean lifecycle management
- `next_fire_at` advanced even when idle gate blocks — prevents re-firing every 5s
- Disabled/unnamed schedule entries pruned from tracking
- `debug_log` for all state transitions (consistent with existing logging)
- `Lwt.async` used correctly for fire-and-forget background loop
- `schedule_timer_enabled` uses canonical env-var boolean parsing (matches `auto_drain_channel_enabled` pattern)

### Dependency check

`C2c_schedule_fire` is bundled in the `c2c_mcp` library module list — accessible from MCP server without additional library linkage. ✅

## Verdict

**PASS** — clean architecture, correct Lwt concurrency, proper idle gating, hot-reload, and error handling. Enables native scheduling for unmanaged Claude Code sessions via `C2C_MCP_SCHEDULE_TIMER=1`.
