# Design: MCP-server-side schedule timer (S6)

**Author**: stanza-coder
**Date**: 2026-05-02T09:40Z
**Status**: SKETCH — awaiting coordinator review
**Relates to**: S1-S5 (native scheduling), heartbeat binary fallback

## Problem

Native scheduling (S1-S5) only fires when `c2c start <client>` launches
the session — the timer thread lives in the `c2c start` process. Claude
Code sessions launched raw (e.g. coordinator1 in tmux, any `claude`
invocation without `c2c start`) never get the timer thread, so they fall
back to the external `heartbeat` binary via Monitor.

The fallback works, but it requires:
1. Agent role files to carry Monitor-arming recipes
2. Agents to correctly arm on startup (dedupe, persistent flag, etc.)
3. The `heartbeat` Rust binary to be installed
4. Monitor tool to be available (not all harnesses expose it)

If the MCP server itself could read schedules and self-deliver, every
Claude Code session with c2c MCP configured would get native scheduling
automatically — zero agent-side setup.

## Architecture analysis

### What exists today

1. **`c2c start` timer thread** (`c2c_start.ml:416-436`):
   - `Thread.create` with `Unix.sleepf` loop
   - Checks idle via `should_fire_heartbeat` (broker last_activity_ts)
   - Fires via `enqueue_heartbeat` → `Broker.enqueue_message` (self-DM)
   - Hot-reload: separate watcher thread reads `.c2c/schedules/<alias>/`
     every 10s, diffs, starts/stops heartbeat threads

2. **MCP server inbox watcher** (`c2c_mcp_server_inner.ml:143-202`):
   - Lwt async loop, `Lwt_unix.sleep 1.0` poll
   - Watches inbox file size changes
   - Drains + emits via `emit_notification` → `write_message` → stdout
   - Only fires when `Claude_channel` capability negotiated
   - Already runs as a background Lwt task alongside the main RPC loop

3. **Channel notification** (`c2c_mcp_helpers_post_broker.ml:331-357`):
   - Formats `notifications/claude/channel` JSON-RPC notification
   - Written to stdout via `write_message` (Lwt_io)

### Delivery paths for a schedule tick

Two options for how the timer delivers:

**Option A: Self-DM (reuse existing inbox path)**

Timer fires → `Broker.enqueue_message ~from_alias:alias ~to_alias:alias`
→ inbox watcher detects size change → drains → emits channel notification.

- Pro: Zero new stdout-writing code. Leverages existing inbox watcher.
- Pro: Works regardless of `Claude_channel` capability — message sits in
  inbox until `poll_inbox` drains it.
- Pro: Identical to how `c2c start` heartbeats work today.
- Con: Extra hop (write inbox file → stat-poll detects → drain → emit).
  Adds ~1-2s latency from the inbox watcher poll interval. Acceptable
  for a 4.1m heartbeat.

**Option B: Direct channel notification**

Timer fires → `write_message (channel_notification ...)` directly to stdout.

- Pro: No inbox hop, immediate delivery.
- Con: Needs `Claude_channel` capability check (or message is lost).
- Con: Bypasses inbox — `poll_inbox` won't see it; no archive trace.
- Con: Stdout write from a background Lwt task needs careful
  serialization with the main RPC response writer (Lwt_io is not
  thread-safe across concurrent fibers without a mutex/sequencer).
  The inbox watcher already does this via `write_message`, so the
  pattern exists, but adding a second concurrent writer increases
  the interleave risk.

**Recommendation: Option A (self-DM).** Simpler, safer, works for all
clients (channel-capable or not). The 1-2s latency is irrelevant for
heartbeat-cadence wakes.

### Where the timer thread lives

The MCP server process (`c2c_mcp_server_inner.ml`) already spawns Lwt
background tasks (inbox watcher, nudge scheduler). Adding a schedule
timer is the same pattern:

```ocaml
(* In the initialize handler, after inbox watcher starts: *)
let _schedule_timer = start_schedule_timer
  ~broker_root ~alias ~session_id in
```

The timer function:

