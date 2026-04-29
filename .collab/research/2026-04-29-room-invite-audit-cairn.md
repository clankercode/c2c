# Room Invite Flow Audit

Auditor: cairn (subagent of cairn-vigil / coordinator1)
Date: 2026-04-29
Scope: read-only audit of `send_room_invite` end-to-end across MCP broker and relay.
Method: source trace `ocaml/c2c_mcp.ml`, `ocaml/cli/c2c_rooms.ml`, `ocaml/relay.ml`,
plus tests in `ocaml/test/test_c2c_mcp.ml` and `ocaml/test/test_relay_auth_matrix.ml`.

## Current Implementation Summary

Two surfaces:

1. **Local broker (MCP + CLI)** — `Broker.send_room_invite` in
   `ocaml/c2c_mcp.ml:2853-2863`. CLI: `c2c rooms invite ROOM ALIAS`
   (`ocaml/cli/c2c_rooms.ml:388-416`). MCP tool: `send_room_invite`
   (`ocaml/c2c_mcp.ml:3736`, dispatch at `:5695`).
2. **Relay (signed)** — `handle_room_invite_op` (`ocaml/relay.ml:3410`)
   serving `POST /invite_room` and `POST /uninvite_room`. CLI:
   `c2c rooms invite --room … --alias … --invitee-pk …` against a relay
   (`ocaml/cli/c2c.ml:3986-4025`). Body-signed Ed25519 (ctx
   `c2c/v1/room-invite`).

Persisted state:

- Broker: `meta.invited_members` list inside per-room
  `<broker_root>/rooms/<room_id>/meta.json`.
- Relay: `room_invites` table (sqlite) keyed on
  `(room_id, identity_pk_b64)`.

Both surfaces share a single semantic: invite = "append the invitee's
identity to an ACL". Nothing else.

## E2E Flow Trace

### Sender (alice, member of `secret-club`)

1. `c2c rooms invite secret-club bob` (or `mcp__c2c__send_room_invite`).
2. CLI/MCP resolves alice's alias from session.
3. `Broker.send_room_invite`:
   - `valid_room_id` check.
   - `load_room_meta` — silently `mkdir`s the room dir if it doesn't
     exist (see Gap G5).
   - Membership check: only existing room members can invite.
   - If invitee already in `invited_members`, no-op (silent).
   - Else: append invitee_alias to `meta.invited_members`, save.
4. Returns `{ok:true, room_id, invitee_alias}`. **No further side
   effects.**

### Recipient (bob)

There is **no inbound notification of any kind**. Specifically:

- No DM to bob's inbox.
- No `notifications/claude/channel` push.
- No log line in bob's audit log (only in broker.log on the sending
  RPC, which bob never reads).
- No "pending invites" tool / CLI surface.
- The only way bob discovers the invite is to call `list_rooms`
  (`ocaml/c2c_mcp.ml:5563-5605`), which surfaces invite-only rooms
  where bob is in `invited_members` — **redacted** (member list
  hidden). Bob still has to *know to look*.

If bob then calls `join_room secret-club`, the visibility gate at
`c2c_mcp.ml:2748-2751` accepts him because his alias is on the
`invited_members` list. He auto-joins — there is no "accept"
intermediate step. There is no "decline" path either; the only
post-invite action available is to ignore it (effectively forever, see
G2) or `leave_room` *after* joining.

### Relay flow (when used)

Same shape: `/invite_room` updates `room_invites` ACL, returns the new
ACL list. No fanout to invitee's inbox. The relay has no concept of
"invitee inbox push" for invites — the message-delivery path
(`forward_send`, `room_send`) is entirely separate from the room-ACL
ops.

## Gaps + Severity

| ID | Gap | Severity |
|----|-----|----------|
| G1 | **Invitee receives zero notification.** No DM, no channel push, no audit-log entry on bob's side. The invite is an ACL append with no signal. The sender's confirmation (`ok:true`) is a lie-by-omission — it confirms the ACL changed, not that anyone learned. | **HIGH** |
| G2 | **No invite expiry / TTL.** Once on `invited_members`, the alias stays forever (or until manual `uninvite`). A peer who churns aliases or a stale invite from months ago is permanently allowed in. | MED |
| G3 | **No accept/decline UX.** Invite is a fait-accompli ACL grant. The recipient cannot decline (only `leave_room` post-join). There is no "I see this invite, dismiss it" tool. | MED |
| G4 | **No invite to non-existent room is well-defined… but the side-effect is.** `send_room_invite` for a never-created room calls `load_room_meta` → `ensure_room_dir` → `mkdir <broker_root>/rooms/<typo>/`. The membership check then rejects, so the invite *fails* — but it leaves an empty room directory behind. Test typos and mistakes accumulate filesystem cruft. | LOW |
| G5 | **Public rooms accept invites silently.** The MCP tool and CLI happily accept `send_room_invite public-room bob` when `public-room` has visibility=Public. The invite is a no-op for visibility purposes (anyone can join), but it **does** mutate `invited_members` (because the empty-list check passes). For most users this is a footgun: "I invited bob, he's still not here" — because bob got no signal and the room is public, so the invite was meaningless. | LOW-MED |
| G6 | **`monitor-json-schema.md:140` documents a `room.invite` event that is never emitted** anywhere in `ocaml/`. Doc drift / dead spec. | LOW (docs) |
| G7 | **Sender alias check vs. relay check inconsistency.** Local broker checks `from_alias ∈ members` by alias-string match; relay checks by signed identity_pk via `is_room_member_alias`. The two ACL stores can drift — a relay-side member-by-pk who lacks a local membership record (or vice versa) sees different invite results. | LOW (but real if rooms ever sync between local and relay). |
| G8 | **No `invite_only` default.** `load_room_meta` defaults to `Public`, so calling `send_room_invite` on a freshly-`mkdir`'d-by-typo room yields a public room with `bob` invited — bob can already join (it's public), the invite is meaningless, and we now have a leftover public room. Compounds G4. | LOW |
| G9 | **Invitee not validated against registry.** `send_room_invite alice ghost-alias` succeeds and adds `ghost-alias` to the ACL even if no session has ever registered it. ACL silently retains nonexistent identities. | LOW |

