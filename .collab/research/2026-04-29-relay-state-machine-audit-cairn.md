# c2c relay state machine audit

**Author**: cairn (subagent of coordinator1 / Cairn-Vigil)
**Date**: 2026-04-29
**Source**: `ocaml/relay.ml` (4874 lines), companion modules under `ocaml/relay_*.ml`
**Scope**: enumerate every state, every transition, every observed edge case for the c2c HTTP relay (the cross-host transport, distinct from the local broker).

This is a code-grounded audit, not a design proposal — every state below
is one the running relay actually carries. File path references use
absolute path `/home/xertrov/src/c2c/ocaml/relay.ml` with line numbers
valid against the SHA the audit was run on.

---

## 0. The relay isn't one state machine — it's six

The relay maintains six largely-independent state tables. They share a
mutex (`InMemoryRelay.t.mutex` / `SqliteRelay.t.mutex`) but otherwise
evolve on their own clocks. Each is enumerated below.

| # | Machine | Storage | Lifetime |
|---|---------|---------|----------|
| 1 | Registration lease (per alias) | `leases` Hashtbl / `leases` table | TTL 300s, touched by heartbeat |
| 2 | Identity binding (alias ↔ Ed25519 pk) | `bindings` / lease.identity_pk | Persistent; survives lease expiry |
| 3 | Allowlist (operator-pinned alias → pk) | `allowed_identities` | Persistent, operator-managed |
| 4 | Message lifecycle (queued / delivered / dead-lettered / deduped / expired) | `inboxes`, `dead_letter`, `seen_ids` | Per-message |
| 5 | Room state (membership, visibility, invites, history) | `rooms`, `room_visibility`, `room_invites`, `room_history` | Persistent (history JSONL on disk if `persist_dir` set) |
| 6 | Pairing / binding (S5a mobile, S5b device-login, S6 observer WS) | `pairing_tokens`, observer bindings, `device_pair_pending_mem`, `ObserverSessions` | Tokens TTL 300s cap; device-pair 600s; bindings persistent |

There is also an HTTP **request-level** machine (auth_decision →
ed25519_verify → rate_limit → handler) layered on every call.

---

## 1. Connection states (HTTP transport)

The relay is `Cohttp_lwt_unix.Server.create`, so each request is a
short-lived state machine. There is no long-lived TCP "session" except
for the observer WebSocket upgrade.

### 1a. HTTP request lifecycle (relay.ml:3994–4423)

```
ACCEPT → RATE_LIMIT_CHECK ──Deny──→ 429 too_many_requests
                │
                Allow
                ▼
          PARSE_AUTH_HEADER (Authorization: "Ed25519 ..." | "Bearer ..." | none)
                ▼
          TRY_ED25519_VERIFY (relay.ml:3920) — produces verified_alias option
                ▼
          AUTH_DECISION (relay.ml:2531) — classifies path → unauth | self_auth | admin | peer
                │
                ├── reject → 401 unauthorized (with reason)
                ▼
          MATCH (meth, path) → handler
                ▼
          200 / 400 / 401 / 403 / 404 / 409 / 500 / 429
```

Edge cases in this layer:

- **Mixed auth rejected both ways** (relay.ml:2563–2576). Sending
  `Bearer` to a peer route gets "Bearer is admin-only"; sending
  `Ed25519` to an admin route gets "admin routes require Bearer".
- **Dev mode**: when `token = None`, peer routes accept unauthed
  requests (line 2575). Admin still skips Bearer check.
- **`/list_rooms` and `/room_history`** are deliberately unauth even
  in prod — there's a comment justifying this so the CLI works without
  a signing alias (line 2532–2535).
- **`/register` and the room mutation routes** are `is_self_auth`
  (line 2552–2562): they bypass header auth and do their own
  body-level Ed25519 verification because the alias hasn't been bound
  yet (or the route accepts both signed and unsigned bodies).
- **Rate limiting**: `/observer/<binding_id>` uses the binding-id
  prefix as a separate event channel, otherwise per-client-IP.

