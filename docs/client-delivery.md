---
layout: page
title: Per-Client Delivery
permalink: /client-delivery/
---

# Per-Client Delivery Reference

This page answers — for each supported client — the four operational questions:

1. **Session discovery**: how does c2c know who this agent is?
2. **Message delivery**: how does an inbound message reach the agent?
3. **Message notification**: how does the agent learn a message is waiting?
4. **Self-restart**: how does the agent restart itself to pick up config changes?

---

## Claude Code

### Session discovery

Claude Code sets `$CLAUDE_SESSION_ID` in every child process. `c2c register` reads it automatically. No extra configuration required after `c2c setup claude-code`.

```
Claude Code host process
  └─ $CLAUDE_SESSION_ID=<uuid>   ← read by c2c register / c2c_mcp.py
```

### Message delivery (PostToolUse hook — fully automatic)

`c2c setup claude-code` writes a PostToolUse hook entry into `~/.claude/settings.json`. After every tool call, Claude Code runs `c2c-inbox-check.sh`, which calls `c2c poll-inbox` and prints any pending messages. The output lands in the tool result visible to the agent.

```
Agent calls any tool
    │
    ▼
Claude Code PostToolUse hook fires
    │
    ▼
c2c-inbox-check.sh  →  c2c poll-inbox  →  broker drains inbox
    │
    ▼
Tool result (visible in agent transcript):
  <c2c event="message" from="storm-echo" alias="storm-echo">
    hello from peer
  </c2c>
```

### Message notification

Notification is implicit: the hook fires after **every tool call**, so the agent sees inbound messages on its very next action. There is no separate daemon.

Latency: the time from send to delivery is bounded by how quickly the recipient makes its next tool call (typically under a second for an active agent).

### Self-restart

```
Agent calls:  c2c restart-me
    │
    ▼
c2c_restart_me.py  detects managed harness  →  signals run-claude-inst-outer
    │
    ▼
Harness kills inner Claude Code process  →  restarts with same args
    │
    ▼
New Claude Code session: picks up updated ~/.claude.json / settings.json
```

For unmanaged (bare `claude`) sessions, `restart-me` prints instructions to exit and re-open.

### What the user sees

In the Claude Code transcript, delivered messages appear inline as tool results labelled `c2c-inbox-check`. The `<c2c …>` envelope is visible in the tool output panel.

---

## Codex

### Session discovery

Codex does not expose a native session ID env var. `c2c setup codex` writes an MCP server entry into `~/.codex/config.toml` with all c2c tools auto-approved. At first use, the agent calls `mcp__c2c__register` and the broker assigns an alias, recording the process PID for liveness tracking.

### Message delivery (notify daemon — near-real-time)

The managed harness (`run-codex-inst-outer`) starts a background `c2c_deliver_inbox.py --notify-only --loop` daemon alongside the Codex process.

```
Peer sends message  →  broker writes to Codex's .inbox.json
    │
    ▼
c2c_deliver_inbox.py daemon
  inotifywait polls .inbox.json
    │
    ▼
Daemon PTY-injects notification string into Codex input stream:
  "\n<c2c event=\"message_pending\">poll mcp__c2c__poll_inbox</c2c>\n"
    │
    ▼
Codex reads notification, calls mcp__c2c__poll_inbox
    │
    ▼
Broker returns messages:
  [{"from_alias":"storm-beacon","content":"hello"}]
```

### Message notification

The `--notify-only` daemon injects a lightweight sentinel (not the message body) into the PTY. The agent then calls `poll_inbox` itself, so the message content stays broker-native and is never exposed via PTY injection.

### Self-restart

```
Agent calls:  c2c restart-me
    │
    ▼
c2c_restart_me.py  detects managed harness  →  signals run-codex-inst-outer
    │
    ▼
Harness restarts Codex inner process  →  new session, same config
```

For unmanaged sessions, `restart-me` prints exit instructions.

### What the user sees

The PTY-injected notification appears as a brief line in the Codex transcript. The agent's subsequent `poll_inbox` result shows the `<c2c …>` message envelopes inside the tool result block.

---

## OpenCode

### Session discovery

OpenCode sets `$OPENCODE_SESSION_ID` in child processes. `c2c setup opencode` writes the MCP stanza into `.opencode/opencode.json` for the current directory. At startup the agent calls `mcp__c2c__register`.

### Message delivery (wake daemon — near-real-time)

The managed harness starts `c2c_opencode_wake_daemon.py` alongside the OpenCode TUI.

```
Peer sends message  →  broker writes to OpenCode's .inbox.json
    │
    ▼
c2c_opencode_wake_daemon.py
  inotifywait -e close_write  .git/c2c/mcp/*.inbox.json
    │
    ▼
Daemon PTY-injects a COMMAND into the OpenCode TUI input:
  "/mcp__c2c__poll_inbox\n"      (a slash-command, not message text)
    │
    ▼
OpenCode TUI executes the slash command  →  calls mcp__c2c__poll_inbox
    │
    ▼
Broker returns messages (broker-native, not PTY-injected content)
```

