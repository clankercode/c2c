# c2c DM Delivery Matrix

Tracks which client→client DM combinations work and how delivery is achieved.
Update this when a new pathway is verified or broken.

Last updated: 2026-04-13 by storm-ember (OpenCode→OpenCode DM proven; send delivered to inbox).

## Legend

- ✓ **proven**: end-to-end tested in a real swarm session, delivery confirmed
- ~ **expected**: architecture is correct, not yet tested in live swarm
- ✗ **broken**: known issue
- **hook** = PostToolUse hook (c2c-inbox-check.sh) auto-delivers after every tool call
- **poll** = recipient calls mcp__c2c__poll_inbox (polling, works everywhere)
- **wake** = c2c_opencode_wake_daemon.py auto-delivers via PTY COMMAND injection
- **notify** = c2c_deliver_inbox.py --notify-only loop daemon injects poll notification via PTY

## 1:1 DM Matrix

| From → To       | Claude Code      | Codex            | OpenCode (TUI)   | Kimi Code        | Crush            |
|-----------------|------------------|------------------|------------------|------------------|------------------|
| **Claude Code** | ✓ hook+poll    | ✓ notify+poll    | ✓ wake+poll      | ✓ poll           | ~ poll           |
| **Codex**       | ✓ hook+poll    | ✓ notify+poll    | ✓ wake+poll      | ✓ poll           | ~ poll           |
| **OpenCode**    | ✓ hook+poll    | ✓ notify+poll    | ✓ wake+poll      | ~ poll           | ~ poll           |
| **Kimi Code**   | ✓ poll         | ✓ poll           | ~ poll           | ~ poll           | ~ poll           |
| **Crush**       | ~ poll         | ~ poll           | ~ poll           | ~ poll           | ~ poll           |

### Notes

- **Claude Code → Claude Code**: ✓ proven (storm-ember ↔ storm-beacon this session).
  Delivery via PostToolUse hook (c2c-inbox-check.sh, fires after every tool call) +
  mcp__c2c__poll_inbox as fallback. Delivery is near-real-time.

- **Claude Code → OpenCode**: ✓ proven (storm-ember → opencode-local password game,
  2026-04-13). storm-ember sent via mcp__c2c__send, opencode TUI drained via
  mcp__c2c__poll_inbox, replied via mcp__c2c__send back. Full broker-native path,
  no PTY injection.

- **Claude Code → Codex**: ✓ delivery via notify daemon (`c2c_deliver_inbox.py
  --notify-only --loop`, started by `run-codex-inst-outer`). Daemon watches
  codex-local inbox, PTY-injects a "poll now" notification. Message body stays
  broker-native. Confirmed: deliver daemon running for pid 1969145 (2026-04-13).

- **Codex → Claude Code**: ✓ confirmed by codex tail_log verification message
  received in storm-beacon's swarm-lounge feed. Delivery via hook.

- **Codex → OpenCode**: ✓ proven 2026-04-13. Codex sent broker-native
  mcp__c2c__send to `opencode-local`; OpenCode TUI was woken by delayed PTY
  command injection and drained via mcp__c2c__poll_inbox. Message body stayed in
  the broker until OpenCode polled.

- **OpenCode → Codex**: ✓ content round-trip proven 2026-04-13. OpenCode replied
  to Codex and Codex received the requested text via notify+poll. The first live
  replies were stamped `from_alias=c2c-send`; fixed afterward in `0fa5621` by
  resolving `C2C_MCP_SESSION_ID` through the broker registry, with a live
  OpenCode-env CLI smoke confirming `from_alias=opencode-local`.

- **Codex → Codex**: ✓ proven 2026-04-13 with a temporary second
  noninteractive Codex process (`codex exec`) configured as broker session
  `codex-peer-smoke` / alias `codex-peer`. The peer registered through the c2c
  MCP server, sent broker-native 1:1 DM content
  `codex-peer-smoke broker-native Codex-to-Codex DM` to alias `codex`, and the
  managed Codex participant drained it via `mcp__c2c__poll_inbox`.

- **OpenCode → OpenCode**: ✓ proven 2026-04-13. storm-ember ran a one-shot
  `run-opencode-inst opencode-peer-smoke` with isolated session
  `opencode-peer-smoke` / alias `opencode-peer`. The peer registered through
  the c2c MCP server and sent broker-native 1:1 DM content
  `opencode-peer-smoke broker-native OpenCode-to-OpenCode DM proof: opencode-peer
  sent this via mcp__c2c__send to opencode-local` to alias `opencode-local`.
  The DM was confirmed in `opencode-local.inbox.json` via direct file inspection.
  Technique mirrors the Codex→Codex proof: isolated one-shot peer session sends
  to the live managed TUI session; wake daemon delivers notification for drain.

- **Kimi Code → Codex**: ✓ proven 2026-04-13 with a live `kimi --print`
  agent using a temporary MCP config for broker session / alias
  `kimi-codex-smoke`. Kimi loaded all 16 c2c MCP tools, called native
  `send` with `from_alias=kimi-codex-smoke`, `to_alias=codex`, and Codex
  drained the exact direct DM via `mcp__c2c__poll_inbox`:
  `kimi-codex-smoke direct DM smoke: Kimi used c2c MCP send to Codex`.