### 1b. Observer WebSocket session (S6, relay.ml:4086–4253)

This is the only long-lived per-client connection. State machine:

```
GET /observer/<binding_id> with Upgrade: websocket
        │
        ├── missing Sec-WebSocket-Key → 400 missing_sec_websocket_key
        ├── invalid Bearer (token != binding_id || binding not found) → 401 invalid_bearer_token
        ├── no fd extractable → 500 internal_error
        ▼
   UPGRADED — register ObserverSessions[binding_id] += session
        │
        ▼
   recv loop:
        │ Ping  → send "observer_pong"
        │ Close → close_with code=1000, finally(): unregister
        │ Text/Binary "reconnect" with since_ts, sig
        │     ├── sig invalid → close_with code=4001 invalid_signature
        │     └── sig ok → drain ShortQueue (in-memory, ts-bounded)
        │                 + if `gap` (since_ts < oldest in queue) →
        │                   backfill from R.query_messages_since +
        │                   per-room R.room_history (limit=100), tagged
        │                   "gap": true
        │ Text "ping" → "observer_pong"
        │ Other text → "observer_ack"
        ▼
   END_OF_FILE / exception → finally(): ObserverSessions.remove
```

Edge cases:

- **Multiple sessions per binding** are supported (list per binding_id,
  relay.ml:2304–2308). All get fan-out from `push_to_observers`.
- **Replay sig is over the binding_id literal** — re-establishing a
  dropped observer must prove possession of the phone's Ed25519 sk.
- **Gap detection** depends on the in-memory `ShortQueue` having an
  oldest_ts; if the queue evicted everything since, gap=true and
  backfill kicks in via the relay's room/dm tables.

---

## 2. Registration lease — the alias-presence machine

States are encoded in `RegistrationLease.is_alive` (relay.ml:159) +
status strings returned by `register` and `heartbeat`.

```
              register()                         heartbeat()
              ──────────►   ALIVE   ─────────►   ALIVE (last_seen touched)
                            │
                            │ now > last_seen + ttl  (TTL=300s default)
                            ▼
                          DEAD (still in leases until gc())
                            │
                            │ R.gc()
                            ▼
                          REMOVED (also: room memberships cleaned up,
                                   stale inboxes pruned)
```

`register` return statuses (relay.ml:618–673, 1332–...):

- `"ok"` — created or refreshed (same node_id reclaim allowed)
- `"invalid_alias"` — `C2c_name.is_valid alias = false`
- `"alias_not_allowed"` — allowlist mismatch (`AllowMismatch`) or
  allowlisted-but-no-pk-supplied (`ListedNoPk`)
- `"alias_identity_mismatch"` (`relay_err_alias_identity_mismatch`) —
  identity_pk submitted differs from the persistently bound pk for
  this alias
- `"alias_conflict"` (`relay_err_alias_conflict`) — alias is alive
  under a *different* node_id (cross-host clobber prevention)

`heartbeat` (relay.ml:837–852, body-binding at relay.ml:3146–3161):

- `"ok"` — found, last_seen touched
- `"unknown_alias"` — no lease matches (node_id, session_id)
- 403 *signature_invalid* — `verified_alias` doesn't own
  (node_id, session_id) per `alias_of_session`. (relay.ml:3140)

### 2a. Edge cases in lease state

1. **Same-node refresh is allowed** (relay.ml:657–659). An expired or
   alive lease can be reclaimed by the same node_id; only a different
   node_id triggers `alias_conflict`.
2. **Lease refresh preserves identity_pk** when caller doesn't supply
   one (relay.ml:661–664) — `effective_pk` falls back to
   `bindings[alias]`. Prevents accidentally clearing a binding on a
   weak refresh.
3. **`gc` cleans inbox keys**: not just leases. Stale inbox entries
   (no live lease pointing at them) are pruned (relay.ml:1199–1206).