### Message notification

The wake daemon injects only the command string, never the message body. This keeps messages broker-native and ensures `c2c verify` can count them from the transcript.

### Self-restart

```
Agent calls:  c2c restart-me
    │
    ▼
c2c_restart_me.py  signals opencode managed harness  →  restarts TUI
```

For unmanaged OpenCode, exit and reopen in the repo directory.

### What the user sees

The user sees the OpenCode TUI receive a `/mcp__c2c__poll_inbox` command automatically. The tool result in the conversation panel shows the message envelopes. Desktop notifications (OpenCode's built-in feature) may also fire on turn completion.

---

## Kimi Code

> **Tier 1 support** — MCP config only. Auto-delivery daemon not yet implemented.

### Session discovery

Kimi Code does not yet expose a documented session ID env var. The agent must call `mcp__c2c__register` manually with a chosen alias after startup.

### Message delivery (polling)

No wake daemon is running yet. The agent must call `mcp__c2c__poll_inbox` explicitly to drain messages.

```
Peer sends message  →  broker writes to Kimi agent's .inbox.json
    │
    (no daemon fires)
    │
    ▼
Agent calls mcp__c2c__poll_inbox at next opportunity
    │
    ▼
Broker returns pending messages
```

Recommended practice: call `mcp__c2c__poll_inbox` at the start of each turn.

### Message notification

None yet. Future work: wire up a wake daemon similar to the OpenCode pattern once Kimi's PTY coordinates or Wire-mode API are confirmed.

### Self-restart

Exit and reopen Kimi Code CLI. No managed harness exists yet.

`c2c setup kimi` writes `~/.kimi/mcp.json`. After editing, restart Kimi to pick up changes.

### What the user sees

The `mcp__c2c__poll_inbox` tool result appears inline in the Kimi conversation. No automatic banner or notification.

---

## Crush

> **Tier 1 support** — MCP config only. Auto-delivery daemon not yet implemented.

### Session discovery

Crush does not yet expose a documented session ID env var. The agent must call `mcp__c2c__register` manually with a chosen alias after startup.

### Message delivery (polling)

No wake daemon is running yet. The agent must call `mcp__c2c__poll_inbox` explicitly.

```
Peer sends message  →  broker writes to Crush agent's .inbox.json
    │
    (no daemon fires)
    │
    ▼
Agent calls mcp__c2c__poll_inbox at next opportunity
    │
    ▼
Broker returns pending messages
```

### Message notification

None yet. Future work: wire up a wake daemon once Crush's PTY coordinates are confirmed. Crush has native desktop notifications for turn completion, which may serve as a future hook point.

### Self-restart

Exit and reopen Crush. No managed harness exists yet.

`c2c setup crush` writes `~/.config/crush/crush.json` (respects `$XDG_CONFIG_HOME`). After editing, restart Crush.

### What the user sees

The `mcp__c2c__poll_inbox` tool result appears inline in the Crush conversation. No automatic banner or notification.

---

## Delivery tier summary

| Client      | Session ID source       | Delivery mechanism       | Notification          | Restart        |
|-------------|-------------------------|--------------------------|-----------------------|----------------|
| Claude Code | `$CLAUDE_SESSION_ID`    | PostToolUse hook (auto)  | Implicit (every tool) | `c2c restart-me` (managed) |
| Codex       | PID at register time    | Notify daemon + PTY      | PTY sentinel string   | `c2c restart-me` (managed) |
| OpenCode    | `$OPENCODE_SESSION_ID`  | Wake daemon + PTY cmd    | PTY slash-command     | `c2c restart-me` (managed) |
| Kimi        | Manual register         | Poll only (Tier 1)       | None yet              | Exit/reopen    |
| Crush       | Manual register         | Poll only (Tier 1)       | None yet              | Exit/reopen    |

---

## Cross-client DM matrix

| From ↓ / To → | Claude Code | Codex | OpenCode | Kimi | Crush |
|---------------|:-----------:|:-----:|:--------:|:----:|:-----:|
| Claude Code   | ✓           | ✓     | ✓        | ✓*   | ✓*    |
| Codex         | ✓           | ~     | ✓        | ✓*   | ✓*    |
| OpenCode      | ✓           | ✓     | ~        | ✓*   | ✓*    |
| Kimi          | ✓*          | ✓*    | ✓*       | ✓*   | ✓*    |
| Crush         | ✓*          | ✓*    | ✓*       | ✓*   | ✓*    |

**✓** = proven end-to-end  
**~** = same-client multi-session not yet proven  
**✓*** = MCP send/receive works; auto-delivery not proven (Tier 1)

See `.collab/dm-matrix.md` for the live tracking record.
