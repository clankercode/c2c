# Codex + notifications/claude/channel Research

**Date:** 2026-04-15  
**Topic:** Does OpenAI Codex support `notifications/claude/channel` or equivalent for external message injection into its chat UI?

---

## Executive Summary

**Short answer: NO, Codex does not support `notifications/claude/channel`.**

Codex does not have a PostToolUse hook like Claude Code, nor does it declare `experimental.claude/channel` support in its MCP handshake. The c2c broker **already implements** `notifications/claude/channel` (both as a server capability and when formatting notifications), but this mechanism is **Claude-Code-specific** and **does not work with Codex**.

For Codex, c2c uses a **different delivery path**: a background daemon that watches inbox files via `inotifywait` and PTY-injects a sentinel to trigger the agent to call `poll_inbox` manually.

---

## What's Supported

### Claude Code — Full channel support

Claude Code supports `notifications/claude/channel` as an **experimental MCP extension** that lets external servers push messages directly into a running session's chat UI (visible as user messages, not just transcript entries).

**How it works:**
```
c2c broker (receives message from peer)
    ↓
c2c MCP server (running as Claude Code MCP server)
    ↓ JSON-RPC notification
notifications/claude/channel { content: "...", meta: { from, to } }
    ↓
Claude Code SDK bridge (extractInboundMessageFields → handleInputPrompt)
    ↓ React state update
Messages.tsx renders message visibly in chat UI
```

**Requirements:**
1. Claude Code must be launched with `--dangerously-load-development-channels server:c2c`
2. The client must declare `experimental.claude/channel` in its `initialize` request
3. c2c broker must have `C2C_MCP_AUTO_DRAIN_CHANNEL=1` set (currently defaults to `0`)

**Current status:** The c2c OCaml MCP server already:
- Declares `experimental.claude/channel` as a server capability
- Formats correct `notifications/claude/channel` JSON-RPC notifications
- Detects client support via `experimental.claude/channel` in initialize handshake
- Auto-drains inbox and emits notifications after initialize (when capable)

However, **standard Claude Code does NOT declare this capability** in its initialize, so the mechanism is gated behind the `--dangerously-load-development-channels` flag.

**Evidence:** `ocaml/c2c_mcp_helpers.ml:330` declares the capability:
```ocaml
let capabilities =
  `Assoc
    [ ("tools", `Assoc [])
    ; ("prompts", `Assoc [])
    ; ("experimental", `Assoc [ ("claude/channel", `Assoc []) ])
    ]
```

### Codex — NOT supported

**Codex does not support `notifications/claude/channel`.**

Key differences from Claude Code:

| Feature | Claude Code | Codex |
|---------|-------------|-------|
| PostToolUse hook | Yes | **No** |
| MCP notifications/claude/channel | Supported (experimental) | **Not supported** |
| Experimental capability declaration | Partial (needs flag) | **No** |
| Native session ID env var | `$CLAUDE_SESSION_ID` | **No** |

**What Codex uses instead:**

Codex uses a **notify daemon + PTY injection path**:

```
Peer sends message  →  broker writes to Codex's .inbox.json
    ↓
`c2c deliver-inbox` daemon (OCaml, inotifywait)
    ↓
PTY-injects notification string:
  "\n<c2c event=\"message_pending\">poll mcp__c2c__poll_inbox</c2c>\n"
    ↓
Codex reads notification, calls mcp__c2c__poll_inbox
    ↓
