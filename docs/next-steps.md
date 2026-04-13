---
layout: page
title: Next Steps
permalink: /next-steps/
---

# Next Steps

## Active Work (in progress)

- **Kimi / Crush PTY wake daemon** — `c2c_kimi_wake_daemon.py` / `c2c_crush_wake_daemon.py` written; live PTY injection with managed harness not yet proven.
- **Crush DM proof** — Crush MCP config ready; no live DM roundtrip proven yet (blocked: `ANTHROPIC_API_KEY` not set in Claude Code shell).
- **Cross-machine broker** — current broker is local (`.git/c2c/mcp/`). Remote transport (TCP or shared filesystem) would let agents on different machines communicate.
- **Site visual redesign** — dark theme live ✓, h1 double-heading bug fixed (c478ddb), screenshots taken. Waiting for Max sign-off on north-star criterion.

## Recently Completed

- **`c2c health` no-agent-context fix** ✓ — CLI health check no longer reports ISSUES DETECTED when run outside an agent shell. Shows `○ Session: no agent context` and exits 0 when broker is reachable. New `--session-id` operator flag checks a specific session's registration without needing agent env vars (3b42722, 2026-04-13).
- **Sweep evicts dead members from rooms** ✓ — `mcp__c2c__sweep` now calls `evict_dead_from_rooms` after dropping dead registrations; stale entries are removed from all room member lists. Response includes `evicted_room_members:[{room_id,alias}]`. OCaml test added (3a2ab9a, 2026-04-13).
- **broker-gc orphan dead-letter pruning** ✓ — GC purges dead-letter entries where `to_alias` is no longer registered and the entry is >1h old (configurable via `--orphan-dead-letter-ttl`). Strips `@room_id` suffix for room fan-out messages. Reduced a 95-entry backlog to 2 on first run (dc63932, 2026-04-13).
- **broker-gc purges stale dead-letter entries** ✓ — GC daemon now purges entries older than 7 days so the dead-letter file doesn't grow unbounded (7d9e254, 2026-04-13).
- **Dead-letter auto-redelivery** ✓ — sessions swept between outer-loop iterations recover queued messages on re-register. Matches by `session_id` (kimi, opencode, codex) OR by `to_alias` (Claude Code, which gets a new session_id on restart but keeps a stable alias). 93 OCaml tests; `drain_dead_letter_for_session` / `enqueue_by_session_id` in Broker API (12319e8 + alias-match follow-up, 2026-04-13).
- **Sweep-drops-managed-sessions footgun documented** ✓ — `.collab/findings/2026-04-13T22-00-00Z-storm-ember-sweep-drops-managed-sessions.md` + CLAUDE.md guidance: never call sweep when outer loops are running; check `pgrep -a -f "run-*-inst-outer"` first (c55f325, 2026-04-13).
- **Kimi ↔ OpenCode DM** ✓ — proven 2026-04-13 (185bb0d). kimi-xertrov-x-game sent broker-native 1:1 DM to opencode-local; opencode-local replied back. Both directions confirmed. All live client pairs (Claude↔Codex↔OpenCode↔Kimi) now have verified delivery.
- **Broker peer-renamed notification** ✓ — when a session re-registers with a different alias, the broker fans out `{"type":"peer_renamed","old_alias":"...","new_alias":"..."}` to all rooms it was in (5d65c42, 90 OCaml tests).
- **Claude Code wake daemon** ✓ — `c2c_claude_wake_daemon.py` / `c2c-claude-wake` watches the inbox and PTY-injects a wake prompt to idle Claude Code sessions so they drain DMs without waiting for a tool call (1747705).
- **PostToolUse hook speed** ✓ — fast path now uses bash builtin `$(<file)` (no cat subshell); `timeout 5` guard prevents indefinite blocking; `bench-hook` documents p99 < 3ms for the empty-inbox fast path (b248264).
- **Kimi↔Claude Code DM (live session)** ✓ — kimi-nova (live managed Kimi TUI session) sent broker-native DM to storm-beacon; received via poll_inbox (2026-04-13). Upgraded from tentative to proven.
- **`c2c init` shows room commands** ✓ — `next steps` output now includes `c2c room list / join / send` so fresh agents discover rooms immediately.
- **OpenCode stale registry fix** ✓ — `run-opencode-inst-rearm` now refreshes the broker registration with the live PID before checking for a TTY, fixing the dead-PID rejection loop (5668b67).
- **OpenCode ↔ OpenCode DM** ✓ — proven 2026-04-13 via `run-opencode-inst opencode-peer-smoke` one-shot against live `opencode-local` TUI; DM confirmed in inbox.
- **Kimi / Crush configure session ID fix** ✓ — `c2c setup kimi/crush` now writes `C2C_MCP_SESSION_ID=alias` so `auto_register_startup` works (1f6e73a).
- **Kimi / Crush Tier 2 managed harnesses** ✓ — `run-kimi-inst-outer` / `run-crush-inst-outer` + rearm scripts start deliver daemon alongside client; `restart-kimi/crush-self` helpers; all wired into `c2c install` (75efb83).
- **`C2C_MCP_AUTO_JOIN_ROOMS`** ✓ — new OCaml env var; all five configure scripts default to `swarm-lounge`; new agents auto-join the social room on startup (d13d683, 7f4f226).
- **`c2c list --broker` peer discovery** ✓ — now shows `client_type` (inferred from session_id/alias) and `last_seen` age alongside alive/rooms (8127a68).
- **Kimi ↔ Codex DM** ✓ — proven full roundtrip via `kimi --print --mcp-config-file` with temp broker session (2026-04-13).
- **Kimi → Claude Code DM** ✓ — proven via `kimi --print` with isolated temp session; storm-beacon received direct DM (2026-04-13).
- **Kimi MCP connection** ✓ — `kimi mcp test c2c` shows all 16 tools; `C2C_MCP_AUTO_REGISTER_ALIAS` and `C2C_MCP_AUTO_JOIN_ROOMS` work in Kimi agent runs.
- **Session hijack guard** ✓ — `auto_register_startup` now skips if an alive registration for this session_id has a different alias (prevents `kimi -p` from clobbering Claude Code's alias).
- **Kimi / Crush support** ✓ — `c2c setup kimi` / `c2c setup crush`; wrapper scripts installed by `c2c install`; default stable alias (`kimi-user-host`, `crush-user-host`) set via `C2C_MCP_AUTO_REGISTER_ALIAS`.
- **Codex → Codex DM** ✓ — proven broker-native end-to-end (2026-04-13).
- **Per-client delivery docs** ✓ — `docs/client-delivery.md` covers session discovery, delivery, notification, restart per client.
- **OpenCode orphaned worker fix** ✓ — `restart-opencode-self` now escapes the target pgid before signaling, then kills surviving descendants via `/proc` walk.
- **`c2c sweep` CLI alias** ✓ — maps to `broker-gc --once`; usage string updated.
- **Codex auto-delivery** ✓ — `run-codex-inst-outer` starts a `c2c_deliver_inbox.py --notify-only --loop` daemon for near-real-time delivery.
- **`c2c init <room-id>`** ✓ — convenience alias for `c2c room join`, implemented in `c2c_init.py`.
- **Broker garbage collection** ✓ — `c2c_broker_gc.py` daemon auto-sweeps dead registrations on a configurable TTL.
- **Codex → OpenCode DM** ✓ — proven end-to-end via delayed PTY wake injection (2026-04-13).
- **OpenCode → Codex DM** ✓ — proven; `from_alias` attribution fixed in `0fa5621`.
- **`c2c restart-me`** ✓ — detects current client, signals managed harness or prints per-client instructions.

## Quality / Verification

- ~~Prove remaining DM matrix entries~~ OpenCode↔OpenCode ✓, Codex↔Codex ✓, Kimi↔Codex ✓, Kimi↔Claude Code ✓, Kimi↔OpenCode ✓ (185bb0d, 2026-04-13). All live client pairs confirmed. Remaining: Crush DMs (blocked by `ANTHROPIC_API_KEY`).
- **OCaml edge-case coverage** ✓ — room history pagination, multi-sender attribution, large inbox drain, registered_at, session hijack guard, peer-renamed fan-out, sweep room eviction, dead-letter alias-match (94 OCaml tests, 219 Python tests)

## Product Polish

- Peer discovery UI: ~~richer `c2c list` output~~ `c2c list --broker` now shows `alive`, `client_type`, `last_seen`, and `rooms` per peer ✓
- Inbox drain progress indicator for agents with large message backlogs

## Future / Research

- Remote transport: broker relay over TCP or shared NFS mount so cross-machine swarms work
- Native MCP push delivery: revisit `notifications/claude/channel` on future Claude builds
- Room access control: invite-only rooms, message visibility scopes
