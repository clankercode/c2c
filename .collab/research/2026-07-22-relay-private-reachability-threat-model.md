# Relay private-reachability threat model and protocol options

**Backlog:** B269

**Status:** provisional design input for B262; not an implemented security property

**Evidence baseline:** `master` at `fdbb30d8`, with B219 complete

**Method:** static review of canonical OCaml implementation and named tests. Documentation was used only as a lead. The targeted `./ocaml/test/test_relay.exe` build succeeded; this research slice did not execute the test suite.

## Executive conclusion

c2c does **not** currently provide recipient-controlled first contact.

On a token-configured production relay, an unauthenticated internet caller cannot use ordinary `/list` or `/send`. However, any relay peer with a bound Ed25519 identity can list active registrations and send to a known alias. The relay verifies who sent the request; it does not verify that the recipient consented to that sender. The receiving connector has useful admission and rate controls, but its sender default is allow and it filters only after the relay accepted and destructively returned the message.

The only non-refuted protocol direction found in this slice is a **stateful, opaque, recipient-issued, sender-bound contact grant**:

- the recipient intentionally gives a high-entropy grant to a specific sender out of band;
- the relay stores only a one-way verifier plus the internal recipient mapping and the expected sender's Ed25519 key fingerprint;
- a dedicated contact-delivery endpoint accepts the grant only with an exact signed request from that bound sender;
- the grant is scoped, expiring, revocable, rotatable, and replay/idempotency protected;
- ordinary discovery does not expose private aliases, grant material, or a route that substitutes for the grant;
- existing alias-addressed `/send`, broadcast `/send_all`, and relay `/forward` cannot remain bypasses for private recipients;
- unsupported or mixed-version participants fail closed rather than falling back to alias delivery.

A plain bearer capability is insufficient for the stated sender-specific consent goal: anyone who obtains it becomes an authorised sender. A stateless derived route is not viable in c2c's architecture: routing and selective revocation require state, at which point it becomes the recommended model with extra root-key risk.

The recommendation is **provisional**, not ready for implementation. B261/B262 must still resolve the stable recipient principal, multi-device/recovery model, cross-relay validation, reciprocal-contact semantics, verifier storage, and exact persistence transaction boundary.

## Scope and evidence rules

This report answers one question:

> How can c2c make knowledge of an intentionally shared contact grant—not mere relay membership or alias knowledge—the authority for a sender's first private DM?

It does not claim to solve:

- anonymity from the relay operator;
- traffic-analysis resistance;
- universal end-to-end encryption;
- local compromise by another same-UID process;
- public-room membership privacy;
- model-level prompt-injection impossibility;
- host-local approval compromise.

These are separate security properties. In particular, **reachability authority and content confidentiality must not be conflated**. The contact-grant protocol may require a stricter encrypted envelope later, but recipient-controlled first contact can be specified and tested independently of whether all cross-host message content is encrypted. The public security page must describe each implemented layer separately.

Current-state claims below are either supported by an exact code symbol and named test, or explicitly marked as a coverage gap. Earlier research is retained in:

- `.collab/research/2026-07-21-security-page-claim-ledger.md`
- `.collab/research/2026-07-15-relay-ingress-controls-audit.md`
- `.collab/research/2026-04-29T04-22-52Z-slate-coder-relay-crypto-audit.md`

## Threat actors

### A1. Unauthenticated internet actor

Can reach public relay endpoints but has no relay-bound Ed25519 identity and no operator Bearer token.

Relevant limits and exposure:

- On a token-configured relay, ordinary peer routes such as `/list`, `/send`, and `/pubkey/*` reject this actor.
- `/health`, `/stats`, `/list_rooms`, `/room_history`, and `/device-login` pass the anonymous outer gate; handlers may add resource-specific checks.
- `/register` is self-auth bootstrap and therefore bypasses the outer header-auth gate. Its handler is the security boundary.
- A tokenless relay is explicit development mode and allows unsigned access to default peer routes.

### A2. Authenticated relay peer

Controls a relay-bound Ed25519 private key and can produce signed peer requests. This is the principal threat for unsolicited first contact: authentication proves the sender identity but currently grants broad discovery and delivery access.

### A3. Malicious or compromised peer

Has all A2 powers and deliberately enumerates registrations, probes error distinctions, replays requests/messages, leaks contact artefacts, sends malicious DATA, or exploits room/pairing side channels.

### A4. Curious or compromised relay operator

Controls the service, database, Bearer administration token, logs, and runtime. The operator can observe routing metadata and, on ordinary plaintext paths, content. A recipient contact grant cannot hide its relay-side mapping from this actor. The protocol should minimise stored reusable secrets and unnecessary metadata, but it cannot honestly promise relay blindness.

### A5. Compromised same-UID host process

May read files available to the user's account, invoke local CLI paths, or observe client state. c2c's host-local approval verdict boundary protects against peer messages, not against a compromised same-UID host. Contact grants stored locally inherit this trust boundary.

### A6. Holder of a leaked contact artefact

