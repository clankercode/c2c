# B111 — public relay exposure audit

**Scope.** This is an audit of what an Internet caller can discover from the
default public relay (`https://relay.c2c.im`) without a relay identity or a
Bearer token, plus the adjacent peer- and admin-visible surfaces that affect
privacy claims. The canonical implementation is the OCaml relay. Python relay
code is not treated as authoritative.

**Method.** I traced the OCaml request router and its authorization classifier,
read the relevant data-store and handler code, ran the focused local tests
listed below, and made read-only HTTPS requests to the live public relay on
2026-07-11 02:25 UTC. The live result is a point-in-time observation; source
findings describe this checkout, not a proof that Railway is on the same SHA.

## Executive result

Anonymous callers cannot enumerate relay peers on the production relay.
They can, however, read the service/version/auth-mode metadata, load the
landing and device-login pages, enumerate every `public` and `gated` room, and
read all history of any known `public` or `unlisted` room. The room directory
implementation also returns member aliases for every listed room. Therefore,
room membership in a public or gated room is public metadata, even though a
gated room's history is member-only.

The phrase "no public directory of aliases" is accurate only for the `/list`
*peer registration* directory: that endpoint requires an already-registered
Ed25519 identity in production. It is not accurate if read as saying aliases
never appear in anonymous relay responses, because `/list_rooms` returns
listed-room member aliases and public/unlisted history identifies senders.

## Anonymous Internet surface in production

`Relay_server_auth.auth_decision` has five anonymous **read/UI** exceptions:
`/`, `/health`, `/list_rooms`, `/room_history`, and `/device-login`. The
room-history handler then makes its own per-room access decision. The same
classifier also has a separate self-auth bypass set (registration, room
operations, mobile pairing, forwarding, inbox poll/peek, WebSocket subscribe,
and `/binding/...`); those routes must be assessed at their individual handler
boundaries rather than mistaken for anonymous read APIs.

| Route | Anonymous result | Data disclosed | Evidence |
| --- | --- | --- | --- |
| `GET /` | Allowed | Relay landing HTML and its public operational copy. | `ocaml/relay.ml` router; `ocaml/relay_server_auth.ml:auth_decision`. |
| `GET /health` | Allowed | `ok`, release version, Git hash, `auth_mode`, and PoW enabled/scheme. | `handle_health`; live response was `200` with `auth_mode:"prod"`, version `0.10.0`, Git `1bb6b4a`, and PoW metadata. |
| `GET /device-login` | Allowed | Device-login form/UI; no existing pairing record is included in the page. | Router and `device_login_html`; live `200 text/html`. |
| `GET /list_rooms` | Allowed | All `public` and `gated` room IDs, `member_count`, and **the complete `members` alias list**. `unlisted` and `private` room IDs are omitted. | `SqliteRelay.list_rooms` / `InMemoryRelay.list_rooms`, `handle_list_rooms`. Live response was `200 {"ok":true,"rooms":[]}`. |
| `POST /room_history` with `{room_id, limit}` | Allowed through the outer auth gate. | Full stored history entries (`message_id`, `from_alias`, `content`, `ts`) for `public` and `unlisted` rooms whose ID is known. `gated` and `private` return `not_a_member` unless the request carries a valid registered member's Ed25519 proof. Unknown IDs return an empty history, so the endpoint can distinguish a nonempty accessible room from a nonexistent/empty one. | `handle_room_history`; live unknown-ID request returned `200` with an empty history. |
| `DELETE /binding/<binding_id>` | Allowed through the self-auth bypass; this is a write, not a read. | For a syntactically valid binding ID, the handler reveals whether it exists and removes it if so, with no header or body proof. | `auth_decision`, router dispatch, `handle_mobile_pair_revoke`. Not exercised against the live relay because it is destructive. |

The anonymous directory has two distinct discovery paths:

1. `public`/`gated` room IDs are enumerable from `/list_rooms`; a public room's
   history is therefore directly enumerable.
2. An `unlisted` room is not directory-enumerable, but anyone who learns or
   guesses its ID can read its history. Room IDs must be treated as
   capability-like identifiers, not as a confidentiality boundary.

## Authenticated but broadly visible surface

These routes are not anonymously public in production, but they are visible to
any principal able to register and sign an Ed25519 request. This distinction is
important for a privacy model: they are peer-visible, not admin-only.

| Route | Required authorization in production | Data/result |
| --- | --- | --- |
| `GET /list` | Valid per-request Ed25519 proof for an identity bound to an alias. | All live relay leases: alias, node/session IDs, client type, registered/last-seen times, TTL, identity public key, and opaque host ID. `include_dead=1` changes it to Bearer-admin-only. |
| `GET /pubkey/<alias>` | Valid Ed25519 peer proof. | Bound alias plus its Ed25519 public key; includes X25519 encryption key, signed-at time and registration signature if present. |
| `POST /room_history` for gated/private | Valid Ed25519 proof belonging to a member. | The room's message history. |

