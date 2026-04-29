# Envelope rename audit — `from_alias` / `to_alias` → `from` / `to`

**Slice:** `slice/envelope-rename-from-to`
**Author:** stanza-coder (subagent of slate-coder, dispatched for envelope rename)
**Date:** 2026-04-29T18-30-00Z

## Goal

Rename the **textual envelope-attribute names** visible to agents in their
transcripts:

- `from_alias=` → `from=`
- `to_alias=` → `to=`

ONLY in `<c2c>` / `<channel>` envelope tags written into agent
transcripts. **Not** OCaml record fields, function args, MCP
tool-input JSON, broker storage shapes, or relay outbox fields.

## Audit findings

### `<c2c>` envelope serialization sites

All `<c2c>` envelope construction sites already use **`from=`** and
**`alias=`** (where `alias` carries the recipient). None emit
`from_alias=` or `to_alias=` as XML attributes:

- `ocaml/c2c_mcp.ml:495-503` — broker-side push envelope: `<c2c event="message" from="%s" alias="%s" source="broker" reply_via="%s" action_after="continue"…>`
- `ocaml/cli/c2c.ml:8323-8328` — `render_payload` PTY-injected envelope: `<c2c event=%S from=%S alias=%S source="pty" …>`
- `c2c_poll_inbox.py:287-289` — Python poll-inbox formatter: `<c2c event="message" from="…" alias="…">`
- `c2c_kimi_wire_bridge.py:217` — Kimi wire-bridge formatter: `<c2c event="message" from="…" alias="…">`
- `c2c_deliver_inbox.py:109` — Codex deliver-inbox formatter: `<c2c event="message" from="…" alias="…">`
- `claude_send_msg.py:103` — caller-supplied attrs (already canonical)
- `c2c_poker.py:150`, `deprecated/c2c_inject.py:72` — caller-supplied attrs

**Conclusion: `<c2c>` envelope is already canonical. No changes needed.**

### `<channel>` envelope (channel-notification)

The `notifications/claude/channel` JSON-RPC notification has its
`params.meta` JSON object rendered by Claude Code as XML attributes
on a `<channel …>` tag in agent transcripts (per
`.collab/research/2026-04-13T16-00-00Z-kimi-nova-claude-code-plugin-research.md`
line 71: "Claude Code receives this wrapped in a `<channel>` tag in
its context").

**Single site that emits `from_alias` / `to_alias` as transcript-visible attribute names**:

- `ocaml/c2c_mcp.ml:4261-4276` — `channel_notification` builds:
  ```ocaml
  let base = [ ("from_alias", `String from_alias); ("to_alias", `String to_alias) ] in
  ```
  These keys become XML attribute names on the rendered `<channel>` tag.

This is **the** confusion site reported 2026-04-29 (multiple agents
misread `to_alias=alice#room` as a sender field).

### Test fixtures asserting the rendered meta keys

- `ocaml/test/test_c2c_mcp.ml:432, 434` — `test_channel_notification_matches_claude_channel_shape`
- `ocaml/test/test_c2c_mcp.ml:448, 450` — `test_channel_notification_empty_content`
- `ocaml/test/test_c2c_mcp.ml:564` — `test_channel_notification_with_role`

These read `meta |> member "from_alias"` / `"to_alias"`. Must be
updated to `"from"` / `"to"`.

### Docs documenting the channel meta shape

- `docs/channel-notification-impl.md:14, 89, 90` — text + JSON example
- `docs/c2c-research/codex-channel-notification.md:30` — text snippet

### Out of scope (NOT renamed)

Kept as-is per task spec — these are internal data shapes / API
parameter names, not transcript-visible envelope attributes:

- OCaml record fields `from_alias` / `to_alias` on
  `C2c_mcp.message`, `room_message`, archive entry, etc. — internal
  struct fields.
- MCP tool-input JSON `from_alias` / `to_alias` on the `send` tool
  (`c2c_mcp.ml:4421-4422`, `5087`, `5458`) — JSON parameter names of
  the tool's input schema; renaming would break every running
  agent's send-tool calls.
- MCP tool-output / receipt JSON keys on `send`'s response.
- Broker inbox JSON files (`<sid>.inbox.json`) — on-disk schema.
- Relay outbox / forwarder JSON envelopes (`relay.ml`,
  `relay_forwarder.ml`, `relay_remote_broker.ml`,
  `c2c_relay_connector.ml`) — wire format between brokers.
- Archive entry JSON keys (`c2c_mcp.ml`, `cli/c2c.ml`,
  `cli/c2c_rooms.ml`, `cli/c2c_stats.ml`) — local storage schema.
- Wire-bridge JSON (`c2c_wire_bridge.ml`) — internal pipe format.
- Function labeled args `~from_alias` / `~to_alias` — internal API.
- Test fixture record literals using internal field names.
- Findings-archive doc references — historical artifacts.

## Plan

1. Edit `ocaml/c2c_mcp.ml` line 4263: `"from_alias"` → `"from"`,
   `"to_alias"` → `"to"`.
2. Update 5 test assertions in `ocaml/test/test_c2c_mcp.ml`.
3. Update 4 doc references (2 files).
4. Build + check + test in slice worktree, all rc=0.
5. Live dogfood: verify rendered envelope shape via test output.
6. Single commit.
