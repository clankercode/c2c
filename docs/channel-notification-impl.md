# c2c + notifications/claude/channel Implementation

## Overview

Claude Code supports `notifications/claude/channel` — an MCP extension that lets external servers push messages directly into a running session's chat UI (visible as user messages, not just transcript entries). c2c implements this end-to-end: the server declares the capability, watches the inbox, and emits channel notifications for incoming messages.

## How It Works

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

## Implementation Status

All server-side components are implemented and working. The one remaining gap is on the client side: **Claude Code never declares `experimental.claude/channel` in its `initialize` request**, so the per-RPC auto-drain path (which requires client capability) never fires for standard sessions. The continuous inbox watcher works regardless of client capability.

### Implemented Components

| Component | Location | Status |
|-----------|----------|--------|
| `channel_notification` fn | `ocaml/c2c_mcp.ml:1486` | Working. Formats correct JSON-RPC notification shape. |
| Server capability declaration | `ocaml/c2c_mcp.ml:62-66` | Working. Server advertises `experimental.claude/channel: {}` in `initialize` response. |
| `client_supports_claude_channel` | `ocaml/server/c2c_mcp_server.ml:32` | Working. Detects `experimental.claude/channel` in client's `initialize` params. |
| `notifications/claude/channel` test | `ocaml/test/test_c2c_mcp.ml:282` | Passing. Validates notification shape. |
| Server capability test | `ocaml/test/test_c2c_mcp.ml:316-319` | Passing. Verifies server declares `claude/channel` capability. |
| Continuous inbox watcher (standalone) | `ocaml/server/c2c_mcp_server.ml:104-139` | Working. Polls inbox file every 1s and emits channel notifications for new messages. |
| Auto-drain after each RPC (standalone) | `ocaml/server/c2c_mcp_server.ml:159-174` | Working. Drains inbox after each request when `C2C_MCP_AUTO_DRAIN_CHANNEL=1` and client is capable. |
| Auto-drain after each RPC (serve cmd) | `ocaml/cli/c2c.ml:2842-2855` | Working. Same per-RPC drain logic in the `c2c serve` command. |
| `c2c setup claude` configuration | `c2c_configure_claude_code.py:102` | Working. Sets `C2C_MCP_CHANNEL_DELIVERY=1` in MCP server env. |

### Known Limitation

**Claude Code does not declare `experimental.claude/channel` support.** The client's `initialize` request never includes this capability, so `client_supports_claude_channel` always returns `false`. This means the per-RPC auto-drain path (which gates on `channel_capable`) never fires in standard Claude Code sessions.

The continuous inbox watcher in the standalone server does not gate on client capability — it fires whenever `C2C_MCP_CHANNEL_DELIVERY` is enabled and a session ID is set, which is the default for `c2c setup claude` sessions. In practice, this is the delivery path that works.

## Standalone Server vs. `c2c serve` Command

The c2c MCP server runs in two modes with different behavior:

| Feature | Standalone (`c2c_mcp_server.ml`) | `c2c serve` (`c2c.ml`) |
|---------|----------------------------------|------------------------|
| Continuous inbox watcher | Yes (1s poll loop, lines 104-139) | No |
| Per-RPC auto-drain | Yes (lines 159-174) | Yes (lines 2842-2855) |
| `C2C_MCP_CHANNEL_DELIVERY` default | `true` (line 16) | N/A (no inbox watcher) |
| `C2C_MCP_AUTO_DRAIN_CHANNEL` default | Follows `C2C_MCP_CHANNEL_DELIVERY` (line 23) | `false` (line 2752) |

The standalone server is what `c2c setup claude` configures. It has the continuous inbox watcher that provides near-real-time delivery regardless of client capability. The `c2c serve` command only has per-RPC auto-drain, which requires both `C2C_MCP_AUTO_DRAIN_CHANNEL=1` and a channel-capable client.

## Inbox Watcher Details

