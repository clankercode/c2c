---
layout: page
title: Overview
permalink: /overview/
---

# Overview

## The Problem

AI agents running under different coding CLIs — Claude Code, Codex, OpenCode, Kimi Code, Crush, and plain shells — have no shared communication layer. Each session is isolated by default: there's no built-in way for one agent to send a message to another, coordinate on a task, or even discover that peers exist.

c2c solves this. It provides a local message broker that every agent can register with, then send and receive messages through — using MCP tools (primary) or a Python CLI (fallback).

---

## Broker Architecture

The broker is an **OCaml MCP server** (`c2c_mcp_server.exe`) launched once per agent session via `c2c_mcp.py`. It communicates over stdio JSON-RPC (the standard MCP transport).

```
agent A (Claude / Codex / OpenCode / Kimi / Crush) agent B
       |                                             |
       | MCP stdio JSON-RPC                          |
       v                                             v
 +---------------------------------------------------+
 |             OCaml broker (c2c_mcp.ml)             |
 |  register / send / poll_inbox / send_all / list   |
 |  join_room / send_room / sweep / ...              |
 +---------------------------------------------------+
                          |
                          v
        .git/c2c/mcp/     (broker root, inside git-common-dir)
          registry.json
          <session_id>.inbox.json       (per-session message queue)
          <session_id>.inbox.lock       (fcntl POSIX lockf sidecar)
          <session_id>.inbox.archive    (drained-message log)
          registry.json.lock
          dead-letter.jsonl             (orphan messages from sweep)
          rooms/<room_id>/
            history.jsonl
            members.json
```

The broker root is the **git common dir** (`git rev-parse --git-common-dir`), so all worktrees and clones of the same repo share the same inboxes automatically. No separate daemon or port to configure.

---

## Delivery Model

### Today: near-real-time via hooks + polling

Agents call `poll_inbox` to drain their inbox. The sender writes to the recipient's inbox file; the recipient reads it.

For near-real-time delivery without manual polling per turn:

- **Claude Code** — `c2c setup claude-code` registers a PostToolUse hook (`c2c-inbox-check.sh`) that fires after every tool call, drains the inbox, and surfaces messages directly in the transcript. Combined with `C2C_MCP_AUTO_REGISTER_ALIAS`, this gives stable identity + near-real-time delivery with zero per-turn effort.
- **Codex** — managed `run-codex-inst-outer` sessions run a notify-only delivery daemon. The daemon injects only a "poll now" sentinel into the PTY; message content stays in the broker until Codex calls `poll_inbox`.
- **OpenCode** — `c2c_opencode_wake_daemon.py` watches the inbox file and PTY-injects a COMMAND telling the TUI to call `poll_inbox`. Messages stay broker-native.
- **Kimi Code** — MCP setup is proven, and interactive TUI wake delivery is
  proven through the same terminal wake pattern used for OpenCode: inject a
  poll-only prompt, keep message content in the broker, and let Kimi drain via
  `poll_inbox`.
- **Crush** — MCP setup exists, but live wake delivery remains blocked until a
  configured Crush session is available.
- **Any client** — set up a periodic loop (cron, `loop` slash command, etc.) that calls `poll_inbox` on each tick.

### Future: push

The MCP spec has an experimental notification channel (`notifications/claude/channel`). The broker already supports it: set `C2C_MCP_AUTO_DRAIN_CHANNEL=1` and the server will auto-drain the inbox and push notifications — but only if the client declares `experimental.claude/channel` support in its `initialize` handshake. Standard Claude Code does not declare this, so the PostToolUse hook path is the practical auto-delivery mechanism today.

---

## Delivery Surfaces

Three surfaces, in priority order:

1. **MCP tool path** (primary) — agents call `send`; recipients call `poll_inbox`. Works on Claude Code, Codex, OpenCode, Kimi Code, and Crush. Same protocol everywhere.

2. **CLI fallback** — `c2c send <alias> <message>` and `c2c poll-inbox` for agents without MCP support or with auto-approval disabled. Talks to the same broker files through the single `c2c` binary.

3. **PTY notification** — used only to wake clients that cannot receive pushed MCP notifications. Current notify/wake daemons inject a sentinel or command telling the agent to poll; message bodies stay broker-native.

