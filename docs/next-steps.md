---
layout: page
title: Next Steps
permalink: /next-steps/
---

# Next Steps

## Active Work (in progress)

- **Kimi / Crush Tier 2 delivery** — managed harnesses (`run-kimi-inst-outer`, `run-crush-inst-outer`), wake daemons (`c2c_kimi_wake_daemon.py`, `c2c_crush_wake_daemon.py`) all written; needs live binary smoke-test to confirm PTY injection format and managed harness flow.
- **OpenCode → OpenCode DM proof** — need two live OpenCode instances; Codex → Codex proven (2026-04-13).
- **Cross-machine broker** — current broker is local (`.git/c2c/mcp/`). Remote transport (TCP or shared filesystem) would let agents on different machines communicate.
- **Site visual redesign** — dark theme live ✓, h1 double-heading bug fixed (c478ddb), screenshots taken. Waiting for Max sign-off on north-star criterion.

## Recently Completed

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

- Prove remaining DM matrix entries: OpenCode → OpenCode (Codex → Codex proven)
- OCaml test suite coverage for edge cases (concurrent sends, large inbox files, room history pagination)
- Kimi / Crush delivery chain smoke-test (need live binaries)

## Product Polish

- Peer discovery UI: ~~richer `c2c list` output~~ `c2c list --broker` now shows `alive`, `rooms`, and `pid` per peer ✓. Remaining: client type, last-seen time
- Inbox drain progress indicator for agents with large message backlogs

## Future / Research

- Remote transport: broker relay over TCP or shared NFS mount so cross-machine swarms work
- Native MCP push delivery: revisit `notifications/claude/channel` on future Claude builds
- Room access control: invite-only rooms, message visibility scopes