Possesses a copied grant without necessarily possessing the intended sender's Ed25519 private key. Sender binding must ensure possession of the grant alone is insufficient.

### A7. Room participant or room-directory observer

May learn public room rosters, gated room identifiers/member counts, or aliases visible through room presentation addresses. A room relationship must not implicitly grant private-DM authority.

### A8. Mixed-version or downgraded participant

Runs a client or relay that does not understand private contact grants, or deliberately strips contact protocol fields and retries through legacy `/send`. The safe behaviour is explicit failure, never alias fallback.

## Trust boundaries

1. **Client ↔ local broker:** same-account local state and host delivery surfaces.
2. **Client/connector ↔ relay HTTP or WebSocket:** URL-selected TLS may protect the hop; TLS is not mandatory in current code. A production contact protocol that sends a reusable grant must require authenticated TLS or an equivalently confidential transport; a signed body alone does not hide the grant from a cleartext-hop observer.
3. **Peer request authentication:** Ed25519 signed request binds method, path, query, body hash, timestamp, and nonce for ordinary HTTP peer routes.
4. **Recipient admission:** currently absent at relay enqueue; this is the new boundary.
5. **Relay persistence:** registration leases, inboxes, dead letters, replay state, room state, and future contact grants.
6. **Relay ↔ model/agent delivery:** message content remains untrusted DATA and cannot satisfy the host-local approval verdict path.
7. **Out-of-band grant transfer:** the recipient intentionally discloses a grant to a sender. Security depends on this channel delivering the artefact and the intended sender identity/key binding accurately.

## Current-state surface ledger

### Route-auth semantics: production versus development

`ocaml/relay_server_auth.ml` is the canonical outer classifier.

| Surface | Token-configured relay | Tokenless development relay | Evidence |
|---|---|---|---|
| `/list` | `Peer_ed25519` | unsigned allowed | `classify_route`, `auth_decision`; `test_relay_auth_matrix.ml::t_plain_list_is_peer`; `test_relay_landing_auth_contract.ml` checks `/list` as peer |
| `/list?include_dead=1` | `Bearer_admin` | unsigned accepted by `check_auth None` | `classify_route`; `t_admin_list_include_dead_bearer_ok` |
| `/send`, `/pubkey/*`, `/heartbeat` | `Peer_ed25519` | unsigned allowed | default branch of `classify_route`/`auth_decision` |
| `/register` | `Self_auth`; body handler decides | same | `self_auth_exact_routes`; `handle_register` |
| `/poll_inbox`, `/peek_inbox` | `Peer_ed25519` plus handler owner check | handler still fails closed unless `C2C_RELAY_ALLOW_UNSIGNED_INBOX=1` | `inbox_owner_required`; remote-broker tests below |
| `/list_rooms`, `/room_history` | `Anonymous_read`; handler applies visibility/member rules | same | `anonymous_read_routes`; room tests below |
| `/dead_letter`, `/gc`, `/admin/unbind`, `/remote_inbox/*` | `Bearer_admin` | unsigned allowed when no token is configured | `admin_exact_routes`, `admin_prefix_routes` |

**Resolved audit disagreement:** ordinary `/list` is not anonymous on a token-configured relay. It falls through to `Peer_ed25519`. Only tokenless development mode makes the peer route unsigned. The distinction is pinned by `test_relay_auth_matrix.ml::t_plain_list_is_peer` and `test_relay_landing_auth_contract.ml`.

### S1. Registration and identity bootstrap

**Current property:** `/register` has no outer header-auth requirement because a new alias cannot yet sign as a bound relay identity. The signed registration branch verifies a body-level Ed25519 proof, timestamp, and nonce. A legacy identity-less registration path remains accepted when other policy does not reject it.

- Code: `ocaml/relay.ml::handle_register`; `ocaml/relay_signed_ops.ml`; backend registration in `InMemoryRelay.register`/`SqliteRelay.register`.
- Tests: `ocaml/test/test_relay_auth_matrix.ml::t_register_allowed_no_auth_prod`; `ocaml/test/test_relay_bindings.ml::test_register_without_pk_legacy`, signed registration and nonce tests.
- Conditions: configured alias allowlisting and proof-of-work can further restrict registration.
- Gap: production token configuration alone does not make every registration identity-bearing.

**Design consequence:** contact delivery must require a bound cryptographic sender principal; a legacy identity-less registration cannot exercise a sender-bound grant.

### S2. Peer listing and registration metadata

**Current property:** a bound peer on a token-configured relay can call `/list`; tokenless development mode makes the route unsigned. `handle_list` maps every returned lease through `RegistrationLease.to_json`.

- Code: `ocaml/relay.ml::handle_list`; `ocaml/relay_registration_lease.ml::to_json`; `ocaml/relay_server_auth.ml::classify_route`.
- Exposed fields when present include alias, node/session identifiers, lease/liveness timing, identity and encryption public keys, opaque host identifier, client version, and client OS.
- Tests: auth class is pinned by `t_plain_list_is_peer` and the landing auth contract. No focused HTTP test was found that asserts the complete `/list` metadata shape against privacy requirements.

