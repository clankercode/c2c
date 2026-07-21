# B262 — Recipient-issued, sender-bound relay contact grant protocol

**Status:** design freeze for B263–B267 implementation  
**Depends on:** B261 (persistence reconciliation), B269 (threat model)  
**Authority:** canonical OCaml surfaces in B261; this document freezes policy and acceptance properties, not code.

**Related:**

- `.collab/research/2026-07-22-relay-private-reachability-threat-model.md` (B269, provisional analysis)
- `.collab/research/2026-07-22-b261-private-reachability-persistence-reconciliation.md` (B261, interfaces)
- `.collab/research/2026-07-21-security-page-claim-ledger.md` (public claim constraints)

---

## 1. Purpose and non-goals

### Purpose

Make **knowledge of a recipient-issued, sender-bound contact grant**—not mere relay membership, alias knowledge, or request authentication—the authority for a sender’s **first private DM** on a production-configured relay.

### Non-goals (explicit)

These remain out of scope for the first implementation slice and must not appear as public guarantees of this work:

1. Anonymity from the relay operator or traffic-analysis resistance.
2. Mandatory TLS for all relay traffic (only contact-grant submission requires confidential transport — §10).
3. Universal application-layer end-to-end encryption of all DMs (C1 deferred — §11).
4. Protection of grant material from a compromised same-UID local process or compromised relay administrator.
5. Public-room membership privacy or changing deliberate public/gated/unlisted/private room semantics beyond preventing room surfaces from becoming private-DM routes.
6. Treating peer messages as approvals, RPC, or trusted instructions (B098 unchanged).
7. “Ephemeral = no trace.”
8. Multi-relay mesh admission of contact grants in v1 (direct home-relay only — §12).

---

## 2. Chosen model

**Stateful opaque sender-bound contact grant (Candidate B from B269).**

| Rejected alternative | Why |
|---|---|
| Bearer capability (any holder) | Fails sender-specific consent (G3). |
| Stateless derived route (HMAC root) | Not routeable without recipient disclosure or scanning; selective revoke needs state → collapses to B with root-key risk. |

**Summary:**

```text
recipient mints 32 CSPRNG bytes (grant_secret)
recipient binds expected sender Ed25519 public-key fingerprint
recipient stores / has relay store: verifier + mapping + policy
recipient gives grant_secret + relay authority + binding metadata out of band
sender presents grant_secret only over confidential transport in a dedicated contact-delivery request
relay admits only if: signed request + verifier match + exact sender fingerprint + active/unexpired/scope + message_id fresh
ordinary /send, /send_all, /forward cannot bypass private recipients
```

---

## 3. Binary security invariants

Each is a regression property. Implementation tasks cannot satisfy these via docs or UI alone.

| ID | Invariant |
|---|---|
| **G1** | Without a valid current recipient-issued grant for the verified sender, no direct, broadcast, or forwarded path may create a relay inbox row, local broker row, WebSocket/short-queue/observer push, wake/notification, message statistic, archive, or content-bearing dead letter for a **private** recipient. |
| **G2** | An unrelated authenticated peer cannot derive a usable private-recipient destination from peer listing, aliases, public-key lookup, registration JSON, room surfaces, health/stats, errors, logs, or protocol-exposed timing distinctions. (Not operator anonymity.) |
| **G3** | Possession of the contact artefact without the intended sender’s Ed25519 private key is insufficient. Verified request signer fingerprint must equal grant-bound sender fingerprint. |
| **G4** | Recipient can expire, revoke, and rotate future authority without renaming the ordinary alias. Revocation linearisation is explicit (§8). |
| **G5** | Grant, sender, recipient mapping, scope, generation, message_id, and accepted content representation are bound into admission. Exact request replay and a fresh signed request with a duplicate message_id cause at most one delivery. |
| **G6** | Ordinary peers do not learn the recipient alias or reusable grant material. Raw grants never appear in listings, logs, metrics, errors, receipts, dead letters, URLs over HTTP query strings, or room metadata. |
| **G7** | Old, unsupported, malformed, tokenless-development, or downgraded paths cannot silently substitute ordinary alias `/send`. Unsupported contact delivery returns an explicit local error and performs no network fallback. |
| **G8** | A DM contact grant cannot read inboxes, send broadcasts/rooms, join or mutate rooms, access history, manage bindings, invoke admin ops, approve actions, or create implicit reciprocal reachability. |
| **G9** | Principal, device, and recovery semantics are explicit (§4). Replacement keys never silently inherit authority. |