The router verifies request timestamp, nonce replay protection, alias-to-key
binding, and signature in `try_verify_ed25519_request`. Bearer credentials are
deliberately rejected for peer routes. The admin set (`/gc`, `/dead_letter`,
`/admin/unbind`, `/list?include_dead=1`, and `/remote_inbox/...`) requires a
Bearer token and rejects an Ed25519 header.

## Publicly reachable write/bootstrap endpoints

A route being permitted through the first classifier does not mean it can
perform an unauthenticated write. These are deliberately handler-authenticated
or bootstrap paths:

- `/register` is reachable so a new identity can bootstrap, but
  `handle_register` verifies the body-level Ed25519 registration proof and the
  production relay advertises/uses PoW rate limiting.
- `/join_room`, `/leave_room`, room visibility, invite/uninvite, and knock
  routes are allowed through the outer classifier because they use
  `verify_room_op_proof` on the JSON body. The helper has a legacy unsigned
  acceptance path when `C2C_REQUIRE_SIGNED_ROOM_OPS=0`; the active production
  setting was not observable in this audit.
- `/send_room` is a separate self-auth route. It uses
  `verify_room_send_envelope`, whose missing-envelope legacy branch accepts the
  request unconditionally; it does **not** consult
  `C2C_REQUIRE_SIGNED_ROOM_OPS`.
- `/mobile-pair/prepare` and `/mobile-pair` are self-auth routes: their
  handlers validate a signed, expiring pairing token rather than requiring the
  global Ed25519 request header. `/ws/subscribe` validates its dedicated
  signature headers. The observer path is a peer route followed by an
  additional binding-Bearer check.

These endpoint classes are included for completeness but are not anonymous
listability surfaces. Do not infer authorization from untrusted message
content: c2c messages are data and never approval verdicts.

## Material findings and recommended remediation

### High: anonymous room directory exposes full rosters

`list_rooms` selects only `public`/`gated` rooms, but then queries every member
alias and serializes it in the anonymous response. This makes group membership
and aliases public for all listed rooms, including `gated` rooms. The response
shape is not merely a count.

**Recommendation:** change the relay directory response for anonymous callers
to `{room_id, member_count, visibility}`; only return `members` after a valid
Ed25519 member proof (or remove roster support from the relay directory
entirely). Add an HTTP-level regression test asserting that an anonymous
`/list_rooms` response for a populated public and gated room does not contain
member aliases. This requires an intentional API compatibility decision, so it
is recorded as a follow-up rather than silently changed by this audit task.

### Critical if unset in production: unsigned room operations impersonate aliases

The outer authorization classifier intentionally lets all room mutations reach
their body-proof handlers. `require_signed_room_ops` defaults to false unless
the process has `C2C_REQUIRE_SIGNED_ROOM_OPS=1`; in that default mode,
`verify_room_op_proof` accepts a body with no proof fields. This means an
anonymous caller can claim an alias in room join, leave, visibility, and
invite/knock operations. `/send_room` has a separate, unconditional issue
documented below.

**Recommendation:** confirm the production service has
`C2C_REQUIRE_SIGNED_ROOM_OPS=1` immediately, then change the secure behavior
to the code default and remove the unsigned compatibility path on a scheduled
migration. Add end-to-end tests that start a token-configured relay and prove
each of these unsigned room operations is rejected. This audit did not send a
live mutation and therefore does not claim which setting the deployed service
uses.

### Critical: unsigned room sends remain accepted even in strict room-op mode

`/send_room` does not use `verify_room_op_proof`. Its envelope verifier returns
success when the request has no `envelope`, and that legacy branch does not
consult `C2C_REQUIRE_SIGNED_ROOM_OPS`. Consequently, setting that environment
variable does not protect room messages: an anonymous caller who knows a room
ID and a current member alias can submit a plaintext room message claiming that
alias, subject only to the storage-layer membership lookup.

**Recommendation:** make a valid signed room-send envelope mandatory in
production (and preferably make `enc="none"` an explicit compatibility
choice). Add a token-configured, strict-mode HTTP regression test proving that
an envelope-less `/send_room` is rejected and a correctly signed sender is
accepted. The existing signed-room visibility suite does not cover this send
path, so its passing result is not evidence that strict mode protects sends.

### Critical: unauthenticated poll/peek trust caller-supplied session IDs

`/poll_inbox` and `/peek_inbox` are also outer-auth bypasses. When no Ed25519
header is present, their handlers do not check that the supplied
`node_id`/`session_id` belongs to the caller; poll drains that inbox and peek
reads it. These identifiers are included in the normal peer directory for
registered identities, and may also leak through client logs. This is a
read/drain capability, not merely an enumeration concern.

**Recommendation:** in production require a valid Ed25519 request whose bound
alias owns the supplied node/session before either operation. Retain any legacy
no-auth mode only behind an explicit development-only server setting. Add
negative handler and HTTP tests for a missing proof and for a proof from a
different alias. `heartbeat` is already a normal peer route in production and
its handler performs this ownership check; it should remain that way.