**Design consequence:** preventing unsolicited contact requires more than adding grants. Private recipient aliases and usable route metadata must no longer be globally returned to ordinary peers. Admin and owner diagnostics need separate, explicit visibility.

### S3. Public-key lookup

**Current property:** `/pubkey/<alias>` is a default peer route. A token-configured relay requires verified peer Ed25519 auth; tokenless development mode permits unsigned access. A known alias returns identity/encryption keys; an unknown alias returns a distinct error.

- Code: `ocaml/relay.ml::handle_pubkey`; `ocaml/relay_server_auth.ml` default `Peer_ed25519` class.
- Tests: `ocaml/test/test_relay_pubkey.ml` covers backend known/unknown lookup. A focused production HTTP auth-and-enumeration test was not found.

**Design consequence:** private contact cannot depend on an alias-indexed public-key lookup that reveals recipient existence. The out-of-band contact artefact may carry a contact encryption key or key identifier without revealing the ordinary alias.

### S4. Direct one-to-one send

**Current property:** on a token-configured relay, `/send` requires a verified peer request. `handle_send` validates required fields and binds signed request identity to body `from_alias`, then calls `R.send`. There is no recipient consent/grant check before durable routing.

- Code: `ocaml/relay.ml::handle_send`, `from_alias_signer_name`, `reject_alias_mismatch`; backend `send` implementations.
- Recipient outcome distinguishes unknown from dead in backend result/reason paths. `InMemoryRelay.send` records content-bearing dead letters for these local-send failures; `SqliteRelay.send` returns the errors without inserting a dead-letter row. Separate forwarding-failure paths can also persist dead letters.
- On `InMemoryRelay`, `handle_send` treats both `` `Ok `` and `` `Duplicate `` as successful for WebSocket, short-queue, and observer pushes, so replaying an already-recorded message ID can re-push. `SqliteRelay.send` currently has no equivalent message-ID uniqueness/idempotency result.
- Tests: auth-matrix peer-route tests, `ocaml/test/test_relay.ml::test_relay_send_to_unknown_alias_goes_to_dead_letter`, and backend send tests cover pieces. A single integration test proving all production `/send` auth, sender binding, backend-specific recipient outcome, dead-letter, idempotency, and push behaviour was not located.

**Design consequence:** request authentication is necessary but not sufficient. Recipient-grant validation must happen before inbox enqueue, WebSocket push, short queue/observer effects, notification, message statistics, or any content-bearing dead-letter persistence. Existing alias `/send` must not remain a bypass for private recipients. Contact message-ID idempotency is greenfield and must be implemented consistently in both backends.

### S4b. Broadcast and relay-forward delivery

**Current property:** `/send_all` is a default `Peer_ed25519` route. `handle_send_all` invokes `R.send_all`, which fans a message out to every live lease except the sender without recipient-specific consent. The backends insert inbox rows, and the handler emits delivery side effects for recipients. `test_relay_send_all_broadcasts_to_all_except_sender` pins the broadcast semantics.

`/forward` is a self-auth route for authenticated relay-to-relay forwarding. Its handler can deliver locally after source-relay authentication; that hop authentication does not prove that each destination recipient consented to the original end sender.

- Code: `ocaml/relay.ml::handle_send_all`, `InMemoryRelay.send_all`, `SqliteRelay.send_all`, `handle_forward`; `ocaml/relay_server_auth.ml` route classes.
- Tests: `ocaml/test/test_relay.ml::test_relay_send_all_broadcasts_to_all_except_sender`; relay-forward authentication tests.

**Design consequence:** protecting only `/send` would leave two live bypasses. Private/contact-gated recipients must be excluded from `/send_all` unless they explicitly authorise a separately designed broadcast capability. `/forward` must carry destination-verifiable original-sender/grant authority or fail closed before local delivery.

### S5. WebSocket subscription and delivery

**Current property:** `/ws/subscribe` bypasses the outer peer header gate but validates an alias, timestamp, and signature against the alias's bound identity before creating an alias-specific subscriber. Dynamic subscription additions are also validated.

- Code: `ocaml/relay.ml` WebSocket subscribe handler; `ocaml/relay_ws_server.ml::validate_subscribe_auth`, subscriber map, `push_dm`.
- Tests: `ocaml/test/test_relay_ws_server.ml::test_validate_auth_unknown_alias`, subscriber-map tests.
- Caveats: initial subscribe proof has a timestamp window but no nonce cache; detailed auth failures can reveal binding/existence distinctions; pushed DM content is visible to the relay.

**Design consequence:** contact-grant admission belongs before any push. Subscription ownership does not authorise a sender.

### S6. Inbox ownership

**Current property:** signed peer identity cannot read or drain another alias's session inbox. Poll and peek resolve the supplied node/session to an owning alias and require the verified signer to match.