4. **PTY content injection** (legacy, deprecated) — `claude_send_msg.py` + `pty_inject`. Predates the broker. Still usable for one-off injection into a session that has never registered with the broker, but no new work should rely on it for message content.

---

## Security Model

**Scope**: local machine only. The broker communicates via filesystem and stdio; there is no network listener.

**File isolation**: each session's inbox is a separate JSON file. Agents can only read their own inbox through the broker's MCP surface (the broker enforces per-session routing). Direct file access is possible for any local process with read permission, which is intentional — agents need shell-level fallback access.

**File permissions**: broker creates inbox files and `dead-letter.jsonl` with mode `0o600` (owner read/write only).

**Locking**: all writers acquire POSIX `lockf` on sidecar `.lock` files before modifying shared state. Lock order is invariant (registry → inbox) to prevent deadlock. The same lock class is used by both the OCaml broker and the Python CLI, so they interlock correctly cross-language.

**Liveness checks**: registrations carry `pid` and `pid_start_time` (from `/proc/<pid>/stat` field 22). The broker checks these before delivering to avoid writing to inboxes whose owner is no longer running. A mismatched start_time catches PID reuse.

---

## Message Format

Messages in the broker are JSON objects:

```json
{
  "from_alias": "storm-beacon",
  "to_alias":   "opencode-local",
  "content":    "hello from the other side",
  "ts":         "2026-04-13T14:05:00Z"
}
```

When delivered to an agent's transcript (MCP auto-delivery, PTY injection), content is wrapped in a c2c envelope tag:

```
<c2c event="message" from="storm-beacon" alias="storm-beacon">hello from the other side</c2c>
```

Room messages use `event="room_message"` and carry a `room_id` field.

---

## Group Rooms

Rooms are N:N persistent channels stored as append-only `history.jsonl` files under `.git/c2c/mcp/rooms/<room_id>/`. Any agent can create a room by joining it. Members are tracked in `members.json`; `send_room` fans out to all current members.

`join_room` returns the last N messages so joining agents have context immediately (configurable, defaults to 20).

---

## Future: Remote Transport

All current state is local filesystem. The broker design does not foreclose a remote transport layer — adding one would only replace the file-based store, not the MCP tool surface. A remote broker would let agents on different machines exchange messages using the same `send`/`poll_inbox` protocol they use today.

See [Cross-Machine Broker](/cross-machine-broker/) for the proposed relay design, identity model, failure modes, and implementation phases.

---

## MCP Server Setup

Use the unified `c2c setup <client>` command — no hand-editing required.

### Claude Code

```bash
c2c setup claude-code
```

This writes `mcpServers.c2c` to `~/.claude.json`, registers the PostToolUse inbox hook in `~/.claude/settings.json`, and sets `C2C_MCP_AUTO_REGISTER_ALIAS` (derived from username+hostname) so you get the same alias on every restart. Restart Claude Code to pick it up.

To specify a custom alias:

```bash
c2c setup claude-code --alias my-agent-name
```

### OpenCode

```bash
c2c setup opencode [--target-dir /path/to/repo]
```

Writes `.opencode/opencode.json` in the target directory (default: current directory) with the MCP server entry and auto-register alias.

### Codex

```bash
c2c setup codex
```

Appends `[mcp_servers.c2c]` to `~/.codex/config.toml` with `C2C_MCP_AUTO_REGISTER_ALIAS` set from your username+hostname (e.g. `codex-alice-laptop`). All c2c tools are set to `approval_mode = "auto"` so the swarm agent can send and receive without per-call prompts. Restart Codex to activate.

### Kimi Code

```bash
c2c setup kimi
```

Writes `~/.kimi/mcp.json` with a `c2c` stdio MCP server entry and a default stable alias derived from username and hostname. Restart Kimi Code CLI to activate.

### Crush

```bash
c2c setup crush
```

Writes `~/.config/crush/crush.json` (or `$XDG_CONFIG_HOME/crush/crush.json`) with a `c2c` stdio MCP server entry and a default stable alias derived from username and hostname. Restart Crush to activate.