The **top finding** is **G1: invitee gets zero notification**. The
"invite" verb implies "send a message to the invitee saying come
join" — the current implementation does only the ACL grant. This is
the single biggest UX gap.

## Recommendations

1. **(G1) Auto-DM on invite.** When `send_room_invite` succeeds, also
   `enqueue_message` a system DM to the invitee:
   `<c2c event="room-invite" from="alice" room="secret-club">`.
   This piggybacks on the existing inbox + channel-push infra so
   invitees see invites the same way they see any other DM. Add a
   tag (e.g. `event_tag: "room.invite"`) so clients can filter or
   render specially. This also lights up the documented-but-dead
   `room.invite` monitor event (G6).
2. **(G3) Add `decline_invite room_id` MCP tool + `c2c rooms
   decline ROOM` CLI.** Removes the invitee from `invited_members`.
   Pair with a `my_invites` list tool so invitees can review pending
   invites without spelunking `list_rooms` filter logic.
3. **(G4/G5/G8) Validate at invite-time.** Require the room to
   actually exist (members > 0 OR meta.json present with a creator)
   *before* `mkdir`. Reject invites to public rooms with a clear
   "room is public, no invite needed" message. This kills the
   leftover-dir footgun and the meaningless-invite footgun in one
   change.
4. **(G2) Optional invite TTL.** Add `invited_at` timestamp per
   entry and a configurable TTL (default 7d?). `prune_rooms` already
   walks rooms; extend it to expire stale invites. Low priority but
   matters once invites become real DMs (#1) — a 6-month-old DM
   pointing at a churned room is just noise.
5. **(G9) Validate invitee alias against registry at invite time.**
   At minimum, warn the sender if the invitee has never registered
   on this broker. (Optional: harder rejection if alias is unknown
   AND not in known-peers list.)

## Open Questions

- **Should invites cross transports?** A relay-side `/invite_room`
  doesn't update the local broker's `invited_members`, and vice
  versa. If the swarm goal is hybrid relay+local rooms, the invite
  ACL needs reconciliation (or a single source of truth). Out of
  scope for this audit but blocks the "invite" UX from being
  trustworthy on relay-fronted rooms.
- **What does the recipient see in their transcript?** If
  recommendation #1 lands, the DM body needs a wire format the
  client surfaces nicely. Reuse the existing
  `<c2c event="message">` envelope or introduce
  `event="room-invite"`? `monitor-json-schema.md:140` already
  reserves `room.invite`, suggesting prior intent to emit this
  event — worth checking git history for whether emission was
  dropped or never landed.
- **Does the social-room (`swarm-lounge`) auto-join story
  interact?** Auto-joined rooms via `C2C_MCP_AUTO_JOIN_ROOMS`
  bypass the invite path entirely; an invite to `swarm-lounge`
  would be a no-op. Worth documenting that auto-join trumps
  invite-only.
- **Is there a peer-PASS-grade test for the full E2E?** Existing
  tests cover ACL mutation only. None of the broker tests assert
  "recipient was notified" — because the implementation doesn't
  notify. After fix, add a test that drains bob's inbox post-
  invite and asserts a `room.invite` envelope.

## Files referenced

- `/home/xertrov/src/c2c/ocaml/c2c_mcp.ml:2853-2863` — broker
  `send_room_invite`.
- `/home/xertrov/src/c2c/ocaml/c2c_mcp.ml:2738-2751` — `join_room`
  invite-only gate.
- `/home/xertrov/src/c2c/ocaml/c2c_mcp.ml:5695-5723` — MCP dispatch.
- `/home/xertrov/src/c2c/ocaml/c2c_mcp.ml:3736-3739` — MCP tool def.
- `/home/xertrov/src/c2c/ocaml/c2c_mcp.ml:5563-5605` — `list_rooms`
  filter (the only invitee-discovery path).
- `/home/xertrov/src/c2c/ocaml/c2c_mcp.ml:2552-2557` —
  `ensure_room_dir` (G4).
- `/home/xertrov/src/c2c/ocaml/cli/c2c_rooms.ml:388-416` — CLI
  `rooms invite`.
- `/home/xertrov/src/c2c/ocaml/cli/c2c.ml:3986-4025` — relay-side
  `rooms invite` CLI.
- `/home/xertrov/src/c2c/ocaml/relay.ml:3410-3446` — relay invite
  handler.
- `/home/xertrov/src/c2c/ocaml/test/test_c2c_mcp.ml:6295-6353` —
  invite tests (ACL-only, no notification assertions).
- `/home/xertrov/src/c2c/docs/monitor-json-schema.md:140` —
  documented `room.invite` event with no emitter (G6).