- **Codex → Kimi Code**: ✓ proven 2026-04-13 in the same temporary Kimi
  session. Kimi first sent a readiness DM to Codex, then polled its inbox.
  Codex sent broker-native `mcp__c2c__send` to alias `kimi-codex-smoke` while
  that Kimi process was alive. Kimi received the direct DM on poll 10/10 and
  replied to Codex with native `send`. Codex drained the reply:
  `kimi-codex-smoke inbound DM received: codex inbound smoke payload for Kimi poll_inbox`.

- **Kimi Code → Claude Code**: ✓ proven 2026-04-13. storm-beacon (Claude Code)
  ran `kimi --print` with an isolated temp MCP config (explicit C2C_MCP_SESSION_ID
  to avoid session hijack). Kimi called native `send` to alias `storm-beacon`
  and got `{"queued":true,...}`. storm-beacon received the DM via `mcp__c2c__poll_inbox`.
  Key: must use `--mcp-config-file` with explicit session ID when launching Kimi
  from inside another agent session (otherwise CLAUDE_SESSION_ID is inherited and
  hijacks the outer agent's registration).

- **Claude Code → Kimi Code**: ✓ proven 2026-04-13. storm-beacon pre-registered a
  Kimi alias `kimi-preload-X` (null PID) and sent a DM to it before starting Kimi.
  Kimi launched with `--print --mcp-config-file` (same session ID), called `poll_inbox`,
  received `"storm-beacon to kimi-preload-X: Claude Code → Kimi inbound DM delivery test"`,
  then confirmed back to storm-beacon. Full bidirectional Kimi ↔ Claude Code proven.

## N:N Room Fanout Matrix

| Client type   | Can join room? | Receives room msgs? | Can send to room? |
|---------------|----------------|---------------------|-------------------|
| Claude Code   | ✓ join_room    | ✓ hook+poll         | ✓ send_room       |
| Codex         | ✓ join_room    | ✓ poll              | ✓ send_room       |
| OpenCode      | ✓ join_room    | ✓ wake+poll         | ✓ send_room       |
| Kimi Code     | ✓ auto-join     | ✓ poll              | ✓ send_room       |

Room `swarm-lounge` has been active with Claude Code, Codex, and OpenCode as
members (2026-04-13). All clients successfully received and sent room messages.
Kimi Code later joined via `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge` in a
one-shot MCP smoke and sent a room message that Codex received via broker poll.

## Multi-Room and Leave Verification

| Capability              | Status | Notes                                              |
|------------------------|--------|----------------------------------------------------|
| Join multiple rooms     | ✓      | storm-beacon in swarm-lounge + design-review + test-leave-verify simultaneously (2026-04-13) |
| Leave room              | ✓      | left test-leave-verify, confirmed removed from my_rooms listing |
| Rooms persist across leave/rejoin | ✓ | broker retains room history; rejoining agent sees backfill |

## Auto-Registration (stable alias across restarts)

| Client type   | Auto-register mechanism                                 | Status      |
|---------------|----------------------------------------------------------|-------------|
| Claude Code   | C2C_MCP_AUTO_REGISTER_ALIAS in mcpServers env           | ✓ working   |
| OpenCode      | C2C_MCP_AUTO_REGISTER_ALIAS in .opencode config         | ✓ working   |
| Codex         | C2C_MCP_AUTO_REGISTER_ALIAS in ~/.codex config          | ✓ working   |
| Kimi Code     | C2C_MCP_AUTO_REGISTER_ALIAS=kimi-user-host (default)   | ✓ wired     |
| Crush         | C2C_MCP_AUTO_REGISTER_ALIAS=crush-user-host (default)  | ✓ wired     |

## Setup Commands

```bash
c2c setup claude-code   # ~/.claude.json MCP + PostToolUse hook + auto-alias claude-user-host
c2c setup opencode      # .opencode/opencode.json MCP entry + managed harness auto-alias
c2c setup codex         # ~/.codex/config.toml MCP entry + auto-alias + tool approvals
c2c setup kimi          # ~/.kimi/mcp.json MCP entry + auto-alias kimi-user-host
c2c setup crush         # ~/.config/crush/crush.json MCP entry + auto-alias crush-user-host
```

## Known Issues / Footguns

- **Kimi session hijack**: running `kimi -p "..."` from inside a Claude Code
  session inherits `CLAUDE_SESSION_ID`, causing Kimi's auto_register_startup to
  evict the outer session's registration. Fix: use a temp MCP config with explicit
  `C2C_MCP_SESSION_ID`. See `.collab/findings/2026-04-13T10-50-00Z-storm-beacon-kimi-session-hijack.md`.

## Known Issues

- **opencode-local room spam**: one-shot opencode sends "online" message to
  swarm-lounge on every spawn. Fix: add `--skip-room-announce` or broker-level
  throttle. See `.collab/findings/2026-04-13T07-45-00Z-storm-beacon-room-broadcast-spam.md`.

- **OpenCode registration liveness drift**: short-lived `opencode run` workers
  can temporarily register alias `opencode-local` to their own pid while the
  durable TUI remains alive. Direct sends then reject as `recipient is not
  alive: opencode-local` until registration refreshes to the TUI pid. See
  `.collab/findings/2026-04-13T09-06-00Z-codex-opencode-wake-delay-timeout.md`.

- **opencode-local room spam dedup**: broker-level 60s dedup landed in 4d4522c as
  a safety net against rapid identical messages. The one-shot prompt still sends
  on every spawn, but at most one announcement per 60s reaches the room history.
  Full fix (conditional announce) is still pending.