---

## 4. Principal model (G9 decisions)

### 4.1 Recipient principal (v1)

- **Owner of a grant** = the **lease-bound Ed25519 identity public key** currently registered for the recipient’s alias (`identity_pk` on the lease), not the bare alias string alone.
- **Internal mapping** stored with the grant: stable `recipient_identity_pk` fingerprint (SHA-256 of raw 32-byte Ed25519 pk) plus the **current delivery alias** used for inbox routing at admission time.
- If the recipient’s alias re-registers under a **different** identity_pk, **existing grants do not automatically retarget**. The recipient must re-issue or explicitly rebind grants (owner-authenticated management op). This fails closed rather than treating “same alias” as the same person.

### 4.2 Sender principal (v1)

- **Exactly one** Ed25519 public key fingerprint per grant:  
  `sender_fp = SHA-256(raw_ed25519_pk_32)`.
- No multi-device sender sets in v1. A second device of the same person needs its own grant or an explicit re-issue after the recipient verifies the new key.
- Alias changes by the sender do not affect admission; only the request signer’s key fingerprint does.

### 4.3 Multi-device recipient delivery (v1)

- **Single active lease** model: delivery goes to the current live lease for the grant’s mapped delivery alias (same as today’s `send` routing).
- No per-device encrypted fan-out in v1. Multi-device fan-out is a follow-up once a stable multi-device recipient principal exists.
- If the mapped alias has no live lease, admission returns uniform unauthorised (same external shape as other failures) to protect G2.

### 4.4 Recovery / device loss

| Event | Effect |
|---|---|
| Recipient loses device but retains identity key and can re-register same identity_pk | Grants remain valid; delivery follows new lease for mapped alias if identity still matches. |
| Recipient rotates identity key | All grants bound to old `recipient_identity_pk` become inert for management and delivery until re-issued/rebound. |
| Sender rotates identity key | Old grants bound to old `sender_fp` fail G3 until recipient issues a new grant. |
| Relay DB restored from backup | Grants restored as of backup; operators treat as possible reappearance of revoked grants and must re-revoke if needed. |

### 4.5 Reciprocity

- **No implicit reciprocal authority.** Receiving a contact DM does not authorise the recipient to DM the sender without a separately issued return grant (or a later “accepted relationship” feature out of v1 scope).
- v1 does not implement “accepted contact” relationship objects. Only grants.

---

## 5. Grant material and storage

### 5.1 Secret and verifier

```text
grant_secret : 32 bytes from CSPRNG (Os.random / equivalent)
verifier     : SHA-256(grant_secret) as 32 raw bytes
```

**v1 verifier choice: unkeyed SHA-256 of a 256-bit uniform secret.**

Rationale (B261 Q5): offline guessing of a 256-bit secret is not a practical threat; HMAC would add a relay-secret lifecycle (generation, backup, rotation, disaster recovery) without a decisive G-invariant benefit for first slice. Revisit only if secrets are shortened or become online-enumerable.

**Never store `grant_secret` on the relay.** Store only `verifier` and non-secret metadata.

### 5.2 Stored grant record (conceptual)

```text
contact_grants:
  verifier              BLOB PRIMARY KEY   -- SHA-256(secret)
  recipient_identity_fp BLOB NOT NULL      -- SHA-256(recipient ed25519 pk)
  delivery_alias        TEXT NOT NULL      -- current routing alias (mutable only via owner rebind)
  sender_fp             BLOB NOT NULL      -- SHA-256(sender ed25519 pk)
  scope                 TEXT NOT NULL      -- v1: "dm-first-contact" only
  generation            INTEGER NOT NULL  -- recipient-controlled, monotonic per owner policy
  created_at            REAL NOT NULL
  expires_at            REAL NOT NULL      -- relay-authoritative
  revoked_at            REAL NULL          -- null = active
  label                 TEXT NULL          -- optional non-secret owner note (never the secret)
```

```text
contact_grant_message_ids:
  verifier    BLOB NOT NULL
  message_id  TEXT NOT NULL
  accepted_at REAL NOT NULL
  PRIMARY KEY (verifier, message_id)
```

