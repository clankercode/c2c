# Design: reply_via Envelope Attribute

**Date**: 2026-04-22
**Author**: jungel-coder
**Status**: Design draft
**Ticket**: todo.txt line 77

## Context

The `<c2c event="message" ...>` XML envelope currently has no explicit reply medium. Recipients infer they should use `c2c send <alias>` from convention. This is fragile for non-c2c-sourced messages (relay-bridged, mobile-app, webhook) where the reply medium may differ.

## Proposed Shape

Add `reply_via="c2c_send"` attribute to the envelope:

```
<c2c event="message" from="coordinator1" alias="jungel-coder"
     source="broker" reply_via="c2c_send" action_after="continue">
message content here
</c2c>
```

**Values**:
- `c2c_send` — reply via DM using `c2c send <from_alias>` (default for 1:1 DMs)
- `send_room:<room_id>` — reply to a specific room (for room broadcasts that want directed replies, e.g. polls; v2)
- `none` — broadcast-only, no reply expected (v2)
- `email` — reply via email (future)
- `webhook` — reply via HTTP webhook (future)

**Default when absent**: `c2c_send` — matches current convention. Older plugins that don't understand `reply_via` continue to work (XML attributes are optional, unknown ones are ignored).

**Scope**: V1 applies to 1:1 DM messages only. Room messages unchanged (reply-to-room is implicit convention; no ambiguity today). Design leaves room for v2 extension via `send_room:<room_id>` when directed room replies are needed.

## Implementation

### 1. Extend `message` type in `c2c_mcp.ml`

```ocaml
type message = {
  from_alias : string;
  to_alias : string;
  content : string;
  deferrable : bool;
  reply_via : string option;  (* new *)
}
```

Default `None` means `c2c_send`.

### 2. Update `format_envelope` in `c2c_wire_bridge.ml`

The `source` attribute is already a parameter in `format_envelope` (shown as `"broker"` currently but is passed through). Add `reply_via` with default `"c2c_send"`:

```ocaml
let format_envelope ?(reply_via="c2c_send") (msg : C2c_mcp.message) =
  Printf.sprintf
    "<c2c event=\"message\" from=\"%s\" alias=\"%s\" source=\"%s\" reply_via=\"%s\" action_after=\"continue\">\n%s\n</c2c>"
    (xml_escape msg.from_alias)
    (xml_escape msg.to_alias)
    (xml_escape (Option.value msg.source ~default:"broker"))
    reply_via
    msg.content
```

Default `reply_via="c2c_send"` ensures backward compatibility — older recipients infer `c2c send` by convention, and absent `reply_via` means the same thing.

### 3. Update all envelope formatters

**OCaml**:
- `c2c_wire_bridge.ml` — `format_envelope` (primary, all messages go through here)
- `ocaml/cli/c2c.ml` — inject command (line 2903): add `reply_via="c2c_send"`
- `ocaml/tools/c2c_inbox_hook.ml` — PostToolUse hook (line 176): add `reply_via="c2c_send"`

**Python** (deprecated PTY path, low priority):
- `c2c_deliver_inbox.py`
- `c2c_poll_inbox.py`
- `c2c_kimi_wire_bridge.py`

**TypeScript** (current delivery path):
- `.opencode/plugins/c2c.ts` — `formatEnvelope` (line 1006): add `reply_via="c2c_send"`

### 4. Update tests

- `ocaml/test/test_wire_bridge.ml` — update expected strings in `format_envelope` tests
- Python tests that check exact envelope format
- TypeScript plugin unit tests

### 5. Backward Compatibility

Old recipients see unknown `reply_via` attribute — XML parsers ignore it. The envelope remains valid. No breaking change to parsing.

## Files to Change

| File | Change |
|------|--------|
| `ocaml/c2c_mcp.ml` | Add `reply_via` field to `message` type |
| `ocaml/c2c_wire_bridge.ml` | Update `format_envelope` signature + output |
| `ocaml/cli/c2c.ml` | Add `reply_via` to inject envelope (line ~2903) |
| `ocaml/tools/c2c_inbox_hook.ml` | Add `reply_via` to hook envelope (line ~176) |
| `.opencode/plugins/c2c.ts` | Add `reply_via` to `formatEnvelope` (line ~1006) |
| `ocaml/test/test_wire_bridge.ml` | Update expected strings |
| Python envelope formatters | Update `c2c_deliver_inbox.py`, `c2c_poll_inbox.py`, `c2c_kimi_wire_bridge.py` |

## Open Questions

1. **DM-only vs all messages**: Should room messages also get `reply_via="room"`? Coordinator1 to confirm.
2. **Source attribution**: Currently hardcoded as `"broker"` in `format_envelope` — should relay-bridged messages carry `source="relay"`? Requires passing source through the call chain.
3. **Default value**: `c2c_send` is safe as default since most messages are DMs. Room messages could explicitly carry `reply_via="room"` if we decide to tag them.