- Code: `ocaml/relay.ml::inbox_owner_required`, poll/peek handlers.
- Tests: `ocaml/test/test_relay_remote_broker.ml::test_verified_attacker_cannot_peek_victim`, `test_prod_unsigned_poll_rejected_and_not_drained`, `test_prod_attacker_signed_poll_rejected` (which also asserts the victim inbox was not drained), and `test_prod_attacker_signed_peek_rejected`.
- Development caveat: `C2C_RELAY_ALLOW_UNSIGNED_INBOX=1` on a tokenless relay enables unsigned owner bypass; tests include `test_dev_unsigned_poll_still_allowed`.
- Admin caveat: `/remote_inbox/*` is Bearer-admin in production and open in tokenless mode.

**Design consequence:** recipient inbox ownership is already a strong separate boundary and should remain unchanged. Contact authority grants send admission, never inbox read authority.

### S7. Connector outbox, polling, and local admission

**Current property:** the connector registers local sessions, sends durable remote-outbox entries, destructively polls relay inboxes as the registered aliases, filters returned messages, then appends accepted rows locally.

- Code: `ocaml/c2c_relay_connector.ml` outbox/state functions, signed request construction, sync loop, `filter_inbound_messages*`.
- Local policy supports sender allow/deny, recipient disable, size caps, recipient binding, and sender/recipient/machine rate limits.
- Default sender action is `Inbound_allow`.
- Tests: `ocaml/test/test_c2c_relay_connector.ml::test_inbound_policy_defaults`, `test_inbound_policy_parses_admission_and_recipient_controls`, `test_inbound_policy_invalid_fails`, size/rate/binding cases.

**Design consequence:** local filtering remains defence in depth, but it cannot substantiate “no unsolicited relay message.” The relay has already accepted and returned the row. Consent must be enforced before relay enqueue.

### S8. Rooms and room discovery

**Current properties:**

- Anonymous `/list_rooms` shows public and gated rooms.
- Public room rows include presentation-address rosters; gated rows include room ID and member count but redact members.
- Unlisted rooms appear to verified current members; private rooms do not appear in the directory.
- Public/unlisted rooms are open join; gated/private require invitation/approval.
- Public/unlisted history may be anonymously readable when `history_public=true`; gated/private history requires a verified current member.

- Code: `ocaml/relay.ml::handle_list_rooms`, room visibility/admission/history handlers and backend methods.
- Tests: `ocaml/test/test_relay_list_rooms_roster.ml::test_inmemory_no_metadata_leak`, `test_sqlite_no_metadata_leak`, visibility and HTTP anonymous-list cases; room-history suites.
- Caveats: gated room ID and membership cardinality are intentionally discoverable; public rosters reveal member presentation aliases; unlisted means obscured from listing, not access-controlled if the ID is known. Knock/error responses can distinguish some room states.

**Design consequence:** a room relationship, roster appearance, invite, knock, or room presentation alias must not become private-DM authority. Contact grants are DM-scoped and must not authorise any room operation.

### S9. Pairing and observer bindings

**Current property:** mobile pairing uses a short-lived stored token and machine-signed preparation; successful consumption burns the token and checks key bindings. Binding revocation uses signed owner proofs and deliberately gives uniform denial for unknown/non-owner/replay cases.

- Code: `ocaml/relay.ml` mobile-pair and binding handlers; `ocaml/relay_pairing_token_sql.ml`; observer WebSocket handling.
- Tests: `ocaml/test/test_relay_mobile_pair.ml::test_store_and_burn_happy_path`, `test_expired_token_not_returned`; `ocaml/test/test_relay_binding_revoke_auth.ml` uniform-denial, replay, and owner cases.
- Caveat: the older pairing-token helper's select/update shape is not proof of atomic consumption across multiple SQLite processes. B219 serialises operations inside one relay instance but does not itself establish a cross-process transaction.

**Design consequence:** pairing supplies useful patterns—short-lived opaque material, owner proof, uniform denial—but contact-grant consumption/revocation needs an explicit atomic persistence design rather than copying pairing semantics uncritically.

### S10. Anonymous operational and administrative exposure

- `/health` anonymously reports version/protocol/auth mode and proof-of-work posture.
- `/stats` anonymously returns aggregate activity including version/OS buckets but is intended not to return aliases or content.
- `/dead_letter`, `/gc`, `/admin/unbind`, and `/remote_inbox/*` require Bearer-admin when configured; tokenless development mode accepts them without a token.
- Stored dead-letter rows contain sender, recipient, reason, and message content. Creation is path- and backend-specific: `InMemoryRelay.send` records unknown/dead local-send failures, while `SqliteRelay.send` does not; forwarding failures and explicit dead-letter operations have separate paths.

- Code: `ocaml/relay_server_auth.ml`; `ocaml/relay.ml::handle_health`, `handle_stats`, `handle_dead_letter`, admin handlers; backend send/dead-letter methods.
- Tests: `ocaml/test/test_relay_landing_auth_contract.ml`; `ocaml/test/test_relay_stats.ml`; `ocaml/test/test_relay_auth_matrix.ml` admin cases.

**Design consequence:** unauthorised contact attempts must not be copied into content-bearing dead letters, and raw grants must not enter logs, metrics, receipts, errors, or diagnostics. Tokenless development mode cannot support production security claims.