In-memory backends hold equivalent hashtbl state with identical semantics.

### 5.3 Out-of-band contact card (client input, not a URL)

```text
contact-v1:
  protocol: "c2c-contact/1"
  relay_authority: <https URL of recipient home relay>
  grant_secret: <base64url-nopad 32 bytes>
  sender_ed25519_pk: <base64url-nopad 32 bytes expected signer>   # or fingerprint + local binding ceremony
  expires_at: <unix seconds, advisory for UI; relay time is authoritative>
  # optional in v1 for display only — not a routing secret:
  recipient_display_hint: <opaque string chosen by recipient; may be empty>
```

Rules:

- Invitation is **client input** (file/paste/QR of structured text). Not an HTTP GET URL carrying the secret.
- Client transmits `grant_secret` only in the **request body** (or dedicated non-logged credential field) of the contact-delivery request.
- **Never** place `grant_secret` in query strings, path segments, or referrer-prone URLs.
- `recipient_display_hint` must not be the ordinary private alias if that would defeat G2; empty is valid.

### 5.4 Generation and rotation

- **Mint:** new random secret, new verifier row; never retarget an existing verifier to a different sender/recipient/scope.
- **Rotate:** mint independent grant B; revoke or expire grant A.
- **Revoke:** set `revoked_at` (v1: keep row until GC after `expires_at + replay_retention` for uniform denial).

---

## 6. Protocol surface

### 6.1 Dedicated delivery endpoint

```text
POST /contact/v1/deliver
Content-Type: application/json
Authorization: Ed25519 ...   # ordinary peer signed-request auth
```

**Route class:** `Peer_ed25519` on token-configured relays (same outer gate as `/send`).  
**Tokenless development:** refuse contact delivery with explicit `contact_unsupported_in_dev` (or equivalent). **v1: refuse.**

**Request body (exact fields for signature body-hash):**

```json
{
  "protocol": "c2c-contact/1",
  "grant_secret": "<b64url>",
  "message_id": "<client-chosen unique id>",
  "content": "<plaintext or future envelope string>"
}
```

v1 accepts **plaintext content** for reachability (C1 deferred). Content remains untrusted DATA (B098).

**Signed request covers:** method, path, query, body hash, timestamp, nonce (existing `Relay_signed_ops` blob).  
Outer verifier still consumes header nonces into `request_nonces` before signature verification.

### 6.2 Owner management ops (authenticated as recipient)

Owner-authenticated (verified signer’s identity_pk matches grant’s `recipient_identity_fp`), production peer auth:

| Operation | Intent |
|---|---|
| issue | Mint grant bound to `sender_fp`, expiry, optional label; return **grant_secret once** to owner client only |
| list | Return non-secret metadata (label, sender_fp prefix, expiry, revoked, generation) — **never** reusable secret |
| revoke | Set `revoked_at` |
| rotate | Issue new + revoke old in one owner transaction |
| rebind-delivery-alias | Update `delivery_alias` only if signer still matches `recipient_identity_fp` |

Exact HTTP paths may be `/contact/v1/grants` REST-ish; B263 chooses concrete paths consistent with existing auth matrix. CLI wraps the same backend ops.

### 6.3 What is not an endpoint

- Do not overload `/send` with optional grant fields.
- Do not put grant secrets in WebSocket subscribe messages.

---

## 7. Admission algorithm (atomic)

### 7.1 Backend operation (shared contract)

Extend `Relay_backend_contract.RELAY` with a single policy-shaped op (names illustrative):

```text
admit_contact_delivery :
  t ->
  verified_sender_alias:string ->
  verified_sender_identity_pk:string ->  (* raw 32-byte or b64 as backend normalises *)
  grant_secret:string ->
  message_id:string ->
  content:string ->
  [ `Accepted of float   (* ts *)
  | `Duplicate of float
  | `Rejected ]
```

**No distinct external error variants** for unknown/malformed/expired/revoked/wrong-sender/wrong-recipient/wrong-generation — all map to `` `Rejected `` for handlers that emit **one** uniform unauthorised response. Internal non-sensitive counters may differentiate.

### 7.2 Atomic steps (under one `with_lock` for SQLite; one SQL transaction required)

On the already-locked connection:

