# Independent security review — consent-gated private reachability

**Date:** 2026-07-22  
**Scope:** `feature/b264-private-discovery` (worktree), base `18f9cc01`…`HEAD`  
**Invariant:** (1) private recipients not usable ordinary DM routes; (2) no delivery side effects without recipient-issued, sender-bound grant.  
**Method:** static code audit of handlers/backends + suite inventory + dogfood evidence. Parallel subagent reviews were launched; this report is the coordinator synthesis from primary symbols.

## Verdict

**PASS-WITH-NOTES** — no open **BLOCKER** on the G1/G2 delivery/discovery invariant in the reviewed new binary. One **MAJOR** residual is **operational downgrade** (pre-B264 binary + migrated DB). Product/ops gaps for public opt-in CLI and TLS-at-handler are **MAJOR/MINOR** depending on deploy discipline.

---

## Path gate table

| Path | Gated for private? | Evidence | Residual |
|---|---|---|---|
| `R.send` / `handle_send` | Yes | `is_public_recip` / `discovery_visibility` → `` `Error unknown_alias `` without content DLQ (InMemory private branch) | Legacy `/send` still push on Ok/Duplicate for **public** only |
| `R.send_all` / `handle_send_all` | Yes | skips non-Public; Sqlite SQL filters `discovery_visibility = 'public'` | — |
| `handle_forward` → `R.send` | Yes | reuses `R.send` private gate | Source-relay auth ≠ grant; intended v1 fail-closed |
| `admit_contact_delivery` / `handle_contact_deliver` | Yes | verifier, sender_fp, expiry, revoke, mid idempotency; tokenless refuse | Accepted: stats only, **no** `push_dm` (poll path) |
| `list_peers` / ordinary `handle_list` | Yes | Public only | — |
| `list_peers_admin` / `include_dead` | Admin Bearer | `classify_route` admin when `include_dead` | Operator intentional |
| `handle_pubkey` | Yes | `peer_identity_pk_of` etc. | Internal `identity_pk_of` still for owner/routing |
| Rooms | Not DM authority | room roster tests; private DM still needs grant | Public room presentation aliases remain |
| Connector | Not boundary | post-accept filter | Documented |
| Register default | Private | INSERT `'private'` / hashtbl Private | No production CLI to set Public |

---

## Findings

### M1 — MAJOR: old binary on migrated DB reopens global reachability

**Where:** operational; new code stamps `schema_version=2` + `relay_features` in `SqliteRelay.create` (`ocaml/relay.ml` B266 block) but pre-B264 binaries never read that stamp.  
**Why:** Old `list_peers`/`send` ignore `discovery_visibility` and grants → G1/G2 fail if operators roll back the binary while keeping the DB.  
**Fix:** Deploy policy: refuse start of binary without contact/private support against stamped DBs (wrapper/supervisor/health check); document in runbook; optional forward-only migration note. Not fixable inside old binary.

### M2 — MAJOR (product/ops): no production surface to opt-in Public discovery

**Where:** `set_peer_discovery_visibility` exists on backends only; no `c2c relay` HTTP/CLI subcommand.  
**Why:** Does **not** weaken private default (safer). Blocks intentional public aliases and lifecycle tests’ production analogue. B262 allows public opt-in.  
**Fix:** Add owner-authenticated `c2c relay discovery set --alias X --visibility public|private` (and/or HTTP) with tests.

### M3 — MINOR: contact Accepted does not wake via WS/short-queue

**Where:** `handle_contact_deliver` `` `Accepted `` → `stats_note_message` only; no `Relay_ws_server.push_dm`.  
**Why:** Inbox row is created (G1 satisfied for durable delivery); idle clients relying on WS-only may not wake until poll/connector.  
**Fix:** After admit, resolve delivery alias and call same push path as `handle_send` Ok branch (still B098 DATA).

### M4 — MINOR: TLS not enforced inside `handle_contact_deliver`

**Where:** B262 §10; doctor `check_transport_security` only.  
**Why:** Grant secret in JSON body is visible on cleartext hops; signatures ≠ confidentiality.  
**Fix:** When `native_tls=false` and `X-Forwarded-Proto` not https, refuse contact deliver in prod; keep doctor.

### N1 — NOTE: InMemory unknown still content-DLQs; private does not

External error code matches; server-side DLQ differs. Not a peer oracle. Sqlite already no content DLQ on unknown.

### N2 — NOTE: dual-backend send idempotency still asymmetric for public legacy

Contact path has own mid table; public `/send` Duplicate still triggers push (pre-existing). Out of G1 private reject scope.

---

## G1–G9 snapshot

| ID | Status in reviewed binary |
|---|---|
| G1 | **Met** for private: send/send_all/forward/contact reject without grant; no content DLQ on private reject |
| G2 | **Met** ordinary list/pubkey; admin separate |
| G3 | **Met** sender_fp bind; leaked secret tests |
| G4 | **Met** expire/revoke/rotate + concurrent tests |
| G5 | **Met** mid + request nonces; Duplicate no second row |
| G6 | **Met** list redaction; issue secret once |
| G7 | **Partial ops** — tokenless refuse + protocol downgrade OK; **old binary rollback** is M1 |
| G8 | **Met** DM scope; rooms ≠ DM |
| G9 | **Met** at v1 freeze (key fp principals; no silent key inheritance) |

---

## Accepted non-goals (not findings)

- Relay operator visibility / no anonymity  
- No universal TLS or E2E (C1 deferred)  
- Same-UID host compromise  
- B098 DATA framing ≠ prompt-injection immunity  
- Ephemeral ≠ no trace  

---

## Evidence already green (do not re-claim without rebuild)

- Suites: contact_grants, private_discovery, contact_delivery_handlers, private_reachability_matrix, private_migration  
- Dogfood: `.collab/evidence/B267/dogfood-isolated-local/`  
- Ledgers: `2026-07-21-security-page-claim-ledger.md`, B267 matrix ledger  
- Page: `docs/security/index.md`

---

## Required before “all blockers closed”

1. **Accept M1 as deploy constraint** with written runbook (or implement supervisor refuse).  
2. **Track M2** as follow-up feature (public opt-in CLI) — not a private-mode bypass.  
3. Optional harden M3/M4 before calling wake/TLS production-complete.

**Coordinator disposition:** For B267 “independent review / no unresolved blocker-major on invariant”: **PASS-WITH-NOTES** if M1 is recorded as operational acceptance criterion and M2–M4 filed as non-blocking follow-ups. **FAIL** only if deploy cannot enforce “no old binary on stamped DB.”
