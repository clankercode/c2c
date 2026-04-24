# join_room missing session override — stale MCP server process

## Symptom
`mcp__c2c__whoami` resolves identity correctly, but `mcp__c2c__join_room` returns:
`join_room: missing member alias. Register this session first or pass alias explicitly.`

## Root Cause (confirmed)
`join_room` was missing from the session-override allowlist in `request_session_id_override`
(c2c_mcp.ml:2598). When Codex calls MCP tools, the thread ID metadata is attached to each
request, and `request_session_id_override` maps thread ID → session_id for tools in the allowlist.
`join_room` was not in the allowlist, so its calls couldn't be routed to the correct session.

Fix committed: `ee57a00` — added `join_room` and `leave_room` to the allowlist.

## Why whoami worked but join_room didn't
Both use the same underlying resolution chain:
- `whoami` at line 3360: `resolve_session_id ?session_id_override arguments` then looks up by session_id
- `join_room` at line 3781: `alias_for_current_session_or_argument ?session_id_override broker arguments`
  → `current_registered_alias ?session_id_override broker` → same resolution path

Both go through `resolve_session_id` which respects `session_id_override` from the allowlist.
So `whoami` working means the allowlist WAS being hit for it (since before ee57a00, `whoami`
was already in the allowlist). The difference: `whoami` doesn't require the alias to be
registered — it returns empty string if not found. `join_room` returns the error if alias is None.

Actually — wait. Let me re-examine. Before ee57a00:
- whoami: in allowlist → session_id_override works → whoami resolves correctly
- join_room: NOT in allowlist → session_id_override = None → falls back to `current_session_id()`
  which returns the raw thread ID (not the managed session ID) → no registration found → error

So `whoami` worked because it was already in the allowlist from an earlier commit (324ad08).
`join_room` failed because it wasn't.

## Secondary issue: stale MCP server process
Even after ee57a00, lyra-quill's Codex still showed the error. Reason: the MCP server
is a long-running daemon. `/plugin reconnect` only refreshes the tool list, not the
underlying broker process. A FULL session restart (killing and re-spawning the Codex outer
loop) was needed to pick up the new `c2c-mcp-server` binary.

## Fixes applied
1. `ee57a00`: add `join_room`/`leave_room` to session override allowlist
2. `126a8b9` (jungle-coder): S5c dedup — unrelated but also needed for clean build
3. `4a48d1f` (galaxy-coder): expose `write_allowed_signers_entry` in Broker mli signature

## Resolution
After a full Codex session restart, lyra-quill confirmed `join_room` should work correctly.

## Severity
Medium — broke room functionality for Codex peers. Fixed.