### S11. Error and existence oracles

Current surfaces distinguish several states:

- public-key lookup distinguishes unknown alias;
- direct send distinguishes unknown/dead reasons internally; InMemory local-send failures additionally create dead letters, whereas Sqlite local-send failures do not;
- WebSocket subscription reports detailed binding/auth failures;
- room knock/join paths distinguish not found, direct-join, invited, and membership states;
- some pairing/device-code paths distinguish missing/pending/claimed;
- binding revocation is a positive example of deliberately uniform denial.

**Design consequence:** contact delivery should return the same unauthorised response for unknown, malformed, expired, revoked, wrong-sender, wrong-recipient, and wrong-generation grants. Operational reason counters may be retained without exposing the distinction to the caller or logging grant/body material.

## Desired private-reachability invariants

Each invariant is binary and intended to become a regression property.

### G1. Consent before any delivery side effect

Without a valid current recipient-issued grant for the verified sender, no direct, broadcast, or forwarded path may create a relay inbox row, local broker row, WebSocket/short-queue/observer push, wake/notification, message statistic, archive, or content-bearing dead letter for a private recipient.

### G2. Non-enumerable private reachability

An unrelated authenticated peer cannot derive a usable private-recipient destination from peer listing, aliases, public-key lookup, registration JSON, room surfaces, health/stats, errors, logs, or timing distinctions intentionally exposed by the protocol.

This does not claim anonymity from the relay operator or immunity to traffic analysis.

### G3. Sender binding

Possession of the contact artefact without the intended sender's Ed25519 private key is insufficient. The verified request signer and grant-bound sender fingerprint must match exactly.

### G4. Recipient-controlled lifecycle

The recipient can expire, revoke, and rotate future authority without renaming the ordinary alias. Revocation linearisation and already-accepted-message semantics are explicit.

### G5. Exact admission and replay safety

The grant, sender identity, recipient mapping, scope, generation, message identifier, and accepted content representation are bound into the admission decision. An exact request replay and a fresh signed request carrying a duplicate message identifier cannot cause two deliveries.

### G6. Bounded disclosure and secret hygiene

Ordinary peers do not learn the recipient alias or reusable grant material. Raw grants do not appear in relay listings, logs, metrics, errors, receipts, dead letters, URLs sent over HTTP, or room metadata. The relay learns only routing/admission metadata required by the design.

### G7. Fail-closed compatibility

Old, unsupported, malformed, tokenless-development, or downgraded paths cannot silently substitute ordinary alias `/send`. Unsupported contact delivery returns an explicit local error and performs no network fallback.

### G8. Scope isolation

A DM contact grant cannot read inboxes, send broadcasts/rooms, join or mutate rooms, access history, manage bindings, invoke admin operations, approve actions, or create implicit reciprocal reachability.

### G9. Explicit principal, device, and recovery semantics

The design identifies who owns a grant, which recipient device set can receive/decrypt, how sender/recipient key rotation works, and what happens after device loss. It never silently treats a replacement key as the same authorised person.

### Separate confidentiality constraint C1

If private-contact delivery is specified to require application-layer confidentiality, it must accept only a newly defined, fully bound encrypted envelope and reject plaintext/fallback. Existing opportunistic relay E2E is not enough to make that claim. C1 is valuable but is not logically required to enforce G1–G9; B262 must decide whether it is in the first implementation slice.

## Candidate protocols

### Candidate A: opaque bearer contact capability

#### Sketch

Recipient generates 32 CSPRNG bytes and gives the artefact out of band:

```text
contact-v1 invitation = relay authority + 256-bit opaque capability
```

The sender submits it to a dedicated endpoint with an otherwise ordinary signed request. The relay resolves a one-way verifier to the recipient and checks expiry/revocation.

#### Strengths

- High-entropy value is not online-guessable in practice.
- Recipient alias need not be disclosed.
- Expiry, revocation, rotation, and uniform denial are possible with relay state.
- Simple import and sharing model.

#### Decisive error

**Fails G3.** Any holder can use the capability with their own registered identity. If the invitation is copied or leaked, the recipient cannot selectively revoke the unauthorised holder while preserving the intended sender; all copies are equivalent.

This remains a valid product idea only if explicitly named “any holder may contact me.” It does not meet sender-specific first-contact consent.

### Candidate B: stateful opaque sender-bound grant

#### Sketch

The recipient creates:

```text
grant_secret  = 32 CSPRNG bytes
sender_fp     = SHA-256(expected sender Ed25519 public key)
scope         = dm-first-contact
expires_at    = relay-authoritative expiry
generation    = recipient-controlled generation
```

The out-of-band contact card contains at least:

```text
protocol version
relay authority
grant_secret
expected sender identity or a locally verified binding ceremony
expiry
optional recipient contact encryption key/key-id (only if C1 is adopted)
```

