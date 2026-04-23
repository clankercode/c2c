# Relay API design review — 2026-04-23

## TL;DR

The relay HTTP surface is an RPC-flavoured JSON-over-HTTP API implemented as a
single `match meth, path` tower in `ocaml/relay.ml` (lines 2684–2794). It is
internally consistent: every route POSTs JSON and returns JSON with an
`ok`/`error_code`/`error` envelope, JSON content-type is set uniformly, and a
small family of `respond_*` helpers (lines 1879–1898) centralises status-code
selection. That consistency is the strong suit — a new endpoint fits the mould
in a few lines.

The design weaknesses are all structural and will bite the M1 mobile-app work:
**(1) no `/v1/` prefix**, so there is no way to evolve the wire format without
breakage; **(2) HTTP status codes are under-used** — handler-level validation
errors collapse onto 200 or 400, and the handlers for `register`, `send`,
`join_room` return 200 OK even on semantic failure, with `ok:false` as the
real signal; **(3) naming is RPC verbs, not resources** — `/invite_room`,
`/uninvite_room`, `/send_room`, `/list_rooms`, `/room_history` are five
endpoints against one `rooms` resource; **(4) unbounded list responses** on
`/list`, `/dead_letter`, `/list_rooms`, `/room_history` (no cursor/limit);
**(5) no `X-Request-Id`, no `Cache-Control`, no `ETag`** — GETs are fully
uncacheable and there is nothing to correlate a misrouted send with a relay
log line. The upcoming `GET /pubkey/<alias>` is exactly the endpoint where
ETag/`Cache-Control` would matter most; if it lands without them, the mobile
client will refetch the same pubkey every poll.

The good news: fixes are mechanical. A `/v1/` prefix with a legacy-alias
fallback, a typed `respond_validation_error`/`respond_conflict` path, and a
`{cursor, items, next_cursor}` convention on list endpoints would carry the
relay through M1 + M2 without another breaking change.

## Endpoint inventory

Table below is the full surface of `make_callback` (`relay.ml:2601–2795`).
Auth column: **none** = in the `is_unauth` list (`relay.ml:1805`),
**self** = body-level Ed25519 proof verified inside the handler
(`is_self_auth`, `relay.ml:1821–1828`), **peer-Ed25519** = per-request
Ed25519 header signature, **admin-Bearer** = Bearer token from `token` arg.

| Method | Path                    | Auth              | Request body                               | Response shape                                             |
|--------|-------------------------|-------------------|--------------------------------------------|------------------------------------------------------------|
| GET    | `/`                     | none              | —                                          | HTML landing page (`landing_html`, `relay.ml:1902`)        |
| GET    | `/health`               | none              | —                                          | `{ok, version, auth_mode}`                                 |
| GET    | `/list`                 | none / admin      | `?include_dead=1` (admin)                  | `{ok, peers:[...]}` — unbounded                            |
| GET    | `/dead_letter`          | admin-Bearer      | —                                          | `{ok, dead_letter:[...]}` — unbounded                      |
| GET    | `/list_rooms`           | none              | —                                          | `{ok, rooms:[...]}` — unbounded                            |
| GET    | `/gc`                   | admin-Bearer      | —                                          | `{ok, expired, pruned}` (**GET mutates state**)            |
| GET    | `/remote_inbox/<sid>`   | admin-Bearer      | path-encoded session_id                    | `{ok, messages:[...]}`                                     |
| POST   | `/admin/unbind`         | admin-Bearer      | `{alias}`                                  | `{ok, removed, alias}`                                     |
| POST   | `/register`             | self (body-Ed25519)| `{node_id, session_id, alias, identity_pk?, sig?, nonce?, ts?, ttl?, client_type?}` | `{ok, result, lease}` or `{ok:false, error_code, error, existing_lease}` (all 200 unless JSON parse fails) |
| POST   | `/heartbeat`            | peer-Ed25519      | `{node_id, session_id}`                    | `{ok, result, lease}`                                      |
| POST   | `/send`                 | peer-Ed25519      | `{from_alias, to_alias, content, message_id?}` | `{ok, result, ts}` or `{ok:false, error_code, error}`   |
| POST   | `/send_all`             | peer-Ed25519      | `{from_alias, content, message_id?}`       | `{ok, result, ts, delivered:[], skipped:[]}`               |
| POST   | `/poll_inbox`           | peer-Ed25519      | `{node_id, session_id}`                    | `{ok, messages:[...]}`                                     |
| POST   | `/peek_inbox`           | peer-Ed25519      | `{node_id, session_id}`                    | `{ok, messages:[...]}`                                     |
| POST   | `/join_room`            | self              | `{alias, room_id, identity_pk?, sig?, nonce?, ts?}` | `{ok, result}`                                     |
| POST   | `/leave_room`           | self              | same                                       | `{ok}`                                                     |
| POST   | `/set_room_visibility`  | self              | `{alias, room_id, visibility, …proof}`     | `{ok, result}`                                             |
| POST   | `/send_room`            | self              | `{from_alias, room_id, content, message_id?, envelope?, …proof}` | `{ok, result, ts, delivered, skipped}`           |
| POST   | `/room_history`         | none              | `{room_id, limit?}`                        | `{ok, room_id, history:[...]}` — no cursor                 |
| POST   | `/invite_room`          | peer-Ed25519      | `{alias, room_id, invitee_pk, …proof}`     | `{ok, ...}`                                                |
| POST   | `/uninvite_room`        | peer-Ed25519      | same                                       | `{ok, ...}`                                                |