4. **Heartbeat body-binding mismatch** returns 403, *not* 401 — see
   `reject_session_mismatch` at relay.ml:3140. This is `forbidden`
   because the auth itself was valid but the claim was wrong.
5. **`unbind_alias`** (admin) wipes both `bindings` and `leases` —
   used by `/admin/unbind` for operator override.

---

## 3. Identity binding — alias ↔ Ed25519 pk

This is a *separate* machine from the lease because bindings persist
across lease expiry. (`bindings` Hashtbl in InMemoryRelay; `identity_pk`
column on `leases` row in SqliteRelay where it's coupled.)

States:

```
   UNBOUND ─── register w/ identity_pk (signed) ──► BOUND
   UNBOUND ─── register w/o identity_pk ─────────► UNBOUND (stays)
   BOUND   ─── register same identity_pk ────────► BOUND (no-op)
   BOUND   ─── register different identity_pk ───► ⊥ (alias_identity_mismatch)
   BOUND   ─── admin/unbind ─────────────────────► UNBOUND
```

Edge cases:

- **InMemory vs Sqlite divergence**: InMemoryRelay treats `bindings`
  as separate from leases (relay.ml:642–668). SqliteRelay reads
  `existing_pk` from the lease row directly (relay.ml:1390–1396) —
  unbinding via `unbind_alias` clears both, but a leased-but-pk-empty
  alias works subtly differently across the two backends.
- **Allowlist precedence**: if `allowed_identities[alias]` exists,
  registration must include identity_pk *and* match. `ListedNoPk`
  → alias_not_allowed (line 638–640).
- **Signed registration path** (relay.ml:3080–3122): partial proof
  fields → 400 `missing_proof_field`. All present → verify against
  `register_sign_ctx = "c2c/v1/register"`. Skew window: −120s past,
  +30s future. Nonce TTL: 600s. Failures emit specific codes
  (`signature_invalid`, `timestamp_out_of_window`, `nonce_replay`).

---

## 4. Allowlist state (operator pinning)

```
   UNLISTED ─── R.set_allowed_identity ──► LISTED(pk)
   LISTED   ─── set again w/ same pk ────► LISTED (idempotent)
   LISTED   ─── set w/ different pk ─────► LISTED(new pk) (overwrite)
```

Lookup result type (relay.ml:441–442):

- `Allowed` — pk matches pinned
- `Mismatch` — pk submitted but != pinned
- `Unlisted` — alias not in allowlist (registration proceeds)

Loaded from `start_server`'s `?allowlist` argument (relay.ml:4436–4438)
once at startup; not reloadable without process restart.

---

## 5. Message lifecycle

Each message id passes through one of these states:

```
                       send()
   ── from_alias ──► CHECK_RECIPIENT
                       │
                       ├── unknown alias → DEAD_LETTER (reason="unknown_alias")
                       │                     return `Error (unknown_alias, ...)
                       │
                       ├── lease.is_alive=false → DEAD_LETTER (reason="recipient_dead")
                       │                            return `Error (recipient_dead, ...)
                       │
                       ├── cross_host (alias@otherhost) → DEAD_LETTER
                       │     (reason="cross_host_not_implemented", #379)
                       │     return 404 cross_host_not_implemented
                       │
                       ├── seen_ids[msg_id] = true → DEDUPED, return `Duplicate ts
                       │
                       └── ENQUEUED to inboxes[(node_id, session_id)]
                              return `Ok ts
                              ▼
                         (also: short_queue push if recipient has bound observer)
                              ▼
                         poll_inbox → drained → INBOX EMPTY
                            (peek_inbox observes without draining)
```

Edge cases observed:

1. **Dedup window FIFO**: `seen_ids` Hashtbl + `seen_ids_fifo` queue
   capped at `dedup_window` (default 10000) — oldest evicted on
   overflow (relay.ml:599–604). A reused message_id past the eviction
   window will deduplicate-fail (re-deliver) silently.
2. **Cross-host dead-letter** (relay.ml:3171–3190, fix in
   commit `492c052b`): pre-fix, mismatched host caused silent drop.
   Now writes to dead_letter with reason `cross_host_not_implemented`
   *and* returns 404. This is the recently-fixed silent-drop bug.
3. **`send_all`** does NOT touch dead_letter for skipped recipients —
   it returns them in the `skipped` array but the bookkeeping is the
   client's responsibility (relay.ml:1160–1180).
4. **`send_room` *does* dead-letter** unreachable members per-recipient
   with reason="recipient_dead" (relay.ml:1097–1111). Asymmetry vs
   `send_all` is real.
5. **Inbox is per (node_id, session_id), not per alias**. If the same
   alias re-registers under a new session, the old inbox is orphaned
   until `gc()` (relay.ml:1199–1206).
6. **No TTL on queued messages** — once enqueued, a message sits
   forever until `poll_inbox` drains it. A session that registers
   then never polls accumulates indefinitely.
7. **Envelope passthrough on send_room**: when L4/3 envelope is
   present, it's appended to fan-out and history rows verbatim
   (relay.ml:1086–1132). Recipients can re-verify the sig.
8. **Identity-pk-bound observer push**: every successful send/send_all
   /send_room also pushes to ShortQueue + observer sessions if the
   recipient's identity_pk has a phone binding (relay.ml:3199–3214,
   3229–3245, 3568–3584).

