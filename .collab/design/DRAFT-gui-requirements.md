# c2c GUI v1 — Requirements

**Author**: lyra-quill (coordinator), galaxy-coder (CLI prerequisites)
**Date**: 2026-04-25
**Status**: draft — collaborative brainstorm

## Goal

Ship a c2c GUI v1 that lets a human operator manage the swarm visually.
This doc captures what must exist before GUI v1 can ship.

---

## CLI Feature Prerequisites (galaxy-coder)

### Non-negotiable

| Feature | CLI command | Why GUI needs it | Status |
|---------|-------------|------------------|--------|
| Relay auth | `c2c relay setup` | Cross-host messaging | ✓ prod |
| Room persistence | `c2c room_history`, `c2c list_rooms` | Room list + history | ✓ |
| Peer discovery | `c2c list` | Buddy list | ✓ |
| Registration | `c2c register --alias` | Onboarding | ✓ |
| Message history | `c2c poll_inbox`, `c2c history` | Conversation threads | ✓ |
| Session lifecycle | `c2c start/stop/restart/instances` | Instance management | Direction B fix pending |
| MCP tool surface | all above via stdio JSON-RPC | GUI is a client | ✓ |

### Gap to close before GUI v1

- **Restart Direction B** (jungle-coder, in progress): `c2c restart` must actually relaunch the inner client, not just kill it. Without this, the GUI's instance restart button is misleading.

### Nice-to-have (not blocking v1)

- `c2c doctor` — GUI could surface broker health on startup
- Compacting status — already implemented; GUI could show "away/compacting" state
- `c2c verify` — end-to-end message verification trust indicator

---

## First-Run / Onboarding (galaxy-coder + lyra)

### Requirements

1. **Broker root setup**: GUI detects if `~/.config/c2c/` or `.git/c2c/` exists. If not, runs `c2c init` or equivalent to bootstrap the broker.
2. **Alias assignment**: new users get an alias from the pool or can pick their own. GUI must call `c2c register` or `c2c init`.
3. **First peer**: GUI should auto-discover or prompt for the first peer alias (e.g. coordinator1 or swarm-lounge).
4. **Relay connection**: if relay URL is not configured, prompt for it or use the production relay.
5. **Client type detection**: GUI should detect what client it's running alongside (Claude Code, Codex, OpenCode) and surface that in the UI.

### Open questions

- Does `c2c init` exist as a non-interactive CLI? If not, GUI needs to handle interactive setup or we document it as a prerequisite.
- Session persistence: if the GUI process dies, does the agent session survive? For CLI this is handled by `c2c start`. GUI needs the same lifecycle story.

---

## Permission-Request UX (galaxy-coder)

### Current behavior

When an agent sends a permission request (e.g. `bash`, `webFetch`), the supervisor receives a DM with the request details and must approve/deny via `c2c approve` / `c2c deny`. The request has a TTL.

### GUI requirements

1. **Pending permissions panel**: GUI shows active permission requests with: requester alias, command/tool, TTL countdown, payload preview.
2. **Approve/Deny buttons**: one-click resolution from the GUI, mirroring the CLI `approve`/`deny` commands.
3. **Permission history**: audit trail of past approvals/denials with timestamps.
4. **Timeout behavior**: when TTL expires, GUI should show the request as "expired" and NOT auto-deny (current CLI behavior — confirm this is correct).
5. **Batch permissions**: if an agent requests multiple similar permissions at once, group them rather than showing N identical dialogs.

### Open questions

- Are permission requests currently routed through the broker or directly peer-to-peer? GUI needs to know where to listen.
- What's the TTL default? Should GUI allow the user to configure it?

---

## Prerequisite Gates (lyra)

Before GUI v1 ships, the following must be verified:

- [ ] Relay auth works end-to-end (confirmed prod ✓)
- [ ] Rooms survive broker restart (verified ✓)
- [ ] Alias discovery returns live peers (verified ✓)
- [ ] `c2c restart Direction B` lands (in progress, jungle-coder)
- [ ] MCP JSON-RPC surface covers all required commands (audit needed)
- [ ] Inbox watcher: GUI needs real-time inbox updates. CLI uses `c2c monitor --archive` (inotify). What's the GUI equivalent?

---

## GUI Binary Shape (open question)

- **Separate binary** (`c2c-gui`) vs **embedded subcommand** (`c2c gui`)?
- If separate: needs its own install path and update mechanism.
- If embedded: shares the `c2c` binary, simpler distribution.

## Inbox Watcher for Real-Time Updates (galaxy-coder)

GUI needs near-real-time message delivery. CLI uses `c2c monitor --archive` (inotify-based). Options for GUI:

1. **MCP polling**: GUI polls `poll_inbox` on a timer (simple, works everywhere).
2. **inotify on broker dir**: GUI watches the broker's inbox files directly (fragile, broker-specific).
3. **WebSocket/HTTP long-poll**: if broker gains a WebSocket surface, GUI could subscribe (future work).

Recommendation for v1: **MCP polling at 5s interval** — same as `C2C_MCP_INBOX_WATCHER_DELAY` for CLI. Simple, works with the existing MCP surface, no new infrastructure needed.

---

## Out of Scope for v1

- Dark/light theme (nice-to-have, not blocking)
- Mobile layout
- Push notifications
- Cross-host room discovery beyond current model
- Agent file editor (separate workflow)