Note: `auth_decision` at `relay.ml:1827` lists `/send_room_invite` as a
self-auth route, but the router dispatches `/invite_room` and
`/uninvite_room` (`relay.ml:2764, 2770`). The `send_room_invite` entry is a
dead/ghost path — see Critical #3.

## Critical findings

**C1. No API versioning.** No `/v1/` prefix, no `Accept: application/vnd.c2c.v1+json`,
no version echo in the request envelope. The mobile-app M1 breakdown adds
`GET /pubkey/<alias>`, `POST /mobile-pair`, `POST /mobile-pair/prepare`,
`POST /device-pair/*`, `WSS /observer/<binding>` — these will live alongside
today's endpoints and there is no path-shape that says "this is the v1
contract, stable". The only versioning artefact today is
`{version: "..."}` inside `/health` (`relay.ml:2054`) which is build SHA, not
API version. Fix: mount everything at `/v1/` *now*, before mobile ships; keep
bare paths as a legacy alias that routes to the same handlers and logs a
`legacy_path` counter so we can measure deprecation. Once legacy traffic hits
zero, drop it. Doing this after mobile lands is a breaking change.

**C2. Handlers return 200 OK on semantic failure.** `handle_register` on
alias-conflict returns 200 with `{ok:false, error_code, existing_lease}`
(`relay.ml:1731–1732`). `handle_send` on unknown recipient returns
`json_of_send_result (\`Error ...)` which is also 200 (`relay.ml:2188`).
`handle_join_room` similarly (`relay.ml:2316`). Any HTTP-level tool — a
curl smoke test, a CDN, a mobile library that treats non-2xx as failure —
cannot tell a successful registration from a conflict. 409 Conflict for
alias-taken, 404 for unknown recipient, 422 for semantic body errors. The
`respond_conflict` helper is defined (`relay.ml:1892`) but never called
anywhere in the file — confirmed via `grep -c`, it has zero call sites.
`respond_internal_error` (`relay.ml:1893`) is also unused. This is dead
infrastructure because the envelope pattern won.

**C3. `send_room_invite` vs `invite_room` path mismatch.** `auth_decision`
lists `/send_room_invite` as a self-auth route (`relay.ml:1827`) but the
router has no such route; the invite endpoints are `/invite_room` and
`/uninvite_room` (`relay.ml:2764, 2770`), and the router dispatches them
only if peer-Ed25519 header auth succeeds (they are **not** in the
`is_self_auth` allowlist). This means the two invite routes do *not* get
the "body-level proof bypass" the other room-mutation routes get — a client
sending only body-level proof (no header Ed25519) is rejected, inconsistent
with `/join_room`, `/leave_room`, `/send_room`. Either add
`/invite_room`/`/uninvite_room` to `is_self_auth`, or remove the ghost
`/send_room_invite` entry and confirm the invite routes require header
auth by design. The code comment (`relay.ml:1817–1820`) implies the former.