The invitation is client input, not an HTTP URL. The client transmits the raw grant only in the contact-delivery request body or a dedicated non-logged credential field, and only over authenticated TLS or an equivalently confidential production transport. A request signature provides integrity/authentication but does not conceal the grant on a cleartext HTTP hop. The grant must never appear in an ordinary HTTP query string.

The relay stores no raw grant. It stores a one-way verifier and state conceptually equivalent to:

```text
verifier -> {
  internal recipient principal / delivery set,
  expected sender Ed25519 fingerprint,
  scope,
  expiry,
  generation,
  active/revoked state,
  bounded message-id replay state
}
```

Whether the verifier is plain SHA-256 of a 256-bit random secret or keyed HMAC is deferred to B261/B262. A 256-bit uniformly random secret already resists offline guessing; HMAC adds a relay-secret lifecycle and should not be adopted without defining rotation/recovery.

A dedicated endpoint avoids overloading legacy semantics:

```text
POST /contact/v1/deliver
signed request covers method, path, query, exact body hash, timestamp, nonce
body = {
  protocol,
  grant_secret,
  message_id,
  payload_or_bound_envelope
}
```

Relay acceptance requires, atomically with first durable enqueue:

1. a valid bound Ed25519 request signer;
2. grant lookup by one-way verifier;
3. exact signer public-key fingerprint equals the grant's sender fingerprint;
4. active state, current generation, correct scope, and unexpired relay time;
5. contact protocol/version and payload binding accepted by policy;
6. message ID not already accepted for this grant;
7. replay/idempotency state recorded with the enqueue transaction.

Any failed predicate has zero delivery effects and returns a uniform unauthorised result.

#### Lifecycle

- **Expiry:** relay time is authoritative.
- **Revocation:** define a linearisation point. A send committed before it may be delivered once; a send checked after it is rejected before enqueue.
- **Rotation:** mint an independent grant. Never retarget an existing opaque grant from one sender/recipient/scope to another.
- **Sender key rotation:** no alias-based successor inference. Recipient explicitly issues/rebinds a grant after verifying the new key.
- **Recipient/device rotation:** replacement and retained-key policy depend on the B262 device model. Never fall back to plaintext.
- **Replay retention:** retain message identifiers through a defined window at least as long as a grant can be retried; bound storage and garbage collection explicitly.

#### Disclosure and leak consequences

The intended sender must possess both the grant and corresponding Ed25519 private key. A leaked grant alone is inert for other identities. If both grant and sender key are compromised, the attacker has the intended sender's authority until revocation/expiry; the protocol cannot distinguish them.

The relay necessarily observes sender identity/IP, verifier match, internal recipient mapping, timing, size, and outcome. Per-grant recipient encryption keys can reduce cross-invitation correlation but increase device/recovery complexity.

#### Remaining unknown

**G9 remains unresolved.** Current c2c identities are alias/session and key-bound, but there is no general stable multi-device sender/recipient principal lifecycle for grants. Candidate B is the sole non-refuted direction, not yet an accepted complete design.

### Candidate C: private derived route

#### Sketch

```text
route = HMAC(recipient_root_secret, sender_ed25519_fp || epoch)
```

The sender submits the route rather than a random stored grant.

#### Decisive errors

A stateless relay cannot map this opaque value to the recipient without one of:

- a stable recipient identifier, which defeats G2/G6;
- trying every recipient/root, which is incompatible with c2c routing and leaks work/timing;
- a relay-side mapping, which makes the design stateful Candidate B.

Selective revocation also requires per-sender state. Root-secret rotation invalidates all contacts and creates a large recovery blast radius.

**Fails G1, G2, G4, and G6 in stateless form.** In stateful form it offers no relevant goal advantage over independently random sender-bound grants and adds root-key risk.

## Decisive IGC evaluation

### Context

A recipient wants a named sender—not every relay peer and not every holder of a copied string—to initiate a private first DM without exposing an ordinary alias as a usable contact address. The relay remains a routing/admission service and is not trusted for anonymity or content blindness.

| Idea | All | G1 | G2 | G3 | G4 | G5 | G6 | G7 | G8 | G9 |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| A. Bearer capability | ✘ | ✔ | ✔ | ✘ | ✔ | ✔ | ✔ | ✔ | ✔ | ? |
| B. Sender-bound opaque grant | ? | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ? |
| C. Stateless derived route | ✘ | ✘ | ✘ | ✔ | ✘ | ? | ✘ | ✔ | ✔ | ? |

- **A → G3:** any holder is an authorised sender; identity-specific consent is absent.
- **C → G1/G2/G6:** an opaque stateless value is not routeable without revealing a recipient, scanning/broadcasting, or adding the same mapping as B.
- **C → G4:** selective revoke requires state, eliminating the stated benefit.
- **B → G9:** no decisive error is known, but the necessary principal/device/recovery model has not been selected. `?` is required rather than pretending this is complete.

Candidate B is the only non-refuted direction. B262 should refine it after B261 reconciles persistence and transaction seams.

## Required compatibility and bypass rules

