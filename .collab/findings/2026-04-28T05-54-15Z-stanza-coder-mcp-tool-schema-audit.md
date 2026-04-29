# MCP tool schema audit — `ocaml/c2c_mcp.ml`

**Author:** stanza-coder
**Date:** 2026-04-28T05-54-15Z
**Scope:** read-only audit of `tool_definition` schemas vs. handler arg parsing.

## 1. Inventory (32 base + 1 dev-only)

`grep -n "tool_definition" ocaml/c2c_mcp.ml` shows the constructor on
L259 and 33 call-sites between L3098 and L3258. `base_tool_definitions`
(L3107) lists 32 tools; `debug_tool_definition` (L3098) is appended only
when `Build_flags.mcp_debug_tool_enabled` (L3261-3264).

Tools defined: `register, list, send, whoami, poll_inbox, peek_inbox,
sweep, send_all, join_room, leave_room, delete_room, send_room,
list_rooms, my_rooms, room_history, history, tail_log, server_info,
prune_rooms, send_room_invite, set_room_visibility, set_dnd, dnd_status,
open_pending_reply, check_pending_reply, set_compact, clear_compact,
stop_self, memory_list, memory_read, memory_write` + `debug` (dev).

## 2. Handler ↔ schema coverage

Cross-referenced the `match tool_name with | "..." ->` dispatch
(L3850-5500ish). **Every handler has a corresponding `tool_definition`,
and every `tool_definition` has a handler.** No orphans either way. The
`pre-register` whitelist at L3470-3473 (which session-binds tools that
need an alias before dispatch) lines up with the same set.

## 3. Discriminator coverage (`tail_log`, #335)

`tail_log` schema at L3179-3182 explicitly documents the discriminated
union: `tool`-keyed entries record RPC events (`{ts, tool, ok}`) and
`event`-keyed entries record subsystem events including
`send_memory_handoff` (#327) and `nudge_tick`/`nudge_enqueue` (#335).
Matches handler at L4646-4693, which simply returns the last N raw JSON
lines — no shape massaging, so the schema's union framing is the
authoritative reader spec. Confirmed accurate.

## 4. `deferrable` / `ephemeral` flag coverage

- `send` (L3120-3123): both flags documented in description and listed
  as `bool_prop` in properties. Description correctly notes that
  `ephemeral` is silently ignored on the relay side in v1 for
  `alias@host` recipients. Matches handler at L4126-4135.
- `send_all` (L3143-3146): no `deferrable` / `ephemeral` properties.
  Verified handler at L4286 — neither flag is read, so this is correct
  by design (broadcast does not currently support either).
- `send_room` (L3159-3162): no `deferrable` / `ephemeral`. Confirmed by
  CLAUDE.md note that "rooms NEVER use `deferrable`
  (`fan_out_room_message` hardcodes `false`)". Schema correctly omits
  the flag. `ephemeral` for rooms is a non-goal (rooms are inherently
  shared / archived). Correct.
- Memory handoff DM (`memory_write`) is `deferrable: false` after #307b
  per CLAUDE.md; the schema does not expose that internal flag, which
  is correct since callers don't control it.

## 5. Spot-check: schema field types vs handler parsing

### `tail_log` (L3179, handler L4646)
Schema: `int_prop "limit"`. Handler: `Broker.int_opt_member "limit"`,
clamps `<1 → 1`, `>500 → 500`, default 50. **Match.**

### `room_history` (L3171, handler L4948)
Schema: `prop "room_id"` (string, required), `int_prop "limit"`,
`float_prop "since"`. Handler: `string_member "room_id"`,
`int_opt_member "limit"` (default 50), `float_opt_member "since"`
(default 0.0). **Match.** Schema description correctly notes "Unix epoch
float".

### `send` (L3120, handler L4102)
Schema: `to_alias` (string, required), `from_alias` (string),
`content` (string, required), `deferrable` (bool), `ephemeral` (bool).
Handler: `string_member_any ["to_alias"; "alias"]`,
`string_member "content"`, `Yojson member "deferrable" → \`Bool b`,
likewise `ephemeral`. **Types match.** Note: the handler also accepts
`alias` as an alias for `to_alias` (OpenCode footgun fix per the
inline comment at L3287-3293), but the schema only advertises
`to_alias` — that's fine since `alias` is a compatibility fallback,
not a documented surface.

## 6. Issues found — type drift in `memory_*` schemas

**Severity: low (cosmetic / spec-correctness, runtime accepts JSON
booleans regardless).**

1. **`memory_write` `shared`** (L3256): declared as `prop` (string) but
   handler at L5442-5445 only accepts `\`Bool` (anything else → false).
   Should be `bool_prop`.
2. **`memory_write` `shared_with`** (L3257): declared as `prop` (string)
   but handler at L5446-5455 accepts both `\`String s` (CSV) and
   `\`List` of strings. Schema either needs an array variant via
   `arr_prop` or its description should explicitly call out the CSV
   contract. Today a well-typed client following the schema strictly
   gets the CSV path only.
3. **`memory_list` `shared_with_me`** (L3244): declared as `prop`
   (string) but handler at L5234-5236 expects `\`Bool`. Should be
   `bool_prop`. Description text says "When true…", reinforcing the
   intent.

These are the only schema-vs-handler mismatches I found. The runtime
behavior is conservative (non-bool → false, etc.) so no correctness bug,
just spec drift that could confuse a strict client or schema-driven
auto-complete.

## 7. Other observations (not bugs)

- `register` description correctly notes the `C2C_MCP_AUTO_REGISTER_ALIAS`
  env-var fallback (L3109), aligning with the env-var docs in CLAUDE.md.
- `debug.payload` is the only property declared inline as an `object`
  type (L3104) rather than via the `prop`/`bool_prop`/etc. helpers —
  intentional because it's polymorphic. Description correctly flags the
  `send_raw_to_self` string-only requirement.
- `set_dnd.until_epoch` correctly uses `float_prop` (L3204), matching
  the handler's float epoch usage.
- `stop_self`, `clear_compact`, `dnd_status`, `list`, `list_rooms`,
  `my_rooms`, `sweep`, `prune_rooms`, `server_info` correctly declare
  `~required:[] ~properties:[]` for fully-implicit (session-derived)
  invocations.

## Recommendation

Single small follow-up: convert the three `prop` calls noted in §6 to
`bool_prop` (×2) and document the array form for `shared_with`. Pure
schema fix — no handler change needed. Slice fits in <10 LOC.

Outside that, the schema layer is in good shape and the #335 union
note for `tail_log` is correctly reflected.
