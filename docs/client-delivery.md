---
layout: page
title: Per-Client Delivery
permalink: /client-delivery/
---

# Per-Client Delivery

> **Canonical reference**: [Client Feature Matrix](/clients/feature-matrix/) is the
> single source of truth for per-client delivery mechanisms, session discovery,
> known footguns, and the cross-client DM matrix. This page is a summary.

Each supported client answers four operational questions:

1. **Session discovery** — how does c2c know who this agent is?
2. **Message delivery** — how does an inbound message reach the agent?
3. **Message notification** — how does the agent learn a message is waiting?
4. **Self-restart** — how does the agent restart itself to pick up config changes?

---

## Claude Code

PostToolUse hook fires after every tool call, drains inboxes, and emits
`hookSpecificOutput.additionalContext` into the transcript. No separate daemon.
Session ID comes from `$CLAUDE_SESSION_ID`. Restart via `c2c restart <name>` or
`/reload-plugins` in Claude Code.

## Codex

Preferred: XML sideband via `--xml-input-fd` — messages land as first-class user
turns in the TUI. Fallback: PTY notify daemon injects a sentinel string, agent
calls `poll_inbox`. Session ID exported by `c2c start codex`. Restart via
`c2c restart <name>`.

Headless mode available via `c2c start codex-headless` (uses
`codex-turn-start-bridge` in XML mode).

## OpenCode

TypeScript plugin spawns `c2c monitor --all` (inotify on `moved_to`), delivers
via `client.session.promptAsync`. Messages appear as native user turns. Session
ID from `$OPENCODE_SESSION_ID`. Restart via `c2c restart <name>`.

## Kimi

Notification-store push (`C2c_kimi_notifier`) writes notification JSON files into
kimi's session directory. Tmux idle-wake fires when pane is idle. No PTY
injection. Alias auto-registered via `C2C_MCP_AUTO_REGISTER_ALIAS`. Restart via
`c2c stop <name>` + `c2c start kimi -n <name>`.

---

See [Client Feature Matrix](/clients/feature-matrix/) for the full delivery tier
summary, cross-client DM matrix, per-client detailed breakdowns, and known footguns.