1. Reject if `protocol` ≠ `c2c-contact/1` or secret length ≠ 32 after decode → `` `Rejected ``.
2. `verifier = SHA-256(grant_secret)`.
3. Lookup grant by verifier. Missing → `` `Rejected ``.
4. If `revoked_at <> null` or `now >= expires_at` → `` `Rejected ``.
5. If `scope` ≠ `dm-first-contact` → `` `Rejected ``.
6. Compute `sender_fp = SHA-256(verified_sender_identity_pk)`; must equal stored `sender_fp` → else `` `Rejected ``.
7. Optionally verify `verified_sender_alias` is still bound to that identity_pk on a live lease (recommended defence in depth).
8. Resolve delivery: current live lease for `delivery_alias` whose identity_pk fingerprint matches `recipient_identity_fp`. Mismatch or absent/dead → `` `Rejected `` (uniform).
9. If `(verifier, message_id)` already accepted → `` `Duplicate ts `` (no second inbox row, no second side effects).
10. Insert inbox row for recipient node/session (same shape as `send`).
11. Insert message_id row; commit.
12. Return `` `Accepted ts ``.

**Handler side effects** (`stats_note_message`, `push_dm`, short-queue, observers) run **only** on `` `Accepted `` — not on `` `Duplicate `` or `` `Rejected `` (stricter than today’s `/send` treating Ok and Duplicate alike for pushes).

### 7.3 Transaction / process posture (B261)

**v1 requirement:**

1. SQLite path: wrap steps 3–11 in `BEGIN IMMEDIATE` … `COMMIT` on the shared `t.db` under the existing non-reentrant mutex (one public lock, lock-free inner worker).
2. Document operational invariant: **one writer process per `c2c_relay.db`** for production (current Railway/single-container topology). Multi-writer is unsupported; if operators violate it, correctness is best-effort via WAL + IMMEDIATE, not a public multi-writer claim.
3. In-memory: single process mutex is sufficient.

Do not nest `with_lock`. Do not open a second connection for admission.

### 7.4 Replay retention / GC

- Retain `contact_grant_message_ids` for each grant until `max(expires_at, revoked_at) + 7 days` (or grant row GC, whichever first).
- GC expired/revoked grants and their message_id rows during existing `gc` or a dedicated sweep under the same lock.
- Request header nonces remain separate (`request_nonces`, 120s window).

---

## 8. Revocation linearisation

- **Linearisation point:** the moment the revoke mutation becomes visible to a subsequent admit transaction on the same database (after commit of revoke under the lock / IMMEDIATE transaction).
- A send whose admit transaction **committed before** that point may deliver once.
- A send whose admit **reads after** revoke sees `revoked_at` and returns `` `Rejected `` with zero side effects.
- No attempt to retract already-delivered inbox rows (they may already be polled). Document as accepted.

---

## 9. Private registration and discovery policy

### 9.1 Default visibility (production after migration)

- New and migrated production registrations are **`private`** by default for peer discovery.
- **Private:** omitted from ordinary `list_peers` / `handle_list` for non-owner peers; `/pubkey/<alias>` does not confirm existence to ordinary peers (uniform not-found); legacy `/send` to private alias without grant path → uniform unauthorised, zero side effects.
- **Public** (optional, explicit opt-in): may appear in peer list and accept ordinary `/send` from authenticated peers. Not the default. Operator/docs must not imply public aliases are “consent-gated.”
- **Owner/admin views:** separate backend parameters or ops; Bearer-admin may list dead/include_dead as today for operators.

### 9.2 Room surfaces

Unchanged intentional room visibility. Room roster aliases must not become private-DM routes: G1 still applies to DM paths even if a room exposes a presentation alias.

### 9.3 Errors

Contact delivery and private legacy send both return the **same** external unauthorised shape (HTTP status + error code stable, e.g. `contact_unauthorised` / generic `unauthorised` — B263 picks one and tests it). No distinction among unknown grant, wrong sender, expired, revoked, private alias, dead recipient.

---

## 10. Transport

- **Production contact delivery and grant issue responses that include `grant_secret` require authenticated TLS** (or an equivalently confidential authenticated channel).  
- Relay must refuse contact delivery when the connection is known cleartext if the server can detect it (`native_tls` / TLS terminator signal). If detection is impossible behind an external TLS terminator, deployment docs require TLS at the terminator and doctor/health warn when misconfigured.
- Request signatures provide integrity/authentication, **not** confidentiality of `grant_secret`.

