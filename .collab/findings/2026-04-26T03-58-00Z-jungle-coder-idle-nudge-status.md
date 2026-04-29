# Findings: idle-nudge implementation status

**Date**: 2026-04-26T03:58:00Z
**Agent**: jungle-coder
**Worktree**: .worktrees/idle-nudge-plan/

## What's implemented (✅)

1. **`relay_nudge.ml`** — scheduler thread, message loading, nudge dispatch
   - `load_messages` reads `<broker_root>/nudge/messages.json`
   - `nudge_tick` scans registrations, checks idle/DND, sends nudge
   - `start_nudge_scheduler` runs as Lwt async thread
   - Hardcoded defaults: cadence=30min, idle=25min

2. **`last_activity_ts`** in registration type (`c2c_mcp.mli` line 33)

3. **`touch_session` function** (`c2c_mcp.ml` ~line 2339) — updates `last_activity_ts` on registry write

4. **Touch_session call sites** — 13 handlers covered:
   `register`, `poll_inbox`, `peek_inbox`, `drain_inbox`, `send`, `send_all`,
   `send_room`, `send_room_invite`, `join_room`, `leave_room`, `set_dnd`,
   `dnd_status`

5. **Scheduler startup** — `Relay_nudge.start_nudge_scheduler` called in
   `c2c_mcp_server.ml:313`

## Gaps found

### Gap 1: Env vars not wired (medium)
`C2C_NUDGE_CADENCE_MINUTES` and `C2C_NUDGE_IDLE_MINUTES` are documented but
not read. `relay_nudge.ml:98` uses hardcoded defaults. Need to read from env
in `c2c_mcp_server.ml` before calling `start_nudge_scheduler`.

### Gap 2: `messages.json` not created (medium)
`<broker_root>/nudge/messages.json` does not exist. `load_messages` returns `[]`
and logs a warning. Need to create the file with nudge message pool.

### Gap 3: `set_room_visibility` missing `touch_session` (minor)
Line ~4306 in `c2c_mcp.ml` — `set_room_visibility` changes room state on behalf
of a session but doesn't update `last_activity_ts`. Minor: it's a room admin
action, not a send/receive interaction.

## Root cause
The implementation was done in the `feat-idle-nudge` worktree (now stale, behind
origin) but never fully wired up with env vars and the message pool file.

## Fix status
Gap 1 and 2 are straightforward to close. Gap 3 is minor.
