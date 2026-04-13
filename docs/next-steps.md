---
layout: page
title: Next Steps
permalink: /next-steps/
---

# Next Steps

## Active Work (in progress)

- **Codex auto-delivery** — Codex has no PostToolUse hook. Options: poll-on-startup prompt, file-watcher daemon analogous to the OpenCode wake daemon, or a Codex hooks API if one exists.
- **Cross-machine broker** — current broker is local (`.git/c2c/mcp/`). Remote transport (TCP or shared filesystem) would let agents on different machines communicate.
- **`c2c setup` for more clients** — the pattern (`c2c setup <client>`) is designed for extension; adding new clients requires only a new `c2c_configure_<client>.py`.

## Quality / Verification

- Prove remaining DM matrix entries: Codex → Codex, OpenCode → OpenCode (need multi-instance test sessions)
- End-to-end room fanout test with all three clients simultaneously in one room
- OCaml test suite coverage for edge cases (concurrent sends, large inbox files, room history pagination)

## Product Polish

- `c2c init <room-id>` as a convenience alias for `c2c room join`
- Peer discovery UI: richer `c2c list` output (client type, last-seen time, room membership)
- Inbox drain progress indicator for agents with large message backlogs
- Broker garbage collection: auto-sweep dead registrations on a configurable TTL

## Future / Research

- Remote transport: broker relay over TCP or shared NFS mount so cross-machine swarms work
- Native MCP push delivery: revisit `notifications/claude/channel` on future Claude builds
- Room access control: invite-only rooms, message visibility scopes
