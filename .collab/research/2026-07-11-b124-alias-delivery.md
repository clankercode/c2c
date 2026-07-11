# B124 inbound identity guidance research

## Task model

- Goal: every LLM-visible inbound c2c delivery should state the recipient's c2c identity, distinguish it from the sender, and retain exact reply guidance.
- Blockers: codebase-memory MCP is unavailable (recorded separately); targeted repository search is the approved fallback. No product decision blocks implementation.
- Acceptance interpretation: use concise trusted reminder text, strip room/relay routing suffixes from the displayed recipient identity, escape both identities against markup/reminder injection, preserve DM versus room reply behavior, mirror the wording in the OpenCode plugin, and cover canonical drain/push renderers with focused tests.

## Delivery-path map

- `C2c_mcp_helpers.format_reply_hint` is the canonical broker-agnostic reminder formatter.
- `C2c_mcp_helpers.format_c2c_envelope` appends it for envelope paths; callers enabling it include the wire bridge, hook delivery, PTY injection, and OCaml deliver-watch path.
- `C2c_mcp_helpers_post_broker.channel_notification` calls the same helper for Claude channel push.
- `opencode-c2c/c2c.ts` mirrors the helper because OpenCode injects its own transcript-visible envelope; its embedded OCaml artifact is generated from this source.
- Codex hooks render through `C2c_hook_lib.format_messages_as_text` and the canonical envelope helper.
- Kimi's canonical notification-store path carries broker messages into Kimi; the removed/deprecated wire bridge is not a current independent contract.
- Root Python renderers are legacy/deprecated compatibility surfaces; the OCaml binary is the source of truth. B124 should not expand changes into deprecated paths unless a current test proves they are live.

## Wording decision

Use: `Your c2c alias is <recipient>; this direct/room message is from <sender>.` This is concise and less ambiguous than “you received ... from ...”, explicitly binds both roles, and leaves the existing exact reply call immediately below it.

For `recipient#room-id` and `recipient#12hexhost`, display only `recipient`; the decorated value remains in the envelope's `to` metadata for routing context.