**C4. Method/semantic mismatches.**
- `GET /gc` triggers garbage collection — mutates state on a GET
  (`relay.ml:2701–2702`). GETs must be safe and idempotent. This should
  be `POST /gc` (or `POST /admin/gc` — admin route anyway).
- `POST /room_history` is a pure read with no side effect (`relay.ml:2782–2786`)
  and takes only `{room_id, limit}` — should be `GET /rooms/<id>/history?limit=N`.
  POST makes it uncacheable and hides the safe semantics.
- `POST /peek_inbox` — also a read; same story.

**C5. Unbounded list responses.** `/list`, `/dead_letter`, `/list_rooms`,
`/room_history`, `/poll_inbox`, `/peek_inbox` all return `{items:[...]}` with
no cursor, no `next_cursor`, no explicit upper bound visible in the handler
surface. For a 50-agent swarm it is fine; at 5k peers or once rooms accumulate
history, `/list_rooms` and `/room_history` will be the first to break. Adopt
`{items, next_cursor, truncated}` now while callers are in-repo — retrofitting
pagination onto a live unauthenticated GET (`/list_rooms`) is painful.

## Important findings

**I1. Mixed RPC and REST naming.** Room operations are five flat verbs
(`/join_room`, `/leave_room`, `/send_room`, `/invite_room`, `/uninvite_room`,
`/room_history`, `/set_room_visibility`, `/list_rooms`) where a resource model
would be one `/rooms`/`/rooms/<id>` tree. The RPC form is fine for an
internal swarm broker, but it means every new room verb adds a top-level path
and the CLI wrapper in `c2c_relay_connector.ml` has to mirror each. The M1
breakdown's `POST /mobile-pair`, `POST /device-pair/prepare`, etc. extend the
verb style, which is at least consistent — but `GET /pubkey/<alias>` is
resource-shaped. Pick one: either `/v1/peers/<alias>/pubkey` (resource) or
`/v1/pubkey_lookup?alias=...` (RPC). Don't mix a resource-style GET with
verb-style POSTs under the same version.

**I2. No request/trace ID.** The relay does not read `X-Request-Id` from
inbound requests and does not emit one in responses (searched
`relay.ml` — zero references). The structured log line on rate-limit denial
(`relay.ml:2611`) includes `source_ip_prefix` and `path` but no request ID.
When a swarm agent reports "my send returned `ok:false` and I can't find
it in the relay log", there is nothing to join on. Accept and echo
`X-Request-Id`; generate one if absent; include in every log line.

**I3. No cache controls, no ETag.** The `respond_json` helper
(`relay.ml:1879–1885`) sets only `Content-Type`. No `Cache-Control: no-store`
on the peer routes, no `Cache-Control: public, max-age=…`/`ETag` on
`/health` or the upcoming `/pubkey/<alias>`. Pubkeys are content-addressable
and change rarely; `ETag` + `If-None-Match` would cut mobile bandwidth
significantly. Today, even the static HTML landing page (`GET /`) has no
cache header. Add `Cache-Control: no-store` by default on the JSON helper,
override on GETs that should cache.

**I4. JSON parse error shape is inconsistent with other 400s.** Every POST
handler has the boilerplate `match json with | Error msg -> respond_bad_request
(json_error_str err_bad_request ("invalid JSON: " ^ msg))` repeated 12 times
(`relay.ml:2705–2786`). The error_code is always `err_bad_request` with a
human message concatenated — parsers can't distinguish "malformed JSON" from
"missing field `alias`" without substring-matching. Introduce
`err_invalid_json` and lift the parse into a helper so all POST routes share
one definition.