### 5a. Dead-letter states

`dead_letter` is a single FIFO `Queue` (in-memory). Entries:

- `unknown_alias` — `send` to non-existent recipient
- `recipient_dead` — recipient lease expired
- `cross_host_not_implemented` — alias@host where host != self
- `recipient_dead` — room-fanout to a dead member (also written from
  `send_room`, `join_room`, `leave_room`)

There's no read-then-clear; `dead_letter` accumulates until process
restart. `add_dead_letter` is exposed for handlers (used by #379 fix).

### 5b. Nonce state

Two separate nonce tables: `register_nonces` (TTL 600s, register +
room ops) and `request_nonces` (TTL 120s, per-request §5.1). Both
self-prune expired entries on every check (relay.ml:821–827). Replay
returns `relay_err_nonce_replay`.

---

## 6. Room state machine

Three coordinated tables: `rooms` (room_id → member aliases),
`room_visibility` (room_id → "public"|"invite"), `room_invites`
(room_id → identity_pk b64 list), and `room_history` (room_id → msgs).

```
   NONEXISTENT ─── join_room (first member) ──► PUBLIC, MEMBERSHIP={a}
                                                  history += join_msg

   PUBLIC      ─── set_room_visibility "invite" ─► INVITE-ONLY
   INVITE-ONLY ─── set_room_visibility "public" ──► PUBLIC

   any room    ─── invite_to_room (signed) ─────► invites += pk
   any room    ─── uninvite_from_room ──────────► invites -= pk

   PUBLIC      ─── join_room ─────────────────► add to members
                                                fan out join system msg
   INVITE-ONLY ─── join_room w/ identity_pk ∈ invites ─► add
   INVITE-ONLY ─── join_room w/ pk ∉ invites ─────────► 401 not_invited

   any         ─── leave_room ──────────────────► remove from members
                                                  fan out leave msg if not last
```

Room op auth (relay.ml:3282–3344):

- Optional signed proof: identity_pk + sig + nonce + ts in body
- `C2C_REQUIRE_SIGNED_ROOM_OPS=1` flips legacy unsigned path from
  WARN-then-allow to `unsigned_room_op` reject (relay.ml:52–55,
  3299–3306). Phase 2/3 of migration plan; default off.
- Signature verifies against per-op context: `c2c/v1/room-join`,
  `room-leave`, `room-send`, `room-invite`, `room-uninvite`,
  `room-set-visibility`.
- `set_room_visibility` and invite/uninvite require the *requestor*
  to be a current member of the room (`is_room_member_alias` check at
  relay.ml:3397, 3425).

### 6a. Room edge cases

1. **Join is idempotent**: re-joining doesn't re-fan-out a system
   message (relay.ml:941–946 `if not already_member`).
2. **Last-leaver**: if the leaver is the only member, no leave-system
   message is fanned out (`removed && members' <> []`, relay.ml:994).
   The room itself sticks around with empty membership; no
   auto-removal (a `prune_rooms` op exists at the broker layer but
   not relay).
3. **Visibility default is "public"** (`room_visibility_of` returns
   "public" when no row, relay.ml:1035–1038). New rooms are public.
4. **Invite list is a flat array**, no expiry, no per-invitee
   metadata. A pk in `room_invites[room_id]` can join until removed.
5. **Not-a-member from `set_room_visibility` is 401**, not 403.
   (Quirk vs heartbeat-mismatch which is 403.)
6. **Persisted history on disk** when `persist_dir` is set
   (`rooms/<room_id>/history.jsonl`, append-only, JSON Lines per
   message, relay.ml:519–553). Loaded eagerly at create.
7. **Envelope on send_room** is preserved through fan-out *and*
   history (relay.ml:1086–1126) so late readers via `room_history`
   can also verify signatures.

---

## 7. Pairing / binding states (S5a, S5b, S6)

### 7a. Mobile-pair (S5a, machine-initiated)

```
   POST /mobile-pair/prepare           POST /mobile-pair                DELETE /binding/<id>
   ─── store signed token ───►  PENDING ──── verify+burn token,    ─── remove binding,
       (TTL 300s cap server)              add ObserverBinding ───►   push pseudo_unregistration
                                          push pseudo_registration   to active observer sessions
```

Pending → confirmed transition is atomic via `get_and_burn_pairing_token`
(relay.ml:377–395) — single-use semantics enforced at SQL level.

Edge cases:

- **Rebind** (line 3638–3644): if a token already exists for
  `binding_id`, prepare overwrites and structured-logs `pair_rebound`.
- **Token TTL cap**: server rejects tokens with TTL > 300s
  (relay.ml:3624). Defends against tokens with eternal lifetimes.
- **Future-dated `issued_at`**: rejected if more than 5s in future
  (line 3623).

### 7b. Device-pair (S5b, RFC 8628 OAuth-style)

State machine on `device_pair_pending_mem` keyed by user_code:

```
   POST /device-pair/init       POST /device-pair/<user_code>      GET /device-pair/<user_code>
   create pending,        ───► (phone registers pubkeys)      ──► (machine polls)
   user_code generated,
   binding_id="dev-"+code,
   expires_at = now+600s

       PENDING                       PENDING (with phone pk fields)         CLAIMED
                                 ─OR─                                  (binding created,
                                     INVALIDATED (fail_count>=10)       pending removed)
```

States:

- `(phone_ed=None, phone_x=None)` → poll returns `status: "pending"`
- both set → poll returns `status: "claimed"`, creates ObserverBinding
  via `add_observer_binding`, removes the pending entry
- inconsistent (one set, other None) → poll returns 400
  `incomplete registration` (relay.ml:3906–3907)

Edge cases:

- **fail_count gate**: 10 invalid pubkey submissions on a single
  user_code invalidates it (relay.ml:3814, 3826, 3840, 3852). DoS
  resistance.
- **Expired user_code on register or poll**: deletes the pending and
  returns 404 `user_code expired`.
- **Poll-after-claim is a 404** (`user_code not found`) because the
  pending row was removed at claim time. Client must remember the
  binding_id from the claim response.
- **InMemory only**: `device_pair_pending_mem` is not in the SQL
  DDL — relay restart loses pending pairs (acceptable, 600s window).

### 7c. Observer binding (long-lived)

ObserverBindings module (relay.ml:1211–1266) holds the persistent
binding (phone_ed, phone_x, machine_ed, provenance_sig, issued_at)
keyed by binding_id with a reverse `phone_pk_to_binding` index. Lives
across reconnects. Removed only by `DELETE /binding/<id>`.

---

## 8. State-machine cross-cutting concerns

1. **Mutex granularity**: a single `Mutex.t` per relay value gates
   all of (1)–(5). Long-running ops (room fan-out to thousands of
   members) hold the lock — fine at swarm scale, possibly tight for
   future load.
2. **InMemoryRelay vs SqliteRelay parity** is mostly enforced by the
   `RELAY` module signature at relay.ml:425–484, but subtle
   differences exist around binding lookup vs lease lookup that have
   bitten us before (see prior #322-related findings).
3. **`gc_loop`** (relay.ml:4427–4431) fires `R.gc` on a configurable
   interval — only runs if `gc_interval > 0.0`. Default startup
   doesn't enable it; operators must opt in.
4. **Self-host string** (#379) is the relay's own identity for
   alias@host validation. None = legacy "accept any/no host"; Some
   "h" = reject `alias@otherhost`. Set at create time, not mutable.
5. **`C2C_REQUIRE_SIGNED_ROOM_OPS`** (relay.ml:42–55) is the only
   server-side feature gate inside the state machine — flips
   legacy-unsigned-allowed → reject. Phase 3 plan: default to "1".

---

## 9. Bugs / sharp edges flagged for follow-up

1. **No queued-message TTL**. A registered-but-never-polling session
   is an inbox leak until `gc()` (which only runs if explicitly
   enabled). Action: consider per-message ttl in future.
2. **`send_all` skipped recipients are not dead-lettered**. Asymmetric
   vs `send_room` and `send`. Either deliberately frugal or an
   oversight; worth a clarifying comment.
3. **Dead-letter is unbounded**. Only drains via process restart. No
   read API drains it (only `dead_letter`, a peek). Should evict
   beyond a reasonable cap or persist and rotate.
4. **Cross-backend binding semantics**. SqliteRelay derives `existing_pk`
   from leases row, InMemoryRelay from `bindings` Hashtbl. For an
   unbinder-then-rebinder flow these may diverge subtly (especially
   if lease was deleted but binding wasn't, or vice versa).
5. **Mutex coverage of WS push**: `push_to_observers` does NOT take
   the relay mutex (relay.ml:2330–2344) — it grabs `ObserverSessions.mutex`
   only. Send happens via `Lwt.async`. Race vs concurrent
   `remove_observer_binding` is benign (stale send is dropped) but
   worth a comment.
6. **`request_nonce_ttl = 120s` vs `request_ts_past_window = 30s`**
   means a replay between 30s and 120s after the original would be
   caught by the nonce table even though the timestamp window has
   already rejected it. Belt-and-suspenders, fine.
7. **Observer reconnect sig is over `binding_id` only**, not
   `binding_id || nonce || ts`. Replayable indefinitely with a
   captured signature. Defensible because binding_id is bearer-token
   gated already, but worth noting.
8. **`is_room_member_alias` returns false for nonexistent rooms**
   (relay.ml:1070–1073). Set-visibility on a never-joined room would
   401 `not_a_member`, not 404 — quirk for clients.

---

## 10. Audit conclusion

The relay is six independent state machines glued by one mutex. The
high-traffic paths (register, send, poll_inbox, send_room) are
well-instrumented and have specific error codes for each transition.
The device-pair / observer flows have more nuanced state but are
isolated by binding_id and don't interact with the core peer routes.

The biggest correctness risks are (a) the unbounded dead-letter and
inbox queues, (b) the asymmetry between `send_all` (no DL) and
`send_room`/`send` (DL on failure), and (c) the cross-host story
(#379 just patched silent-drop, but the broader cross-host transport
is still "not_implemented"). The recently-landed `cross_host_not_implemented`
DL reason is the right shape for future work.

For the c2c roadmap, the relay state machine is in good shape for
1:1 + rooms across a single relay host. The cross-host story is the
next frontier and the state taxonomy here suggests a `forwarded` or
`pending_forward` message state will be needed to bridge it cleanly.

---

**End of audit.**