The continuous inbox watcher (`start_inbox_watcher` in `c2c_mcp_server.ml:104-139`) runs as an Lwt async task alongside the main RPC loop:

1. Polls the inbox file size every 1 second via `Unix.stat`.
2. When file size increases beyond the last known size, drains the inbox and emits channel notifications.
3. Uses **post-drain file size** (not pre-drain) to avoid missing shorter subsequent messages when a previous batch was larger.
4. Continues looping when the inbox file is missing (stat returns size 0 on `Unix_error`).
5. Catches and logs exceptions, then continues watching — transient errors (file locks, permission races) do not kill the watcher.

## Completed Implementation History

The following items were originally tracked as "Required Changes" and have all been completed:

1. **Server capability declaration** — The `initialize` response now includes `"experimental": { "claude/channel": {} }` in capabilities (`ocaml/c2c_mcp.ml:62-66`).

2. **Channel delivery enabled by default** — `C2C_MCP_CHANNEL_DELIVERY` defaults to `true` in the standalone server (`c2c_mcp_server.ml:11-16`). `c2c setup claude` also explicitly sets `C2C_MCP_CHANNEL_DELIVERY=1` (`c2c_configure_claude_code.py:102`).

3. **Continuous delivery** — The inbox watcher background thread provides near-real-time delivery without depending on RPC traffic or client capability. This is the primary delivery mechanism.

4. **Setup integration** — `c2c setup claude` writes `C2C_MCP_CHANNEL_DELIVERY=1` into the MCP server environment configuration.

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

This matches what `channel_notification` in `ocaml/c2c_mcp.ml:1486` produces.

## Environment Variables

| Variable | Default (standalone) | Default (`c2c serve`) | Purpose |
|----------|---------------------|----------------------|---------|
| `C2C_MCP_CHANNEL_DELIVERY` | `true` | N/A | Enables the continuous inbox watcher in the standalone server |
| `C2C_MCP_AUTO_DRAIN_CHANNEL` | Same as `CHANNEL_DELIVERY` | `false` | Enables per-RPC auto-drain (requires channel-capable client) |
| `C2C_MCP_SESSION_ID` | (none) | (none) | Required for both watcher and auto-drain to know which inbox to watch |

## Test Coverage

1. **Unit test**: `channel_notification` produces correct JSON shape — `test_c2c_mcp.ml:282`
2. **Capability test**: Server declares `experimental.claude/channel` in `initialize` — `test_c2c_mcp.ml:316-319`
3. **Integration test**: MCP server with `C2C_MCP_AUTO_DRAIN_CHANNEL=1` and mock channel-capable client — verifies notifications are emitted after initialize
4. **End-to-end**: Two Claude Code sessions, one sends to the other via c2c — message appears in chat UI (requires Claude Code to surface channel notifications)

## Related Files

- `ocaml/c2c_mcp.ml` — `channel_notification` (line 1486), `capabilities` with channel declaration (line 62), initialize handling
- `ocaml/server/c2c_mcp_server.ml` — standalone server: inbox watcher (lines 104-139), auto-drain (lines 159-174), env defaults
- `ocaml/cli/c2c.ml` — `c2c serve` command: auto-drain (lines 2842-2855), defaults auto-drain to `false` (line 2752)
- `ocaml/c2c_mcp.mli` — interface definition
- `ocaml/test/test_c2c_mcp.ml` — channel notification test (line 282), capability test (line 316)
- `c2c_configure_claude_code.py` — `c2c setup claude` sets `C2C_MCP_CHANNEL_DELIVERY=1` (line 102)

## References

- Claude Code source: `src/bridge/inboundMessages.ts` — `extractInboundMessageFields()`
- Claude Code source: `src/components/Messages.tsx` — React rendering
- Claude Code source: `src/utils/messages.ts` — `createUserMessage` for system messages
- `findings-ipc.md` — prior research on channel mechanism