**I5. Error bodies sometimes leak internal detail.** Most error paths emit
short messages ("alias is required"), but some include full schema
explanations in the user-facing `error` string (`relay.ml:2246–2247`: "client
must upgrade to sign room ops and/or set C2C_REQUIRE_SIGNED_ROOM_OPS=0 on
the server"). Server-side env-var names in client-visible errors is a mild
information leak and couples client UX to server deployment knobs. Keep
`error_code` stable and machine-readable; move the human hint to a
`hint` field that server can trim in prod mode.

**I6. No OpenAPI/JSON-Schema spec.** The contract is the OCaml `match`
expression plus the client module. Any non-OCaml consumer (Python shim,
future Rust/TS mobile client, curl smoke tests, third-party relay
re-implementation) has to read `relay.ml` to learn the shape. For ~20
endpoints this is tractable to auto-generate — an OpenAPI 3 YAML checked
into `ocaml/` would let us diff breakage at CI time and let the mobile
client generate a typed client.

## Minor / nits

**M1. GET vs POST inconsistency on read endpoints.** `/list`, `/list_rooms`,
`/dead_letter`, `/remote_inbox/<sid>` are GET (good). `/poll_inbox`,
`/peek_inbox`, `/room_history` are POST (inconsistent — they read too).
The justification is "body carries identity", but the body is just
`{node_id, session_id}` which fits fine as query params, and with Ed25519
request-signing the signature already covers the path+query.

**M2. `/remote_inbox/<session_id>` uses a handwritten prefix match.**
`relay.ml:2788–2791` does `String.length path > 14 && String.sub path 0 14
= "/remote_inbox/"`. A single typo in the `14` silently breaks routing; the
literal appears twice (`relay.ml:1811, 2789`) and must stay in sync. Extract
`let remote_inbox_prefix = "/remote_inbox/"` and derive the length. Same
applies if/when `/pubkey/<alias>` and `/device-pair/<code>` land — factor
out a `match_prefix` helper now.

**M3. No `OPTIONS` handler, no CORS.** `meth_to_string` recognises OPTIONS
(`relay.ml:2527`) but no branch in the router accepts it — everything falls
through to 404. Fine for pure agent use; will bite the moment a browser-based
observer or diagnostic page tries to hit `/health` cross-origin.

**M4. `landing_html` hard-codes endpoint links** (`relay.ml:1938`: `<a
href="/list">/list</a>` and `/health`). Any rename in the router diverges
the landing page. Minor but worth noting as the inventory grows.

**M5. No redirect handling.** No 301/302 emitted anywhere. Good — staying out
of that tar pit. But when v1 lands, legacy-path → `/v1/...` might best be
a same-URL alias (the router dispatches both) rather than a 301, since many
agent HTTP clients don't follow redirects on POST by default.

**M6. `c2c_relay_connector.ml` duplicates path literals.** All 20+ endpoint
paths are hard-coded strings in the client module (`relay.ml:3005–3209`).
A shared constants module would let the router and client import the same
symbols — prevents the `/send_room_invite` vs `/invite_room` ghost-path
drift described in C3.

## What's strong

- **Single response helper family with consistent content-type.** Every
  JSON response goes through `respond_json` (`relay.ml:1879`), which always
  sets `Content-Type: application/json`. The HTML landing page uses
  `respond_html` with the correct `text/html; charset=utf-8`. No raw
  `respond_string` calls leak through.
- **Envelope is uniform.** `{ok, error_code?, error?, ...}` via `json_ok`
  and `json_error` (`relay.ml:1711–1721`). Every client knows exactly one
  shape to pattern-match on. This is the main reason the codebase tolerates
  the "200 on semantic failure" issue — the envelope makes it survivable.
- **Auth is table-driven.** `auth_decision` (`relay.ml:1800–1842`) is the
  one place to reason about which routes need what. The comments
  (`relay.ml:1813–1820`) explicitly explain the self-auth bypass — rare and
  valuable.
- **Rate limiter keys by path.** `Rate_limiter_inst.check … ~path`
  (`relay.ml:2609`) means per-route budgets are possible without code changes.
  Good hook for M1's strict pairing-endpoint limits.
- **Dev mode is explicit.** `auth_mode` in `/health` and the stderr banner
  (`relay.ml:2833`) make it loud when the relay is unauth'd.

## Scope of review

- Read: `ocaml/relay.ml` routing tower (lines ~1700–2850), response helpers
  (1879–1898), auth decision (1800–1842), landing HTML (1902–1940),
  JSON envelope (1711–1769), and full `make_callback` match
  (2601–2795). Skimmed: `ocaml/c2c_relay_connector.ml` client surface (505
  LOC), and `.projects/c2c-mobile-app/M1-breakdown.md` §S2 / §S4 / §S5a for
  upcoming endpoints.
- **Out of scope** (by request): authentication scheme security, rate-limit
  tuning, handler perf, SQL schema, relay broker internals. Those live in
  sibling review files.
- Not verified: behaviour under malformed `Content-Length`, slowloris,
  partial JSON — those belong in a security/robustness pass.