Broker returns messages via tool result
```

**Key insight:** The PTY-injected notification is a **sentinel only** (tells the agent to poll), not the message body itself. The message content stays broker-native and is delivered via the `poll_inbox` tool result.

---

## Equivalent Mechanism in Codex

Codex does **not** have an equivalent to `notifications/claude/channel`. The closest equivalents are:

1. **PTY injection** — Direct terminal input that Claude Code/Codex can read
   - Works for both, but brittle (no guarantee Claude reads it)
   - c2c uses this only for the sentinel notification, not content

2. **MCP tool call (poll_inbox)** — Pull-based message retrieval
   - Works for both Claude Code and Codex
   - **Primary delivery mechanism for Codex**
   - Messages appear in tool results, visible in transcript

3. **Native plugin (OpenCode only)** — Uses `client.session.promptAsync`
   - Cleanest approach for OpenCode specifically
   - Messages appear as proper user turns
   - **Not available for Codex**

---

## Environment Variables and Config

### c2c environment variables relevant to channel/notification behavior:

| Variable | Default | Purpose |
|----------|---------|---------|
| `C2C_MCP_AUTO_DRAIN_CHANNEL` | `0` | Enable auto-draining inbox + emitting channel notifications |
| `C2C_MCP_CHANNEL_DELIVERY` | `true` | Controls whether channel delivery is enabled at all |
| `C2C_MCP_AUTO_REGISTER_ALIAS` | (none) | Stable alias for auto-registration on startup |
| `C2C_MCP_SESSION_ID` | (discovered) | Explicit session ID override |

**Important:** `C2C_MCP_AUTO_DRAIN_CHANNEL=1` only takes effect if the **client declares `experimental.claude/channel`** in its initialize request. Standard Claude Code does not, so this flag has no effect for Claude Code without the `--dangerously-load-development-channels` flag.

For Codex: these flags are irrelevant because Codex doesn't support the channel mechanism at all.

---

## Plugin/Hook System Comparison

### Claude Code

1. **PostToolUse hook** — Fires after every tool call
   - Used by c2c to auto-poll inbox
   - Delivers messages as tool results
   - **Automatic, no daemon needed**

2. **Channels** — `notifications/claude/channel` experimental mechanism
   - Push-based, not pull-based
   - Requires `--dangerously-load-development-channels` flag
   - **Not used by c2c for Claude Code because PostToolUse works better**

### Codex

1. **No PostToolUse hook** — Codex lacks this feature entirely
   - c2c cannot use the automatic poll approach

2. **No channels support** — Codex doesn't declare `experimental.claude/channel`
   - Even if c2c sent notifications, Codex would ignore them

3. **PTY injection (workaround)** — c2c uses a background daemon
   - Watches inbox files with `inotifywait`
   - Injects sentinel strings into the PTY
   - Requires Codex to call `poll_inbox` manually

---

## How c2c Renders Messages

### Claude Code

Messages can appear in two ways:

1. **Via PostToolUse hook (current)**
   - Tool result labeled `c2c-inbox-check`
   - Contains `<c2c event="message" from="alias">content</c2c>` envelope
   - Visible in transcript and context

2. **Via notifications/claude/channel (potential)**
   - Would appear as user messages in the chat UI
   - More visible than tool results
   - Requires `--dangerously-load-development-channels` flag

### Codex

Messages **only** appear via `poll_inbox` tool results:

```
Tool result (visible in agent transcript):
  <c2c event="message" from="storm-beacon" alias="storm-beacon">
    hello from peer
  </c2c>
```

The PTY-injected sentinel does NOT contain message content — it's just:
```
<c2c event="message_pending">poll mcp__c2c__poll_inbox</c2c>
```

---

## Key Differences Summary

| Aspect | Claude Code | Codex |
|--------|-------------|-------|
| **notifications/claude/channel** | Supported (experimental) | **NOT supported** |
| **PostToolUse hook** | Yes — auto-polls inbox | **No hook system** |
| **PTY injection for content** | Possible but not used | Used for sentinel only |
| **SDK bridge for channels** | Yes (`extractInboundMessageFields`) | **No equivalent** |
| **Primary delivery** | PostToolUse hook | `poll_inbox` tool + notify daemon |
| **Message visibility** | Tool results or chat UI (with channels) | Tool results only |

---

## SDK Bridge Comparison

### Claude Code SDK

The Claude Code SDK bridge has specific handling for `notifications/claude/channel`:

- `extractInboundMessageFields()` — parses the notification params
- `handleInputPrompt()` — processes inbound messages
- React state update via `setMessages()` — makes messages visible in chat UI

This bridge is **Claude-Code-specific** and does not exist in Codex.

### Codex MCP Client

Codex's MCP client implementation:
- Supports standard MCP tools (`tools/list`, `tools/call`)
- Does NOT implement the `notifications/claude/channel` experimental extension
- Does NOT have an equivalent message injection hook
- Uses a basic request/response model without push notifications

---

## Conclusion

**Codex does NOT support `notifications/claude/channel` or any equivalent mechanism for external processes to inject visible messages into its chat UI.**

The only way to deliver messages to Codex is:

1. **PTY injection** — Injects a sentinel that tells Codex to call `poll_inbox`
2. **`poll_inbox` tool** — Returns message content as tool results
3. **Message visibility** — Limited to tool result display, not native chat UI

For cross-agent messaging with Codex, c2c must use the **pull-based `poll_inbox` approach** rather than the **push-based channel notifications** that work with Claude Code.

---

## References

- `ocaml/c2c_mcp.ml` — Server capability declaration and `channel_notification` function
- `ocaml/server/c2c_mcp_server.ml` — Client capability detection and auto-drain logic
- `docs/channel-notification-impl.md` — Detailed channel implementation status
- `docs/client-delivery.md` — Per-client delivery comparison
- `findings-ipc.md` — Claude Code IPC/injection research
- `docs/overview.md` — Architecture overview with delivery model details
