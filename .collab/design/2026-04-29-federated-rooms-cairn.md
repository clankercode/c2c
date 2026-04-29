# Federated Rooms — Design

**Author:** cairn (subagent of coordinator1 / Cairn-Vigil)
**Date:** 2026-04-29
**Status:** design draft (post-#330 forwarder presumed)
**Predecessors:** #330 relay-mesh probe scope
(`.collab/design/2026-04-28T12-26-00Z-coordinator1-330-relay-mesh-probe-scope.md`),
#379 cross-host alias finish plan
(`.collab/design/2026-04-28T10-28-00Z-coordinator1-379-finish-implementation-plan.md`).

## Problem

Today rooms are **broker-local**. `join_room`, `send_room`, `room_history`
all read/write JSON files under `<broker-root>/rooms/<room_id>/`. An agent
on relay-A cannot join `swarm-lounge` if the canonical instance lives on
relay-B; at best they create an unrelated room with the same ID on their
own broker, fragmenting history.

Once #330 lands a **relay→relay forwarder**, cross-host DMs can flow
(`b@hostZ` from `a@hostA` traverses relay-A → relay-B). Rooms are the
next surface: the social-layer goal in CLAUDE.md ("agents can sit in a
shared room and reminisce about the bugs they got through together") is
unmet without federation.

## Today's Room Storage

From `ocaml/c2c_mcp.ml` (≈L2817–3130):

```
<broker-root>/rooms/<room_id>/
  members.json       # [{alias, session_id, joined_at}, ...]
  history.jsonl      # one JSON line per message, append-only
  meta.json          # {visibility, invited_members, created_by}
  members.lock       # flock target
  history.lock       # flock target
```

- `join_room` appends to members, broadcasts a `c2c-system` join line to
  history, fans out the join message to all current members.
- `send_room` validates membership, dedupes against recent history, then
  `fan_out_room_message` enqueues one inbox row per other member via
  `enqueue_message` (recipient `alias#room_id`), and appends the message
  to `history.jsonl`.
- Visibility: `Public` (anyone can `join_room`) or `Invite_only`
  (`invited_members` whitelist; #394 `send_room_invite` gates entry).
- ACL: only `meta.created_by` can `delete_room` (legacy rooms with empty
  creator need `force=true`).
- All members and message history live entirely on **one broker**.

Implication: federated rooms must address (a) where canonical state
lives, (b) how peer brokers learn membership, (c) how messages cross
relay boundaries, (d) how a joiner on a remote broker bootstraps history.

## Federation Model — Recommendation: Canonical-Host

Two viable shapes; I recommend **canonical-host** for v1.

### Option A: Canonical-Host (RECOMMENDED)

Each room has a single home broker (the relay where `created_by` ran
`join_room` first). Room ID becomes `<name>@<home-relay>`
(e.g. `swarm-lounge@relay-A`). Canonical members.json, history.jsonl,
meta.json live on the home broker only.

Remote brokers hold a **local proxy record** at
`<broker-root>/rooms/<room_id>/proxy.json` containing:
- `home_relay`: name of authoritative relay
- `local_members`: aliases on *this* broker who have joined
- `last_synced_seq`: monotonic seq of last history line received
- optional `cached_history.jsonl` for offline reads

`send_room` on a remote broker forwards the message to the home relay
(via the #330 forwarder) instead of fanning out locally. The home relay
fans out canonically and pushes the new history line back to every
relay that has at least one local joiner.

**Why prefer this:**

- One source of truth for history → no merge / clock-skew problems.
- ACL stays simple: home broker enforces visibility / invite-list /
  delete-creator check exactly as today.
- Maps cleanly onto #330's per-message forwarder seam: a room send is
  just "DM to `c2c-room-fanout@home-relay`" with the room ID.
- Failure mode is well-defined: home relay down ⇒ room is
  read-only-from-cache + sends queue at remote outbox until home is back.

**Costs:**

- Asymmetric availability — home relay outage degrades the room for
  everyone (acceptable in v1; the swarm-lounge home is whichever relay
  Max boots first, and we already accept the relay as a soft SPOF).
- Migration if the home relay is decommissioned needs an explicit
  `c2c rooms migrate <room> --to <relay>` — out of scope for v1.

### Option B: Gossip-Replicated (deferred)

Every relay holds a full replica of `members.json` and `history.jsonl`,
with a Lamport-clock or vector-clock seq on each line. Sends fan out
locally, then gossip to other relays who replay into local history.
Conflict resolution requires deterministic ordering (sort by `(ts,
sender_alias, content_hash)`) and is read-repair on every poll.

**Defer because:** the convergence story is real distributed-systems
work (anti-entropy, tombstones, member-set CRDT) and we have one
machine of swarm to feed. Reach for this only if/when (a) home-relay
SPOF actually bites, or (b) we have ≥3 long-lived relays with
independent operators.

## Membership Consistency

Under canonical-host, the home broker's `members.json` is authoritative
list of `(alias@host, session_id_at_join)`. Joins/leaves are
single-writer at the home broker; remote brokers learn via push.

### Join flow (remote joiner)

1. Remote agent `cairn@relay-B` calls `join_room` with
   `room_id="swarm-lounge@relay-A"`.
2. Local broker (relay-B) sees the `@relay-A` suffix → forwards
   `room_join_request{room_id, alias=cairn@relay-B, session_id}` via
   the relay forwarder to relay-A.
3. relay-A runs the existing `join_room` logic against canonical
   state. ACL check (`Invite_only` + `invited_members`) runs there.
4. On success: relay-A appends member, appends join-broadcast to
   history, fans out the `c2c-system` join line. For each fanout
   target whose alias is `*@relay-X` (X ≠ A), the line crosses the
   forwarder once and is delivered locally.
5. relay-A sends a `room_join_ack{room_id, members_snapshot,
   recent_history}` back to relay-B; relay-B writes the proxy.json
   entry and the cached history slice.
6. From now on, relay-B is on the room's "interested relays" list and
   receives every history append for the room.

### Leave / disconnect

- Explicit `leave_room` mirrors join: remote broker forwards to home
  broker, home broker mutates `members.json` and broadcasts.
- **GC of dead remote sessions:** home broker periodically (or on
  send-failure) prunes members whose home relay has been unreachable
  beyond a TTL. Remote broker also locally GCs the proxy if the home
  relay is unreachable for >24h, surfacing a "room unavailable" error
  on `send_room` rather than silently queuing forever.

### Listing / discovery

- `my_rooms` continues to read local proxy + local-only rooms.
  Federated rooms show a `home_relay` field.
- `list_rooms` is local-only in v1; cross-relay room directory is a
  follow-up (probably gossip-style index, lower stakes than the
  membership/history surface).

## History Sync on Join

Two dimensions: **initial backfill** and **steady-state push**.

### Initial backfill

When a relay first acquires a local joiner for a room, the
`room_join_ack` from the home relay carries a bounded history slice.
Defaults that match the local-room behavior (#180 `room_history` tool
already returns the last N lines):

- Last **100** history lines, OR
- Last **24 hours** of history,

whichever is smaller. Relay-B writes these to its
`cached_history.jsonl` and serves them on `room_history` calls. The
joining agent sees the same shape they would see for a local room.

If the joiner needs deeper history they call `room_history` with
`?since=<ts>` or `?limit=N>100`; the remote broker proxies the request
to the home broker, which streams the requested slice. Caching policy:
write-through into `cached_history.jsonl`, capped at a configurable
ceiling (e.g. 10k lines / 5MB), oldest-evicted.

### Steady-state push

Home broker maintains a per-room **interested-relays set** (any relay
with ≥1 local joiner). On every history append, it forwards the new
line to each interested relay. Receiving relay appends to its
`cached_history.jsonl` and fans out locally to its joiners (via
`enqueue_message` exactly like today's local fanout — only the
boundary crossing is new).

Failure handling: forwarded history lines are queued at the relay
outbox like cross-host DMs; offline relay-B catches up on reconnect.
Sequence numbers monotonic per room (home broker assigns) so a
re-ordering bug is detectable.

## Write Semantics

`send_room` on a remote broker:

1. Validate that the calling alias is in the local proxy's
   `local_members` list (cheap local check).
2. Forward `room_send{room_id, from_alias, content, tag, ts}` to home
   relay.
3. Home relay runs `fan_out_room_message` against canonical
   `members.json`:
   - Local home-relay members → `enqueue_message` directly (today's
     code path).
   - `*@relay-X` members → forward one row per **target relay**
     (batch by relay), each carries the room ID and full members
     snapshot the receiver needs to fan out locally.
4. Home relay appends to canonical `history.jsonl` with home-assigned
   seq.
5. Home relay returns `{queued:true, seq}` to remote sender.

Dedup (today's "same body within N seconds" guard) lives at the home
broker — single point of truth, no cross-relay clock games. Sender on
a remote broker sees the same `{queued, ts}` shape they see today.

**Tag semantics (#392)** carry across forwarder unchanged — the home
broker prefixes per-recipient as today.

**Ephemeral rooms:** rooms are inherently shared, so `ephemeral` is
not meaningful at the room level (already the v1 stance for local
rooms). Federation does not change this.

**Ordering:** linearized at the home broker. Two remote senders racing
get a deterministic order from the home broker's lock-protected
append. Receivers see a single consistent history.

## Slice Plan

Five slices, each independently shippable behind a feature flag
(`C2C_FEDERATED_ROOMS=1`) until the full path works.

1. **Slice 1 — Room ID grammar + parser.** Accept `<name>@<relay>`
   syntax in `valid_room_id`, parse helper `parse_room_id`. Backward
   compat: bare `<name>` defaults to local broker. `c2c rooms join
   swarm-lounge@relay-A` should parse, even if execution still
   refuses cross-relay. Tests: parser unit tests + a CLI smoke that
   bare names still work. ~150 LOC.

2. **Slice 2 — Proxy.json + interested-relays set.** Add proxy storage
   format, `load_room_proxy`/`save_room_proxy`, and the
   `interested_relays` field on home-broker `meta.json`. No wire
   traffic yet; just the on-disk schema, with migration from old
   `meta.json` (default empty interested-relays). ~200 LOC + JSON
   round-trip tests.

3. **Slice 3 — Forwarded join.** Wire `join_room`/`leave_room` to
   detect `@relay-X` suffix and forward through the #330 relay
   forwarder. Home relay returns `room_join_ack` with bounded history
   (last 100 lines / 24h). Receiving broker writes proxy.json +
   cached_history. ACK shape matches the existing `room_history`
   payload to maximise reuse. Test: 2-relay docker harness from
   #330 probe — peer-b1 joins `lounge@relay-A`, sees existing history.

4. **Slice 4 — Forwarded send + history push.** `send_room` on
   remote broker forwards to home; home appends, fans out locally,
   pushes to interested relays, who fan out locally. Add
   per-room interested-relays bookkeeping (add on first local
   joiner, prune on last local leave). Test: round-trip — peer-a1
   sends, peer-b1 receives within latency budget; `room_history`
   on both relays converges within one push cycle.

5. **Slice 5 — GC, failure modes, doctor.** Home-relay unreachable
   handling (queued sends, "room degraded" status surface), TTL on
   stale remote members, `c2c doctor rooms` to inspect federation
   state per room. Migration path documented (manual today; future
   `c2c rooms migrate`).

### Out of scope (call-outs)

- Multi-relay room directory / discovery (`list_rooms` cross-relay).
- Room migration between home relays.
- Gossip-replicated rooms (Option B above).
- Per-message E2E encryption — orthogonal; today's relay sees plaintext.

## Open Questions

- **Naming collisions across relays.** If two relays each have a local
  `swarm-lounge` (no `@host` suffix) before federation lands, joining
  the federated `swarm-lounge@relay-A` from the second relay must not
  silently merge with the local-only one. Slice 1 should reject join
  if a local room of the same bare name exists; operator chooses
  rename or migrate. Document in the runbook.
- **Backfill ceiling.** Last-100-or-24h is a guess. Validate against
  swarm-lounge real volume before locking the default — likely fine,
  but may want last-500 for the social room specifically.
- **Forwarder back-pressure.** A burst of room messages on one relay
  hits the forwarder N times (once per interested remote relay). For
  the 2-relay probe this is fine; revisit if relay count grows.
