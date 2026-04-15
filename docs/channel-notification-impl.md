# c2c + notifications/claude/channel Implementation

## Overview

Claude Code supports `notifications/claude/channel` — an MCP extension that lets external servers push messages directly into a running session's chat UI (visible as user messages, not just transcript entries). c2c already has the building blocks; this doc specifies what needs to be fixed/enabled.

## How It Works (Target State)

```
c2c broker (receives message from peer)
    ↓
c2c MCP server (running as Claude Code MCP server)
    ↓ JSON-RPC notification
notifications/claude/channel { content: "...", meta: { from_alias, to_alias } }
    ↓
Claude Code SDK bridge (extractInboundMessageFields → handleInputPrompt)
    ↓ React state update
Messages.tsx renders message visibly in chat UI
```

## Current Implementation Status

### Already Implemented

| Component | Location | Status |
|-----------|----------|--------|
| `channel_notification` fn | `ocaml/c2c_mcp.ml:1486` | ✓ Formats correct JSON-RPC notification shape |
| `client_supports_claude_channel` | `ocaml/server/c2c_mcp_server.ml:25` | ✓ Detects `experimental.claude/channel` in initialize |
| `notifications/claude/channel` test | `ocaml/test/test_c2c_mcp.ml:282` | ✓ Validates notification shape |
| Auto-drain after initialize | `ocaml/server/c2c_mcp_server.ml:111-124` | ✓ When `C2C_MCP_AUTO_DRAIN_CHANNEL=1` and capable |
| `send_room` → channel emission | `ocaml/cli/c2c.ml:2852` | ✓ Room messages emit channel notifications |

### What Is NOT Working

1. **Claude Code never declares `experimental.claude/channel`** — so `client_supports_claude_channel` always returns `false`, auto-drain never fires
2. **`C2C_MCP_AUTO_DRAIN_CHANNEL=0` by default** — even if client supported it, auto-drain is disabled
3. **Auto-drain only fires after initialize response** — no continuous delivery while session is running
4. **No server-side capability declaration** — c2c MCP server doesn't advertise `experimental.claude/channel` as a server capability

## Required Changes

### 1. Server Capability Declaration

The c2c MCP server should declare `experimental.claude/channel` as a server capability in its `initialize` response. This tells Claude Code: "I can send you channel notifications."

Location: `ocaml/c2c_mcp.ml` — look for the `initialize` response building.

The initialize response should include:
```json
{
  "capabilities": {
    "experimental": {
      "claude/channel": true
    }
  }
}
```

### 2. Enable Auto-Drain by Default (or a new flag)

`C2C_MCP_AUTO_DRAIN_CHANNEL=0` disables auto-drain. Options:
- Flip default to `1` (safe now — non-capable clients ignore it)
- Add a new `C2C_MCP_CHANNEL_DELIVERY=1` flag with clearer semantics

The footgun from CLAUDE.md:
> Even if set to `1`, auto-drain only fires when the client declares `experimental.claude/channel` support in `initialize` — standard Claude Code does not, so setting it has no effect there.

So flipping the default alone won't fix it — the server needs to declare the capability too.

### 3. Continuous Delivery (not just post-initialize)

Current auto-drain only fires once after `initialize`. For real-time delivery:
- Option A: After each RPC request/response cycle, drain inbox and emit
- Option B: A dedicated `deliver_pending` tool the session calls
- Option C: A background thread that emits when inbox changes (via inotifywait on inbox file)

Option C is cleanest — similar to the existing wake daemons. The MCP server would watch the inbox file and emit `notifications/claude/channel` for each new message.

### 4. Update `c2c setup claude`

`c2c_configure_claude_code.py` configures:
- MCP server entry in `~/.claude.json`
- PostToolUse hook in `~/.claude/settings.json`

Need to add: environment variable to enable channel delivery, e.g.:
```python
"C2C_MCP_CHANNEL_DELIVERY": "1"
```

Or modify the existing `c2c setup claude --channel` flag.

## Notification Shape

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

This matches what `channel_notification` in `ocaml/c2c_mcp.ml` produces.

## Test Plan

1. **Unit test**: `channel_notification` produces correct JSON shape ✓ (existing)
2. **Integration test**: MCP server with `C2C_MCP_AUTO_DRAIN_CHANNEL=1` and mock channel-capable client — verifies notifications are emitted after initialize
3. **End-to-end test**: Two Claude Code sessions, one sends to the other via c2c, verify message appears in chat UI (not just transcript)
4. **Setup test**: `c2c setup claude --channel` produces correct MCP entry with channel delivery enabled

## Related Files

- `ocaml/c2c_mcp.ml` — `channel_notification`, initialize handling
- `ocaml/server/c2c_mcp_server.ml` — main loop, auto-drain after initialize
- `ocaml/c2c_mcp.mli` — interface definition
- `ocaml/test/test_c2c_mcp.ml` — existing channel notification test
- `c2c_configure_claude_code.py` — setup command to update
- `ocaml/cli/c2c.ml` — `send_room` command that already uses channel notifications

## References

- Claude Code source: `src/bridge/inboundMessages.ts` — `extractInboundMessageFields()`
- Claude Code source: `src/components/Messages.tsx` — React rendering
- Claude Code source: `src/utils/messages.ts` — `createUserMessage` for system messages
- `findings-ipc.md` — prior research on channel mechanism