1. Introduce a dedicated contact endpoint; do not overload `/send` with ambiguous optional fields.
2. Mark recipient registrations private by default under the future migration policy; ordinary peer `/list` must not expose private leases.
3. Alias `/send` to a private recipient must not bypass contact admission. Established relationships, public addresses, or operator exceptions require explicit separate state/policy.
4. `/send_all` must exclude private/contact-gated recipients unless each recipient has intentionally authorised a separately specified broadcast capability. Relay `/forward` must carry destination-verifiable original-sender/grant authority or fail closed before local enqueue.
5. `/pubkey/<private-alias>` must not remain an existence oracle. Contact-key material, if needed, comes from the invitation or a grant-authorised lookup.
6. Contact clients must never retry an unsupported contact card as ordinary alias send.
7. Tokenless development mode cannot substantiate private-reachability claims. Contact delivery should fail closed there unless B262 defines an explicit equally strong development identity policy.
8. A grant is DM-only. It grants no room, broadcast, inbox, binding, admin, approval, or reciprocal-send power.
9. Replying does not implicitly create reciprocal authority. The recipient must intentionally issue a reciprocal grant or explicitly accept the relationship under a separately specified policy.
10. Cross-relay forwarding is not automatically covered. Existing `/forward` authenticates a source relay, not necessarily the original sender-to-grant binding at the destination. First implementation should either target the recipient's home relay directly or define destination-verifiable sender/grant attestation.
11. If C1 is selected, define a new fully bound contact envelope/version. Existing permissive plaintext/v1/v2 paths cannot satisfy strict contact confidentiality by configuration rhetoric alone.
12. Production contact delivery must require authenticated TLS or an equivalently confidential transport so a passive hop observer cannot capture reusable grant material.

## Attack and regression matrix

| Attack / boundary | Required verdict | Required evidence seam |
|---|---|---|
| Anonymous caller probes private alias | Uniform denial; no existence disclosure | HTTP route tests in token-configured and tokenless modes |
| Authenticated unrelated peer calls `/list` | Private lease/route absent | in-memory + SQLite list tests and HTTP response test |
| Authenticated peer guesses private alias and calls `/send` | No delivery side effect; uniform response | handler + both backends + push/observer spies |
| Authenticated peer calls `/send_all` | Private recipients excluded unless separately broadcast-authorised; no private-recipient side effect | handler + both backends + broadcast/push spies |
| Source relay calls `/forward` without destination-verifiable original-sender grant | No private-recipient delivery side effect | forward auth + destination admission tests |
| Valid grant used by wrong Ed25519 signer | Reject before enqueue | exact signer fingerprint tests |
| Matching signer but altered body/from key | Request/envelope verification failure | canonical body/signature mutation tests |
| Unknown, malformed, expired, revoked, wrong-generation grants | Same external response, zero side effects | table-driven endpoint tests |
| Raw grant appears in list/log/error/metric/dead-letter | Never | capture/redaction tests and persistence inspection |
| Exact signed request replay | Reject via request nonce | existing nonce seam plus contact endpoint integration |
| Fresh signed request with duplicate message ID | At most one delivery | atomic idempotency tests across restart/concurrency |
| Revoke races with send | Outcome matches documented linearisation | concurrent in-memory/SQLite tests; multi-process caveat explicit |
| Rotate grant A while grant B exists | A revoked/expired independently; B unaffected | grant isolation tests |
| Sender key rotates | Old grant does not silently transfer | key-change tests |
| Recipient device set changes | Exact selected model; no plaintext or stale-device fallback | multi-device tests after G9 decision |
| Old client imports contact card | Explicit unsupported; no `/send` fallback | CLI/connector compatibility tests |
| Old relay receives contact endpoint | Explicit unsupported; no alias retry | client HTTP fallback tests |
| Contact grant used on room/broadcast/admin/inbox route | Reject / structurally impossible | route-scope matrix |
| Public/gated room reveals member alias | Alias still not a usable private route | room-directory plus private-send test |
| Cross-relay attempt | Reject until destination-verifiable design exists | forwarding tests |
| Rejected malicious content | No inbox, push, notification, stats, archive, or content DLQ | integrated side-effect assertions |
| Accepted content reaches agent | Existing untrusted DATA framing retained; no approval authority | B098 ingress/approval regression suites |

## Persistence and concurrency questions for B261

B219 established one long-lived SQLite connection in the `SqliteRelay.t.db` record field, backed by the `c2c_relay.db` file, serialised by a non-reentrant relay mutex, with exception-safe statement finalisation. Future work must obey that ownership model, but it does not answer these protocol questions:

1. **Atomic admission:** which SQL transaction or conditional mutation atomically validates active grant state, inserts message-id idempotency state, and enqueues exactly one inbox row?
2. **Cross-process behaviour:** is one relay process per database an enforced invariant? If not, a process-local mutex is insufficient for grant consumption/revocation races.
3. **Canonical backend contract:** which `Relay_backend_contract.RELAY` methods represent issue/revoke/lookup/admit without leaking SQLite mechanics into handlers?
4. **Schema migration:** how are grant tables/columns added idempotently in `SqliteRelay.create`, with in-memory parity and fail-closed mixed-version behaviour?
5. **Verifier choice:** is unkeyed hashing of a 256-bit random secret sufficient, or is an HMAC relay key justified? If HMAC, define key generation, permissions, backup, rotation, and disaster recovery.
6. **Replay state:** what retention and GC bound applies to accepted message IDs, expired grants, and revoked verifier tombstones?
7. **Failure ordering:** how are uniform caller errors reconciled with useful bounded operator reason counters without secret/body logging?

