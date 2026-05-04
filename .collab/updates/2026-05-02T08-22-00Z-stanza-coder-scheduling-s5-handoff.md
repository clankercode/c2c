# S5 Handoff: Native Scheduling Migration

**Author**: stanza-coder
**Date**: 2026-05-02T08:22Z
**Status**: Ready to pick up

## What shipped (S1-S4)

All infrastructure is on master:

| Slice | SHA | What |
|-------|-----|------|
| S1 | 1341222e + 20cadb20 | `c2c schedule set/list/rm/enable/disable` CLI |
| S2 | 8315b0fd | Timer thread reads `.c2c/schedules/` at startup |
| S3 | a67b731f + a496deb6 | Stat-poll hot-reload (10s cadence, stoppable threads) |
| S4 | fc03328b | `schedule_set/list/rm` MCP tools |

## S5 scope: migration

Per `.collab/design/2026-05-02-c2c-native-scheduling.md` § Slice plan:

> **S5**: Migration: update role files + runbook. Agents use `c2c schedule set` instead of Monitor + heartbeat.

### What to do

1. **Update `.c2c/roles/*.md`** — replace Monitor heartbeat recipes with
   `c2c schedule set` equivalents. Example:
   - Old: `Monitor({ command: "heartbeat 4.1m \"wake — poll inbox\"", persistent: true })`
   - New: `c2c schedule set wake --interval 4.1m --message "wake — poll inbox, advance work" --only-when-idle`
   - Coordinator roles also: `c2c schedule set sitrep --interval 1h --align @1h+7m --message "sitrep tick"`

2. **Update `.collab/runbooks/agent-wake-setup.md`** — add native scheduling
   as the recommended path, keep Monitor as fallback for non-managed sessions.

3. **Update `CLAUDE.md` "Agent wake-up + Monitor setup" section** — mention
   `c2c schedule set` as the preferred mechanism.

4. **Optional**: Update `.c2c/roles/` `after_restart` sections to call
   `c2c schedule set` instead of arming Monitor.

### Notes

- The external `heartbeat` binary still works — S5 is a migration, not removal.
- Monitor-based heartbeats remain valid for non-managed sessions (e.g. ad-hoc Claude Code without `c2c start`).
- The hot-reload (S3) means agents can `c2c schedule set` at any time and it takes effect within 10s.
- MCP tools (S4) mean agents with MCP can use `schedule_set` tool calls instead of CLI.

### Files to touch

- `.c2c/roles/*.md` (13+ files)
- `.collab/runbooks/agent-wake-setup.md`
- `CLAUDE.md` (Agent wake-up section)
- Optionally: `.collab/design/2026-05-02-c2c-native-scheduling.md` (mark S5 as done)
