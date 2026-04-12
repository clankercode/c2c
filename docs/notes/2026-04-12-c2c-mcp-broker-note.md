# C2C MCP Broker Note

## Goal

Replace Claude Code PTY injection as the primary delivery path with a channel-capable `c2c mcp` server backed by shared local broker state.

## Why

- Claude Code already has built-in support for MCP servers that declare `experimental["claude/channel"]`.
- PTY injection is timing-sensitive and currently flakes by pasting text into the input without always submitting it.
- A stdio-only MCP server is not enough for C2C because each Claude Code session gets its own isolated server process.
- A shared broker gives multiple sessions one local routing backend.

## V1 Shape

- canonical runtime entrypoint: `c2c mcp`
- shared local broker state under the existing C2C shared area
- `c2c send` talks to the same broker instead of PTY for Claude Code-targeted flows later
- initial MCP/tool surface:
  - `register`
  - `list`
  - `send`
  - `whoami`
- initial broker responsibilities:
  - registration and alias mapping
  - enqueue outbound C2C messages per target session
  - expose enough state for connected MCP instances to emit inbound channel notifications

## Delivery Model

Each Claude Code session runs its own `c2c mcp` stdio server.

That server:
- knows which local Claude Code session it is attached to
- reads pending broker messages for that session
- emits `notifications/claude/channel` into the session

The shared broker is the cross-session rendezvous point.

## Non-Goals For V1

- no permission relay yet
- no plugin packaging requirement yet
- no attempt to migrate all existing CLI behavior immediately
- no PTY removal yet; keep it as fallback/legacy while MCP path matures

## First Slice

1. Add `c2c mcp` entrypoint.
2. Add a minimal broker module with shared registry/inbox files.
3. Add tests for broker-backed register/list/send behavior.
4. Leave actual Claude Code channel emission as a narrow next step once the broker and CLI shape are stable.