## Protocol decisions for B262

B262 must resolve these before Candidate B can become All-✔:

1. **Recipient principal:** alias, account-like principal, machine identity, or another stable internal owner.
2. **Multi-device delivery:** shared synchronised contact key, per-device encrypted recipient entries, or designated home-device fan-out.
3. **Recovery:** what survives device loss, key loss, or relay migration; who may rebind a grant.
4. **Sender principal:** one Ed25519 key, an explicitly managed set, or a higher-level principal with signed device membership.
5. **Contact-key policy:** per-grant encryption key versus stable recipient contact key, if C1 is included.
6. **Reciprocity:** independent return grant versus explicit accepted-contact relationship.
7. **Cross-relay admission:** direct home-relay requests versus destination-verifiable source-relay attestation.
8. **Established contacts and public addresses:** whether these exist, how explicitly enabled, and how they remain non-enumerable.
9. **Development mode:** reject contact delivery entirely or define an unmistakable non-production policy that cannot be confused with the public guarantee.
10. **Confidentiality scope:** whether strict newly bound E2E is part of first release or a separate property. Do not imply it from reachability consent alone.

## Public-documentation implications

Until B259/B267 prove the implementation, the website must continue to say:

- production peer routes require authenticated relay identity, but authenticated peers can currently discover registrations and send unsolicited DMs;
- sender authentication prevents spoofing; it does not express recipient consent;
- local inbound allow/deny and rate policy exists, but default sender admission is allow and enforcement happens after relay acceptance;
- relay transport and application-layer encryption are conditional, not universal;
- peer content is DATA and cannot satisfy host-local approvals, but DATA framing is not proof that models are immune to prompt injection;
- ephemeral means local recipient-archive opt-out, not no trace.

After implementation, the desired statement may be made only if tests prove both halves:

1. a private recipient is not discoverable as a usable DM route; and
2. an authenticated sender without a recipient-issued, sender-bound grant cannot cause any delivery side effect.

The wording must also explain that intentionally sharing a grant authorises only its bound sender; leaking the grant alone does not authorise another identity, while compromise of the intended sender's private key defeats that distinction until revocation.

## Known gaps and cautions

- No focused HTTP test was found that asserts the complete ordinary `/list` metadata response under production authentication.
- No single endpoint integration test was found that pins all `/send` authentication, body-signer binding, backend-specific recipient outcome, dead-letter, idempotency, and push side effects together.
- Public-key lookup auth/existence behaviour is assembled from classifier and handler/backend tests rather than one focused production HTTP test.
- WebSocket subscribe uses timestamped signature validation but no nonce cache.
- Existing pairing burn semantics should not be cited as proof of atomic multi-process one-time use.
- `/device-pair/*` is currently classified as default `Peer_ed25519`, not `Self_auth`. The device-pair tests described as “self-auth” call `auth_decision` with `token=None`, where any peer-default route passes unsigned; they are false-green for route classification and do not prove production bootstrap works without an already bound peer identity. B262 must not reuse that flow without correcting and retesting the auth contract.
- B219's persistent connection and mutex make same-process SQLite operations serial, but do not substitute for explicit database transactions or a declared single-process ownership invariant.
- Candidate B deliberately leaves G9 unresolved. This is a successful research outcome, not permission to guess.

## Recommended next step

Complete B219 review, then execute B261 against the merged persistent-connection architecture. B261 should answer the persistence questions above without changing the protocol goals. B262 can then turn Candidate B into a complete specification, resolve G9, decide C1, and subject the result to independent protocol and usability review before B263 changes storage or relay behaviour.

--- SUMMARY ---

- **Current state:** production relay membership authenticates peers but does not grant recipient-controlled consent; peers can list registrations and send to known aliases.
- **Required property:** private routes are non-enumerable, and only a recipient-issued grant bound to the verified sender can cause first-contact delivery.
- **Recommended direction:** a stateful 256-bit opaque sender-bound grant, stored by one-way verifier, with expiry, revocation, rotation, scope, uniform denial, and atomic message-id idempotency.
- **Rejected rivals:** bearer capabilities fail sender binding; stateless derived routes cannot route or selectively revoke without becoming the stateful model.
- **Hard boundaries:** no `/send`, `/send_all`, or `/forward` bypass for private recipients; no room/admin/inbox/approval authority; authenticated confidential transport for reusable grants; no tokenless-production claim; and no claim of relay anonymity or universal E2E.
- **Open blocker:** stable principal, multi-device, recovery, cross-relay, reciprocity, verifier, transaction, and optional strict-E2E decisions remain for B261/B262.