---

## 11. Confidentiality scope (C1)

**v1 decision: C1 is out of the first slice.**

- Reachability consent (G1–G9) is independent of application-layer E2E.
- Public docs must not imply that contact grants provide content confidentiality.
- A later slice may require a newly bound encrypted envelope on `/contact/v1/deliver` and reject plaintext; that is a separate property and ledger entry.

---

## 12. Cross-relay (v1)

- Contact cards name a **single home relay** (`relay_authority`).
- Client delivers only to that authority. No automatic retry to another relay.
- `/forward` **must not** deliver to private recipients without destination-verifiable original-sender+grant proof. **v1: fail closed** — private recipients never accept forwarded-in mail as first-contact; established public aliases may keep existing forward behaviour if still public.
- Multi-relay attestation is a follow-up.

---

## 13. Compatibility, migration, and downgrade (B266 inputs)

### 13.1 Version

- Protocol string: `c2c-contact/1`.
- Relay advertises support via `/health` optional field `contact_protocol: 1` once implemented (B266).
- Clients that see an unsupported card error locally and **must not** fall back to alias `/send`.

### 13.2 Production migration posture

After approved compatibility boundary:

1. Default new registrations to private.
2. Existing leases become private unless explicitly marked public by migration policy or operator opt-in.
3. Legacy `/send` to private recipients fails closed (no grant bypass).
4. `/send_all` skips private recipients.
5. `/forward` to private recipients fails closed.
6. Durable feature marker / schema presence such that **old binaries that ignore grants** either refuse to run against a post-migration DB or are operationally blocked (B266 specifies marker; fail-open downgrade is forbidden).

### 13.3 Development mode

- Tokenless relay: contact delivery refused; doctor labels mode non-production.
- `C2C_RELAY_ALLOW_UNSIGNED_INBOX` remains orthogonal and must not reintroduce send authority.

### 13.4 Connector

- Local inbound allow/deny remains defence in depth after relay acceptance.
- Default `Inbound_allow` does **not** substantiate G1; do not document it as consent.

---

## 14. Persistence implementation rules (from B261, binding)

1. Extend `RELAY`; implement InMemory + Sqlite.
2. DDL in `sqlite_ddl`; create-time migration with **checked** failures.
3. One process-lifetime `t.db`; public `with_lock` once; lock-free workers; finalize every statement.
4. No nested mutex; no per-op `db_open`.
5. Atomic admit as §7; not separate check-then-send.
6. Preserve B219 lifecycle tests.
7. Do not copy pairing-token burn for atomicity.

---

## 15. Abuse / regression matrix (binary)

| Attack | Verdict | Evidence seam |
|---|---|---|
| Anonymous caller probes private alias list/send/pubkey | Deny; no existence disclosure beyond pre-existing anonymous routes | HTTP auth matrix + list/pubkey/send |
| Authenticated peer `/list` | Private leases absent | both backends + HTTP |
| Authenticated peer `/send` to private alias | No side effects; uniform error | handler + both backends + push spies |
| Authenticated peer `/send_all` | Private recipients excluded | both backends + push spies |
| `/forward` without destination-verifiable grant | No private delivery | forward + admit tests |
| Valid grant, wrong Ed25519 signer | Reject before enqueue | fingerprint tests |
| Matching signer, mutated body | Signature failure | signed-ops tests |
| Unknown/malformed/expired/revoked/wrong-generation grant | Same external response; zero side effects | table-driven endpoint |
| Raw grant in list/log/error/metric/DLQ | Never | redaction + persistence inspection |
| Exact signed request replay | Reject via request nonce | existing nonce + contact integration |
| Fresh signed request, duplicate message_id | At most one delivery | atomic idempotency + restart |
| Revoke races send | Matches §8 linearisation | concurrent tests |
| Rotate A while B exists | Independent | isolation tests |
| Sender key rotates | Old grant inert | key-change tests |
| Recipient identity rotates | Old grants inert until rebind/reissue | identity tests |
| Old client imports card | Explicit unsupported; no `/send` fallback | CLI/connector |
| Old relay receives contact endpoint | Explicit unsupported; no alias retry | client HTTP |
| Grant used on room/admin/inbox route | Reject / impossible | route-scope matrix |
| Public/gated room shows member alias | Alias still not usable private DM route | room + private-send |
| Cross-relay attempt | Reject (v1) | forward tests |
| Rejected malicious content | No inbox/push/stats/archive/content DLQ | side-effect assertions |
| Accepted content to agent | Untrusted DATA; no approval authority | B098 suites |
| Tokenless dev contact deliver | Refused | auth/dev matrix |
| Cleartext production contact deliver | Refused or doctor-failed deploy | transport tests / deploy docs |