```ocaml
let start_schedule_timer ~broker_root ~alias ~session_id =
  let schedules_dir = C2c_mcp.schedule_base_dir alias in
  (* Reuse the hot-reload pattern from c2c_start.ml:
     stat-poll the dir every 10s, parse TOML files,
     maintain a table of {next_fire_at, schedule_entry}.
     On each 5s tick, check if any schedule is due.
     If due + idle check passes → enqueue self-DM. *)
  let rec loop () =
    let* () = Lwt_unix.sleep 5.0 in
    (* ... reload schedules if dir mtime changed ... *)
    (* ... check each enabled schedule against clock ... *)
    (* ... fire due schedules via Broker.enqueue_message ... *)
    loop ()
  in
  Lwt.async (fun () -> loop ())
```

### Idle check

The `should_fire_heartbeat` logic in `c2c_start.ml` checks
`Broker.last_activity_ts` for the alias. The MCP server has direct
broker access — same check works. For `only_when_idle` schedules,
compare `last_activity_ts` against `idle_threshold_s`.

### What about non-Claude-Code MCP clients?

The timer uses self-DM (Option A), so it works for ANY MCP client —
channel-capable or not. Non-channel clients get the message on next
`poll_inbox`. This means Codex/OpenCode MCP sessions would also
benefit if they run `c2c-mcp-server` directly.

### Alias discovery

The MCP server knows its alias from the session registration
(`C2C_MCP_AUTO_REGISTER_ALIAS` env var, resolved during initialize).
Same alias used for schedule path resolution.

## Scope

### What changes

1. **New Lwt background task** in `c2c_mcp_server_inner.ml`:
   `start_schedule_timer` — reads `.c2c/schedules/<alias>/`, stat-polls
   for hot-reload, fires due schedules as self-DMs.

2. **Extract shared logic** from `c2c_start.ml`:
   - `should_fire_heartbeat` / `agent_is_idle` — move to `c2c_mcp.ml`
     or a shared module (already partially there via `schedule_base_dir`
     / `parse_schedule`).
   - `enqueue_heartbeat` — trivial wrapper around `Broker.enqueue_message`.

3. **Dedup with `c2c start`**: When `c2c start` launches the MCP server
   as a child, both would have timers. Options:
   - `c2c start` detects MCP-server-has-timer via env var
     (`C2C_MCP_SCHEDULE_TIMER=1`) and skips its own timer thread.
   - OR: `c2c start` always runs its timer, MCP server only runs timer
     when `C2C_MCP_SCHEDULE_TIMER_ENABLED=1` (opt-in). Safer default.
   - Recommendation: opt-in for now (`C2C_MCP_SCHEDULE_TIMER=1`),
     then `c2c start` can set it automatically when it knows MCP is the
     child process.

4. **Docs**: Update `.collab/runbooks/agent-wake-setup.md` to add a
   fourth option ("MCP-server-side scheduling").

### What doesn't change

- Schedule file format (TOML, `.c2c/schedules/<alias>/`)
- `c2c schedule set/list/rm` CLI + MCP tools
- `c2c start` timer thread (still works for non-MCP sessions)
- `heartbeat` binary (still works as fallback for any session)

## Tradeoffs

| | MCP timer | heartbeat binary | c2c start timer |
|---|---|---|---|
| **Works without `c2c start`** | Yes | Yes (with Monitor) | No |
| **Works without Monitor tool** | Yes | No | Yes |
| **Works without MCP** | No | Yes | Yes |
| **Zero agent setup** | Yes | No (arm Monitor) | Yes |
| **Idle-aware** | Yes | Yes | Yes |
| **Hot-reload** | Yes | No (restart binary) | Yes |

## Verdict

**Worth it.** The MCP server timer covers the gap for raw Claude Code
sessions (the most common non-`c2c start` case) with minimal new code
(~80 lines, mostly extracted from c2c_start.ml). The heartbeat binary
remains as a fallback for non-MCP sessions (tmux-only, shell scripts).

The main risk is dedup with `c2c start` — solved cleanly with an env
var gate. The self-DM delivery path is battle-tested (same as all
existing heartbeats).

## Slicing suggestion

- **S6a**: Extract `should_fire_heartbeat` + idle helpers to shared module
- **S6b**: `start_schedule_timer` Lwt task in MCP server, gated by env var
- **S6c**: `c2c start` sets the env var when launching MCP child, skips
  own timer when MCP handles it
- **S6d**: Docs update (runbook, CLAUDE.md)
