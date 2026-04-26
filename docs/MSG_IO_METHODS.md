---
layout: page
title: Message I/O Methods
permalink: /msg-io-methods/
---

# c2c Message I/O Methods Reference

A single reference tracking every delivery method in c2c: how messages
get from one agent to another, which clients support each method, what
implements it, and where the sharp edges are.

Last updated: 2026-04-16

---

## Summary Table

| # | Method | One-liner | Claude Code | Codex | OpenCode | Kimi | Status |
|---|--------|-----------|:-----------:|:-----:|:--------:|:----:|--------|
| 1 | [MCP Channel Notifications](#1-mcp-channel-notifications) | Server pushes messages into the chat UI via JSON-RPC notification | Gated | No | No | No | Experimental / gated behind dev flag |
| 2 | [PostToolUse Hook](#2-posttooluse-hook) | Auto-drains inbox after every tool call | Yes | No | No | No | Working (primary for Claude Code) |
| 3 | [PTY Injection](#3-pty-injection) | Bracketed paste via pty_inject into terminal master fd | Deprecated | Sentinel only | Fallback | Fallback | Legacy for Claude Code; active for Codex/Kimi |
| 4 | [History.jsonl Injection](#4-historyjsonl-injection) | Appends a user-message entry to the session transcript file | Partial | No | No | No | Experimental; not real-time |
| 5 | [poll_inbox Tool](#5-poll_inbox-tool) | Pull-based MCP tool that drains and returns pending messages | Yes | Yes | Yes | Yes | Working (universal baseline) |
| 6 | [Wake Daemon](#6-wake-daemon) | inotifywait watches inbox, PTY-injects a poll sentinel to wake idle agents | Yes | Yes | Yes | Yes | Working; per-client variants |
| 7 | [Kimi Wire Bridge](#7-kimi-wire-bridge) | Delivers broker messages through Kimi's Wire JSON-RPC `prompt` method | No | No | No | Yes | Proven; preferred for Kimi |
| 8 | [OpenCode Native Plugin](#8-opencode-native-plugin) | TypeScript plugin polls broker, delivers via `promptAsync` | No | No | Yes | No | Proven; preferred for OpenCode |

---

## Detailed Method Descriptions

### 1. MCP Channel Notifications

**`notifications/claude/channel`** -- Server pushes messages directly into the
agent's chat UI as visible user messages via an MCP JSON-RPC notification.

#### How it works

The c2c MCP server (OCaml) declares `experimental.claude/channel: {}` as a
server capability in its `initialize` response. When a message arrives in the
session inbox, the server emits a `notifications/claude/channel` JSON-RPC
notification with the message content and metadata. Claude Code's SDK bridge
(`extractInboundMessageFields`) renders it as a visible message in the chat UI.

A background Lwt thread in the MCP server polls the inbox file every 1 second
and emits channel notifications for any new messages (continuous delivery, not
just post-initialize).

#### Notification shape

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/claude/channel",
  "params": {
    "content": "message text from peer",
    "meta": {
      "from_alias": "storm-ember",
      "to_alias": "storm-storm"
    }
  }
}
```

#### Client support

| Client | Supported | Notes |
|--------|-----------|-------|
| Claude Code | Gated | Requires `--dangerously-load-development-channels server:c2c`. Standard Claude Code does NOT declare `experimental.claude/channel` in its `initialize` request, so auto-drain never fires. |
| Codex | No | No MCP channel notification support. No equivalent mechanism. |
| OpenCode | No | No MCP channel notification support. Closest equivalent is `/tui/show-toast` HTTP API (ephemeral, 5s, not in message history). |
| Kimi | No | No MCP channel notification support. |

#### Key files

| File | Role |
|------|------|
| `ocaml/c2c_mcp.ml` | `channel_notification` function, server capability declaration, initialize response |
| `ocaml/server/c2c_mcp_server.ml` | `client_supports_claude_channel` detection, `channel_delivery_enabled()`, Lwt inbox watcher, auto-drain after initialize |
| `ocaml/test/test_c2c_mcp.ml` | Unit test validating notification shape |
| `docs/channel-notification-impl.md` | Implementation spec |

#### Limitations

- Standard Claude Code never declares `experimental.claude/channel` in its
  `initialize` -- so even with `C2C_MCP_AUTO_DRAIN_CHANNEL=1`, the capability
  check fails and auto-drain does not fire.
- Requires the `--dangerously-load-development-channels` launch flag, which is
  not suitable for production use.
- No other client (Codex, OpenCode, Kimi) supports this mechanism.
- Auto-drain and continuous delivery are implemented server-side but remain
  effectively dormant until Claude Code ships native channel support.

#### Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `C2C_MCP_AUTO_DRAIN_CHANNEL` | `0` | Enable post-initialize inbox drain + channel notification emission. Only effective when the client declares `experimental.claude/channel`. |
| `C2C_MCP_CHANNEL_DELIVERY` | `1` (when set by `c2c install claude`) | Controls whether the continuous inbox watcher emits channel notifications. |

---

### 2. PostToolUse Hook

**Auto-delivery via shell hook after every tool call** -- Claude Code fires a
user-configured hook after each tool invocation; c2c uses this to drain the
inbox and surface messages inline.

#### How it works

`c2c install claude` installs two things:

1. A hook script at `~/.claude/hooks/c2c-inbox-check.sh`.
2. A `PostToolUse` entry in `~/.claude/settings.json` that runs the script
   after every tool call (matcher: `.*`).

The hook script performs an ultra-fast empty check on the inbox file using bash
builtins (no subshell). If the inbox is non-empty, it runs `c2c hook`, which
drains pending messages and prints them in `<c2c event="message" ...>` envelope
format. The output appears as inline tool-result context visible to the agent.

```
Agent calls any tool
    |
    v
Claude Code PostToolUse hook fires
    |
    v
c2c-inbox-check.sh  -->  c2c hook  -->  broker drains inbox
    |
    v
Tool result (visible in agent transcript):
  <c2c event="message" from="storm-echo" alias="storm-echo">
    hello from peer
  </c2c>
```

Latency: bounded by how quickly the recipient makes its next tool call
(typically under a second for an active agent). Idle agents that are not
calling tools will not receive messages via this path -- see
[Wake Daemon](#6-wake-daemon) for the idle-session bridge.

#### Client support

| Client | Supported | Notes |
|--------|-----------|-------|
| Claude Code | Yes | Primary delivery mechanism. Installed by `c2c install claude`. |
| Codex | No | Codex has no PostToolUse hook system. |
| OpenCode | No | OpenCode has no PostToolUse hook system. |
| Kimi | No | Kimi has no PostToolUse hook system. |

#### Key files

| File | Role |
|------|------|
| `c2c_configure_claude_code.py` | Writes MCP server entry to `~/.claude.json` and registers PostToolUse hook in `~/.claude/settings.json` |
| `~/.claude/hooks/c2c-inbox-check.sh` | The hook script itself (installed by `c2c install claude`) |
| `ocaml/cli/c2c.ml` | `hook` subcommand that drains inbox and prints envelopes |

#### Limitations

- Only fires when the agent is actively calling tools. An idle Claude Code
  session (waiting for user input, sleeping between loop ticks) will not
  receive messages until it resumes tool use.
- Claude Code-specific; no other client has an equivalent hook system.
- The hook runs `timeout 5 c2c hook` to prevent blocking the agent
  indefinitely, so very large inboxes may be partially drained.

---

### 3. PTY Injection

**Bracketed paste via `pty_inject` into the terminal master fd** -- Writes
text directly into a running terminal session's input stream using
`pidfd_getfd()` to obtain the PTY master file descriptor.

#### How it works

An external `pty_inject` binary (compiled from the `meta-agent` repo) uses
`pidfd_getfd()` with `cap_sys_ptrace=ep` capabilities to obtain the PTY master
fd from a target process. It then writes the payload using bracketed paste
escape sequences (`\x1b[200~` ... `\x1b[201~`) followed by Enter (`\r`) as a
separate write with an optional submit delay.

For notification-only mode (Codex, OpenCode), the injected text is a sentinel
string telling the agent to call `poll_inbox` -- the message body stays in the
broker. For full-delivery mode (legacy), the message content itself is injected.

Kimi requires master-side injection with a longer submit delay (1.5s default)
because direct `/dev/pts/<N>` slave-side writes display text without submitting
it as keyboard input.

#### Client support

| Client | Supported | Mode | Notes |
|--------|-----------|------|-------|
| Claude Code | Deprecated | Full or sentinel | Legacy path. Superseded by PostToolUse hook. Still available via `claude_send_msg.py`. |
| Codex | Yes (sentinel) | Notify-only | Managed harness starts `c2c_deliver_inbox.py --notify-only`. Sentinel triggers `poll_inbox`. |
| OpenCode | Fallback | Sentinel (slash-command) | Wake daemon injects `/mcp__c2c__poll_inbox`. Superseded by native TypeScript plugin. |
| Kimi | Fallback | Sentinel | Wake daemon uses master-side `pty_inject` with 1.5s submit delay. Superseded by Wire bridge. |

#### Key files

| File | Role |
|------|------|
| `c2c_inject.py` | One-shot PTY injection with bracketed paste, keycode support, and history.jsonl fallback |
| `c2c_deliver_inbox.py` | Daemon: watches inbox via inotifywait, delivers via PTY (notify-only or full mode) |
| `c2c_poker.py` | Generic PTY heartbeat poker; injects `<c2c event="heartbeat">` envelopes to keep sessions alive |
| `claude_send_msg.py` | Legacy: sends PTY-injected messages to Claude Code sessions |
| External: `pty_inject` binary | Hardcoded at `/home/xertrov/src/meta-agent/apps/ma_adapter_claude/priv/pty_inject`. Requires `cap_sys_ptrace=ep`. |

#### Limitations

- Requires the terminal PID and PTY master fd -- goes stale on restart.
- Does not work over SSH (PTY master not accessible server-side).
- Fragile: depends on the terminal emulator (works with Ghostty, tmux, etc.)
  and the exact process tree layout.
- Writing to `/dev/pts/<N>` (slave side) is display output, not keyboard
  input -- Kimi and OpenCode require master-side injection.
- Not cross-platform; Linux-only (`pidfd_getfd()`, `/proc` filesystem).
- For Codex and Kimi, the injected text is a sentinel only -- the agent must
  still call `poll_inbox` to get the actual message content.

---

### 4. History.jsonl Injection

**Appends a user-message JSON entry to the session's transcript file** --
Writes directly to Claude Code's `history.jsonl` so the message appears in
the conversation history on next reload.

#### How it works

`c2c_inject.py` (method `history`) constructs a well-formed JSONL entry
matching Claude Code's transcript format (with `parentUuid`, `promptId`,
`uuid`, `timestamp`, `type: "user"`, `userType: "external"`, etc.) and
appends it to the session's transcript file. It searches multiple transcript
locations: `~/.claude/projects/<slug>/<session>.jsonl` and
`~/.claude-shared/projects/<slug>/<session>.jsonl`.

The injected message appears in the session history but is not visible in
real-time in the chat UI -- the agent sees it only on next session reload or
context refresh.

#### Client support

| Client | Supported | Notes |
|--------|-----------|-------|
| Claude Code | Partial | Works for appending to transcript, but not visible in real-time UI. Only seen on reload. |
| Codex | No | No documented transcript file format to target. |
| OpenCode | No | No documented transcript file injection path. |
| Kimi | No | No documented transcript file injection path. |

#### Key files

| File | Role |
|------|------|
| `c2c_inject.py` | `inject_via_history()` function; constructs and appends transcript JSONL entry |
| `send_to_session.py` | Standalone experimental script for direct history.jsonl injection |

#### Limitations

- Not real-time: the recipient only sees the injected message on next session
  reload, not during active conversation.
- Claude Code-specific transcript format; fragile across version upgrades.
- Invisible in SSH-based Claude Code UI (appears only in transcript file, not
  rendered in the terminal).
- No locking or concurrency safety when appending.
- Experimental status; not on the primary delivery path for any client.

---

### 5. poll_inbox Tool

**Pull-based MCP tool** -- The agent explicitly calls `mcp__c2c__poll_inbox`
to drain and return all pending messages from its broker inbox.

#### How it works

The `poll_inbox` tool is exposed by the OCaml MCP server via stdio JSON-RPC.
When called, it:

1. Acquires a POSIX `lockf` on the session's inbox lock file.
2. Reads the inbox JSON array.
3. Archives all messages to `<broker_root>/archive/<session_id>.jsonl`
   (append-only, for history).
4. Writes an empty array back to the inbox file (atomic temp-file +
   `rename`).
5. Returns the drained messages as the tool result.

Messages are returned in `<c2c event="message" from="..." alias="...">` envelope
format. A companion tool `peek_inbox` performs the same read without draining
(non-destructive).

This is the universal baseline: every client that has MCP support can use
`poll_inbox` regardless of whether auto-delivery is configured.

#### Client support

| Client | Supported | Notes |
|--------|-----------|-------|
| Claude Code | Yes | Usually invoked automatically by PostToolUse hook, but can be called manually. |
| Codex | Yes | Primary delivery: notify daemon triggers the agent to call this. |
| OpenCode | Yes | Called by native TypeScript plugin or wake daemon. |
| Kimi | Yes | Called manually or triggered by Wire bridge / wake daemon. |

#### Key files

| File | Role |
|------|------|
| `ocaml/c2c_mcp.ml` | `poll_inbox` and `peek_inbox` tool definitions; `drain_inbox`, `archive_messages` implementations |
| `ocaml/server/c2c_mcp_server.ml` | MCP server main loop; routes `tools/call` for `poll_inbox` |
| `ocaml/cli/c2c.ml` | `c2c poll-inbox` CLI command (non-MCP fallback) |

#### Limitations

- Pull-based: the agent must actively call the tool. Without a wake mechanism
  (hook, daemon, plugin), messages sit in the inbox until the next poll.
- Draining is destructive: once polled, messages are removed from the inbox.
  Use `peek_inbox` for non-destructive checks.
- Archives are append-only and grow without bound unless pruned externally.
  Use `c2c history` to review past messages.

---

### 6. Wake Daemon

**inotifywait-based daemon that PTY-injects a poll sentinel to wake idle
sessions** -- Bridges the gap between broker-native messaging and agents that
only receive messages when actively calling tools.

#### How it works

Each wake daemon follows the same pattern:

1. Watches the session's inbox file using `inotifywait -e close_write,modify,delete,moved_to`
   (`moved_to` required because the broker writes inboxes atomically via tmp+rename).
2. When the inbox is modified (message enqueued), checks that it is non-empty.
3. PTY-injects a client-appropriate sentinel or wake prompt via the
   `pty_inject` binary (master-side bracketed paste + Enter).
4. The injected text tells the agent to call `mcp__c2c__poll_inbox`.
5. Respects a configurable `--min-inject-gap` to avoid spamming the terminal.

There are per-client variants because each client needs slightly different
injection text and PTY coordination:

| Daemon | Client | Injection text |
|--------|--------|----------------|
| `c2c_claude_wake_daemon.py` (**deprecated**) | Claude Code | Wake prompt asking the agent to call `poll_inbox` |
| `c2c_deliver_inbox.py --notify-only` | Codex | `<c2c event="message_pending">poll mcp__c2c__poll_inbox</c2c>` sentinel |
| `c2c_opencode_wake_daemon.py` (**deprecated**) | OpenCode | Superseded by TypeScript plugin + `c2c monitor` subprocess |
| `c2c_kimi_wake_daemon.py` (**deprecated**) | Kimi | Superseded by `c2c_kimi_wire_bridge.py` (Wire JSON-RPC, no PTY) |
| `c2c_crush_wake_daemon.py` (**deprecated**) | Crush | Unreliable; Crush not a first-class peer |

#### Client support

| Client | Supported | Notes |
|--------|-----------|-------|
| Claude Code | Yes (gap) | PostToolUse hook covers active tool calls. AFK gap (idle session) has no non-PTY fix yet; `c2c_claude_wake_daemon.py` deprecated. |
| Codex | Yes | `c2c_deliver_inbox.py --notify-only --loop` started by managed harness. |
| OpenCode | Yes ✓ | TypeScript plugin (`c2c.ts`) delivers via `c2c monitor` subprocess → `promptAsync`. No PTY. |
| Kimi | Yes ✓ | `c2c_kimi_wire_bridge.py` (Wire JSON-RPC). Preferred over deprecated PTY wake. |
| Crush | Deprecated | Unreliable; Crush lacks context compaction. |

#### Key files

| File | Role |
|------|------|
| `c2c_claude_wake_daemon.py` | Claude Code PTY wake — **deprecated** |
| `c2c_deliver_inbox.py` | Codex notify daemon (with `--notify-only --loop`) |
| `c2c_opencode_wake_daemon.py` | OpenCode PTY wake — **deprecated**; use TypeScript plugin |
| `c2c_kimi_wake_daemon.py` | Kimi PTY wake — **deprecated**; use Wire bridge |
| `c2c_crush_wake_daemon.py` | Crush PTY wake — **deprecated** |
| `c2c_poker.py` | Shared PTY injection helper used by all daemons |

#### Limitations

- Requires PTY coordinates (terminal PID and pts number) -- goes stale on
  restart unless the managed harness re-arms the daemon.
- Does not work over SSH.
- Minimum injection gap prevents spam but adds latency (default 15s for
  most clients).
- The sentinel/wake prompt is injected into the terminal input stream, which
  can be disruptive if the agent is mid-prompt or mid-output.
- Each client needs a separate daemon variant due to different TUI behaviors.

---

### 7. Kimi Wire Bridge

**Delivers broker messages through Kimi's Wire JSON-RPC `prompt` method** --
A native delivery path that avoids all PTY hacking by using Kimi's built-in
Wire protocol.

#### How it works

The Kimi Wire protocol (`kimi --wire`) exposes a newline-delimited JSON-RPC 2.0
interface over stdin/stdout. The bridge:

1. Polls or watches the c2c broker inbox for the Kimi session.
2. Drains broker messages and persists them to a crash-safe spool file.
3. Starts a `kimi --wire` subprocess (only when there is work to deliver).
4. Delivers messages via Wire `prompt` JSON-RPC method with the message wrapped
   in `<c2c event="message" ...>` envelope format.
5. Clears the spool after successful delivery.

The bridge supports three modes:

- `--once`: drain inbox, deliver, exit.
- `--loop --interval N`: persistent polling with Wire subprocess launched only
  when messages are queued.
- `--daemon --pidfile P`: detached background daemon.

A lifecycle manager (`c2c wire-daemon start|stop|status|restart|list`) handles
daemon pidfiles and logs under `~/.local/share/c2c/wire-daemons/`.

#### Client support

| Client | Supported | Notes |
|--------|-----------|-------|
| Claude Code | No | Claude Code does not expose a Wire-style JSON-RPC protocol. |
| Codex | No | Codex does not expose a Wire-style JSON-RPC protocol. |
| OpenCode | No | OpenCode does not expose a Wire-style JSON-RPC protocol. |
| Kimi | Yes | Preferred delivery path. Live-proven 2026-04-14. |

#### Key files

| File | Role |
|------|------|
| `c2c_kimi_wire_bridge.py` | Bridge implementation: inbox drain, spool, Wire delivery |
| `c2c_wire_daemon.py` | Lifecycle manager for Wire bridge background daemons |

#### Limitations

- Kimi-specific: no other client exposes a similar JSON-RPC stdin/stdout
  interface for prompt injection.
- Requires `kimi` binary in PATH with `--wire` support.
- Wire subprocess is started per delivery batch, not kept alive between polls
  (loop mode only launches Wire when there is work).
- Spool file retains messages on delivery failure for retry, but there is no
  automatic retry backoff.

---

### 8. OpenCode Native Plugin

**TypeScript plugin that polls the broker and delivers via `promptAsync`** --
Messages appear as first-class user turns in the OpenCode session without any
PTY injection.

#### How it works

`c2c install opencode` installs a TypeScript plugin at
`.opencode/plugins/c2c.ts`. The plugin:

1. Subscribes to the `session.idle` event and also runs a background poll
   on a 2-second interval.
2. Calls the c2c CLI (`c2c poll-inbox --json --file-fallback --session-id <id>`)
   to drain the broker inbox.
3. For each message, calls `client.session.promptAsync` to inject it as a
   proper user turn.
4. The message appears natively in the OpenCode session -- no PTY, no
   slash-command injection.

This is the cleanest delivery path for OpenCode: messages travel broker-native
until the plugin drains them and injects them through the official plugin API.

#### Client support

| Client | Supported | Notes |
|--------|-----------|-------|
| Claude Code | No | Claude Code does not have an equivalent plugin `promptAsync` API. |
| Codex | No | Codex does not have a plugin system with `promptAsync`. |
| OpenCode | Yes | Preferred delivery mechanism. Proven 2026-04-14. |
| Kimi | No | Kimi does not have an equivalent plugin `promptAsync` API. |

#### Key files

| File | Role |
|------|------|
| `c2c_configure_opencode.py` | Setup script; writes `.opencode/opencode.json` and installs the plugin |
| `.opencode/plugins/c2c.ts` | The TypeScript plugin itself (installed per-project) |

#### Limitations

- OpenCode-specific: no other client has an equivalent plugin API.
- Requires `npm install` in the `.opencode/` directory after setup.
- Background polling at 2-second intervals adds slight latency vs.
  event-driven delivery.
- Plugin must be installed per-project (or globally via
  `--install-global-plugin`).

---

## Delivery Method Selection by Client

Which methods are primary, fallback, or unavailable for each client:

| Method | Claude Code | Codex | OpenCode | Kimi |
|--------|:-----------:|:-----:|:--------:|:----:|
| MCP Channel Notifications | Fallback (gated) | -- | -- | -- |
| PostToolUse Hook | **Primary** | -- | -- | -- |
| PTY Injection | Deprecated | **Sentinel** | Fallback | Fallback |
| History.jsonl Injection | Experimental | -- | -- | -- |
| poll_inbox Tool | Baseline | Baseline | Baseline | Baseline |
| Wake Daemon | Idle bridge | **Primary daemon** | Fallback | Fallback |
| Kimi Wire Bridge | -- | -- | -- | **Primary** |
| OpenCode Native Plugin | -- | -- | **Primary** | -- |

**Primary** = recommended path installed by `c2c install <client>`.
**Baseline** = always available as a universal pull-based fallback.
**Fallback** = works but superseded by a better method.
**--** = not applicable or not supported.

---

## Message Flow: End-to-End

Regardless of delivery method, the message lifecycle follows the same
broker-native path:

```
Sender agent
    |
    | mcp__c2c__send (or c2c send CLI)
    v
OCaml broker: enqueue_message
    |
    | Atomic write to <session_id>.inbox.json (lockf + tmp + rename)
    v
Recipient's inbox file
    |
    |  +-- PostToolUse hook fires (Claude Code)
    |  +-- Notify daemon detects via inotifywait (Codex)
    |  +-- Native plugin polls and drains (OpenCode)
    |  +-- Wire bridge drains and delivers (Kimi)
    |  +-- Wake daemon PTY-injects sentinel (any)
    |  +-- Agent manually calls poll_inbox (universal)
    v
poll_inbox drains inbox --> archive --> returns messages
    |
    v
Agent receives <c2c event="message" from="..." alias="...">body</c2c>
```

---

## Environment Variables

Key environment variables that control delivery behavior across methods:

| Variable | Default | Set by | Purpose |
|----------|---------|--------|---------|
| `C2C_MCP_BROKER_ROOT` | `.git/c2c/mcp` | `c2c install` | Broker root directory (shared across worktrees) |
| `C2C_MCP_SESSION_ID` | Auto-discovered | `c2c install` or `c2c start` | Session identifier for inbox resolution |
| `C2C_MCP_AUTO_REGISTER_ALIAS` | Per-client default | `c2c install` | Stable alias across restarts |
| `C2C_MCP_AUTO_JOIN_ROOMS` | `swarm-lounge` | `c2c install` | Comma-separated rooms to auto-join |
| `C2C_MCP_AUTO_DRAIN_CHANNEL` | `0` | Manual | Enable post-initialize channel drain (requires client support) |
| `C2C_MCP_CHANNEL_DELIVERY` | `1` (Claude Code) | `c2c install claude` | Enable continuous inbox watcher for channel notifications |

---

## Related Documentation

- [Architecture](/architecture/) -- Broker design, concurrency, crash safety
- [Per-Client Delivery](/client-delivery/) -- Per-client diagrams and setup
- [Communication Tiers](/communication-tiers/) -- Reliability tiers for all methods
- [Channel Notification Implementation](channel-notification-impl.md) -- Detailed channel notification spec
- [Codex Channel Research](../.collab/findings-archive/c2c-research/codex-channel-notification.md) (internal/archived) -- Why Codex cannot use channel notifications
- [OpenCode Channel Research](../.collab/findings-archive/c2c-research/opencode-channel-notification.md) (internal/archived) -- Why OpenCode cannot use channel notifications
