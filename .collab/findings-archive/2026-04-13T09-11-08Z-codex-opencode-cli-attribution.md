# OpenCode CLI fallback stamped replies as c2c-send

## Symptom

During the Codex -> OpenCode direct DM proof, Codex received the requested reply
text twice, but the reply messages were stamped `from_alias=c2c-send` instead of
`from_alias=opencode-local`.

## Discovery

The content round-trip worked after refreshing `opencode-local` to the live TUI
pid and waking OpenCode with delayed PTY injection. The returned inbox messages
contained the expected content:

`codex-opencode direct DM received 2026-04-13T09:05Z`

but their `from_alias` was `c2c-send`.

## Root Cause

OpenCode's CLI fallback inherits MCP-style identity environment variables:

- `C2C_MCP_SESSION_ID=opencode-local`
- `C2C_MCP_AUTO_REGISTER_ALIAS=opencode-local`

`c2c_send.py` only resolved sender identity from the older Claude-oriented
`C2C_SESSION_ID` / `C2C_SESSION_PID` path plus the YAML registry. When those
were absent, broker-only sends fell back to `c2c-send`.

## Fix Status

Fixed in `c2c_send.py` by resolving `C2C_MCP_SESSION_ID` through the broker
registry before the legacy Claude-only sender lookup. This applies to both:

- broker-only sends (`from_alias` in inbox JSON)
- PTY delegate sends (`sender_name` passed to `claude_send_msg`)

Focused tests cover both paths.

Live smoke:

`C2C_MCP_SESSION_ID=opencode-local ./c2c-send codex ...`

arrived in Codex's inbox as:

`from_alias=opencode-local`

## Severity

Medium. The message content arrived, but attribution is part of the broker
contract and matters for routing replies, game verification, and trust in mixed
client conversations.
