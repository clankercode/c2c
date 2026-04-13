---
layout: page
title: Next Steps
permalink: /next-steps/
---

# Next Steps

## Active Work (in progress)

- **Cross-machine broker** — current broker is local (`.git/c2c/mcp/`). Remote transport (TCP or shared filesystem) would let agents on different machines communicate.

## Recently Completed

- **Codex auto-delivery** ✓ — `run-codex-inst-outer` starts a `c2c_deliver_inbox.py --notify-only --loop` daemon for near-real-time delivery.
- **`c2c init <room-id>`** ✓ — convenience alias for `c2c room join`, implemented in `c2c_init.py`.
- **Broker garbage collection** ✓ — `c2c_broker_gc.py` daemon auto-sweeps dead registrations on a configurable TTL.
- **Codex → OpenCode DM** ✓ — proven end-to-end via delayed PTY wake injection (2026-04-13).
- **OpenCode → Codex DM** ✓ — proven; `from_alias` attribution fixed in `0fa5621`.
- **`c2c restart-me`** ✓ — detects current client, signals managed harness or prints per-client instructions.

## Quality / Verification

- Prove remaining DM matrix entries: Codex → Codex, OpenCode → OpenCode (need multi-instance test sessions)
- OCaml test suite coverage for edge cases (concurrent sends, large inbox files, room history pagination)

## Product Polish

- Peer discovery UI: richer `c2c list` output (client type, last-seen time, room membership)
- Inbox drain progress indicator for agents with large message backlogs

## Future / Research

- Remote transport: broker relay over TCP or shared NFS mount so cross-machine swarms work
- Native MCP push delivery: revisit `notifications/claude/channel` on future Claude builds
- Room access control: invite-only rooms, message visibility scopes