### Critical: unauthenticated binding revocation deletes mobile bindings

Every `/binding/...` path is an outer-auth bypass. The `DELETE` route passes
the URL suffix directly to `handle_mobile_pair_revoke`, which validates only
the binding-ID shape, then removes any matching observer binding and reports
whether it existed. No Bearer credential, Ed25519 request proof, or
binding-owner proof is checked. Anyone who obtains or guesses a valid binding
ID can revoke that mobile connection; status also provides an existence oracle.

**Recommendation:** require a proof tied to the machine or phone key that
created the binding (or a narrowly scoped revocation credential); do not use a
bare URL identifier as authority. Add an integration test with a
token-configured relay that proves anonymous delete is rejected and owner
revoke succeeds. This audit intentionally did not call the public endpoint,
because even a correct request can delete a live binding.

### Medium: public/unlisted history is plaintext metadata/content disclosure

Open-read is documented behavior, but it means content and sender aliases are
not protected by `unlisted`. Public room IDs are enumerable; unlisted room IDs
may leak in links, logs, transcripts, or user prompts. The relay's message
envelope currently supports `enc="none"` in the room path, so the relay can
store and return readable room content.

**Recommendation:** label `unlisted` as "hidden, not secret" in every user
facing room-creation flow, make `gated`/`private` the privacy-preserving
choices, and decide whether room messages need end-to-end encryption before
claiming confidential group chat.

### Medium: peer directory is broad, not public

Every bound relay identity can retrieve live peer registration data from
`/list`, including session/node identifiers and host-routing metadata. This is
not an anonymous public directory, but it is a federation-wide directory for
any participant.

**Recommendation:** document this distinction explicitly and minimize fields
returned to ordinary peers if cross-host discovery does not require all of
them. Keep `include_dead` Bearer-only.

### Operational risk: production setting drift is not source-visible

The source has security-sensitive runtime switches (notably the Bearer token
and signed-room-op requirement). `/health` verifies `auth_mode:"prod"`, but
does not expose the signed-room-op setting. A deployed configuration review is
needed before treating the source's strict path as a live guarantee.

### Documentation drift: relay landing page describes the wrong auth model

`ocaml/relay_server_html.ml` currently says that every route except `/` and
`/health` requires a Bearer token. That is false: the actual policy permits
the anonymous routes above, has Ed25519 peer routes, Bearer-only admin routes,
and body- or header-proof routes. The page also calls `/list_rooms` "public
rooms only" although the implementation lists `gated` rooms.

**Recommendation:** update the landing page from `auth_decision`'s route
classes as part of the remediation, and add a lightweight checked contract so
the operational description cannot silently drift again.

## Verification evidence

Local source/test validation to run from this checkout:

```bash
opam exec -- dune exec ./ocaml/test/test_relay_auth_matrix.exe
python3 -m unittest tests.test_relay_signed_room_ops_gate
```

The first locks the unauthenticated, peer, admin, bootstrap, and self-auth
route classification. The second exercises the visibility matrix, including
public/gated listability, unlisted/private omission, open read for
public/unlisted history, and member-only history for gated/private rooms.

**Observed result in this checkout:** the OCaml matrix passed all 35 cases and
the Python visibility suite passed 18 cases with 1 skip. The first attempted
plain `dune exec` failed before execution because the shell's default Dune
environment did not contain `alcotest`; `opam exec --` selected the repository
switch and passed. Existing compiler warnings were emitted but did not fail
either test command.

The live, read-only checks used for this audit were equivalent to:

```bash
curl -i https://relay.c2c.im/health
curl -i https://relay.c2c.im/list_rooms
curl -i https://relay.c2c.im/list
curl -i https://relay.c2c.im/device-login
curl -i -H 'content-type: application/json' \
  --data '{"room_id":"b111-no-such-room","limit":1}' \
  https://relay.c2c.im/room_history
```

No live write, registration, inbox, pairing, or authenticated request was made.

## Source map

- `ocaml/relay_server_auth.ml:auth_decision` — top-level route class and
  header-auth boundary.
- `ocaml/relay.ml:Relay_server.make_callback` — actual HTTP route dispatch and
  Ed25519 verification before dispatch.
- `ocaml/relay.ml:SqliteRelay.list_rooms` and
  `ocaml/relay.ml:InMemoryRelay.list_rooms` — directory visibility filter and
  serialized `members` aliases.
- `ocaml/relay.ml:handle_room_history` — open-read versus member-read rule.
- `ocaml/relay.ml:SqliteRelay.list_peers` and `handle_list` — peer directory
  row contents.
- `ocaml/relay.ml:try_verify_ed25519_request` — request-signature, replay, and
  identity-binding checks.
- `ocaml/relay.ml:verify_room_op_proof` — body proof and legacy unsigned
  compatibility path.
- `ocaml/test/test_relay_auth_matrix.ml` and
  `tests/test_relay_signed_room_ops_gate.py` — regression coverage discussed
  above.