---

## 16. Acceptance properties for implementation tasks

### B263

- Schema + both backends + owner management ops.
- Issue returns secret once; list never prints reusable secret by default.
- Atomic admit + message_id + inbox under lock/transaction.
- Restart, concurrency, expiry, revoke, redaction, malformed records.
- Migration checked; never default-allow on failure.

### B264

- Private default peer list and pubkey behaviour.
- Owner/admin explicit views.
- Room side channels do not yield private DM routes.
- Error uniformity where required.

### B265

- `/contact/v1/deliver` works for authorised sender.
- `/send`, `/send_all`, `/forward` closed for private recipients.
- Side effects only on `` `Accepted ``.
- Connector not the security boundary.

### B266

- Fail-closed upgrade; durable marker; doctor/health; CLI lifecycle without secret leaks; noisy dev bypasses.

### B267

- Full matrix §15; dogfood isolated local relay; independent review; ledger update; B219 lifecycle still green.

---

## 17. Public documentation constraints (for B260)

Until B259/B267 prove implementation, do **not** claim consent-gated reachability.

After proof, allowed shape:

1. Private recipients are not listed as usable DM routes to ordinary authenticated peers.
2. First-contact delivery requires a recipient-issued grant bound to the verified sender.
3. Leaking the grant alone does not authorise a different Ed25519 identity; compromise of the intended sender’s private key does until revocation.
4. Relay operator still sees routing metadata; TLS and E2E remain separate conditional properties.
5. Peer content remains DATA (B098).

---

## 18. Open items deliberately frozen as “out of v1”

| Item | v1 freeze |
|---|---|
| Multi-device sender set | One key per grant |
| Multi-device recipient fan-out | Single lease delivery |
| Reciprocal accepted-contact object | No; independent return grants only |
| Cross-relay grant attestation | Fail closed; home relay only |
| Strict E2E contact envelope (C1) | Deferred |
| HMAC verifier with relay key | Unkeyed SHA-256 of 256-bit secret |
| Public aliases | Explicit opt-in only; not default |
| Tokenless contact delivery | Refused |

Any change to these freezes requires a new design revision (B262b) before implementation drifts.

---

## 19. Requirements checklist (B262 acceptance)

| Requirement | Section |
|---|---|
| Threat actors, trust boundaries | B269 retained; G1–G9 + non-goals §1, §3 |
| High-entropy recipient-issued capability; alias alone not enough | §2, §5 |
| Issuance/disclosure, sender/recipient binding, expiry, revoke, rotate, replay, storage, redaction | §4–§8 |
| What leaks if grant leaks | §2, §5.1, G3: secret alone insufficient without sender key |
| Authenticated peer discovery without global private enumeration; rooms separate | §9 |
| Production fail-closed, dev bypasses, version, upgrade, downgrade | §13 |
| HTTP/WS/connector parity; alias/host/Ed25519/X25519 interaction | §6–§7, §10–§12, C1 deferred for X25519 envelope |
| Binary abuse matrix | §15 |
| Post-B219 persistence model | §7.3, §14 |

---

## SUMMARY

- **Model:** stateful 32-byte opaque grant, sender-bound by Ed25519 fingerprint, verifier = SHA-256(secret), dedicated `POST /contact/v1/deliver`.
- **Principals:** recipient and sender are key fingerprints; alias is routing only; key rotation never silent; no implicit reciprocity.
- **Atomic admit:** one backend op + SQL IMMEDIATE transaction under existing single-lock discipline; side effects only on first `Accepted`.
- **Discovery:** production private-by-default; close `/send`, `/send_all`, `/forward` bypasses; uniform unauthorised.
- **Transport:** TLS required for grant submission/issue of secrets; C1 E2E deferred.
- **Dev/migration:** fail closed; tokenless refuses contact; no alias fallback; durable migration marker.
- **Implements G1–G9** as binary regression properties for B263–B267.
