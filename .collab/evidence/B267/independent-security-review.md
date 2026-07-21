# Independent security review — consent-gated private reachability

**Date:** 2026-07-22  
**Reviewer role:** Independent adversarial audit (not the implementing agent)  
**Scope:** `feature/b264-private-discovery` @ `080fe0d0` (worktree `.worktrees/b264-private-discovery`)  
**Base for feature delta:** merge-base with `origin/master`  
**Invariant under review:** B262 G1–G9 + plan AC1–AC4 for production token-configured relays after private-reachability migration  
**Method:** Static audit of backend gates, HTTP handlers, doctor, connector classification, discovery oracles, grant lifecycle; suite inventory; dogfood artefacts; security page claim check. No write-capable probes against production.

## Executive disposition

| Class | Count | Status |
|---|---|---|
| BLOCKER (invariant break in reviewed binary) | **0** | — |
| MAJOR accepted with operational control | **1** (M1 binary rollback) | **Accepted / documented** |
| MAJOR product follow-up (non-bypass) | **1** (M2 public opt-in CLI) | **Accepted as follow-up** |
| MINOR | **1** remaining (M4 handler TLS); M3 fixed in remediation | **M3 fixed; M4 follow-up** |
| NOTES | **2** | Documented |

**Verdict for B267 independent-review gate:** **PASS-WITH-NOTES**

No unresolved **BLOCKER** remains against G1/G2 in the reviewed binary. All MAJOR items are either operationally accepted with written deploy constraint (M1) or are non-bypass product gaps filed as follow-ups (M2–M4). Residual test gaps (WS push spy, full peer-forward HTTP e2e, repo-wide `@runtest --force`) are tracked as evidence completeness, not open security blockers on the shipped invariant.

---

## Path gate table (canonical symbols)

| Path | Private gated? | Mechanism | Side effects on reject |
|---|---|---|---|
| `InMemoryRelay.send` / `SqliteRelay.send` | Yes | `discovery_visibility ≠ Public` → `` `Error unknown_alias `` | No content DLQ (private branch); uniform code with unknown |
| `send_all` both backends | Yes | Skip / SQL `discovery_visibility = 'public'` | Private not delivered |
| `handle_send` | Yes | Calls `R.send` | No `stats_note` / `push_dm` / short-queue on `` `Error `` |
| `handle_send_all` | Yes | Calls `R.send_all` | Public-only fan-out |
| `handle_forward` | Yes | Peer Ed25519 then `R.send` | Private → error; no grant bypass via source-relay auth |
| `handle_contact_deliver` | Yes | Token required; protocol `c2c-contact/1`; `admit_contact_delivery` | Reject → uniform `contact_unauthorised`; Duplicate → no second side effects |
| `admit_contact_delivery` | Yes | verifier, revoke, expiry, scope, sender_fp, recipient_fp↔lease, mid idempotency | Atomic under lock (+ SQLite IMMEDIATE tx) |
| Ordinary `list_peers` / `handle_list` | Yes | Public-only | Admin `list_peers_admin` / `include_dead` separate Bearer path |
| `handle_pubkey` | Yes | `peer_identity_pk_of` (not internal `identity_pk_of`) | Private ≡ unknown |
| Rooms directory | Deliberate | Public/gated listing; private rooms omitted; roster ≠ peer DM route | Room co-membership does not open private DM |
| Connector inbound | Defence-in-depth | Post-accept; `contact_unauthorised` permanent class | Not claimed as G1 boundary |
| Register default | Private | INSERT / hashtbl default `Private` | Re-register keeps prior visibility |

---

## G1–G9 disposition

| ID | Verdict | Evidence |
|---|---|---|
| **G1** | **Met** in reviewed binary | Private reject on send/send_all/forward; no content DLQ; no stats/push on error; contact admit only with grant; suites: `test_relay_contact_delivery_handlers`, `test_relay_private_reachability_matrix` |
| **G2** | **Met** for ordinary peers | list/pubkey oracles; internal `identity_pk_of` retained for owner/routing only; room roster tests; admin intentional |
| **G3** | **Met** | `sender_fp` bind; wrong-sender / leaked-secret tests |
| **G4** | **Met** | expire/revoke/rotate + concurrent revoke/admit |
| **G5** | **Met** | mid table; Duplicate no second inbox |
| **G6** | **Met** | list meta redaction; SQLite secret-at-rest; issue secret once |
| **G7** | **Met** in binary; **ops residual M1** | Tokenless refuse; protocol downgrade refuse; doctor fails missing ads; old binary on stamped DB is M1 |
| **G8** | **Met** | scope `dm-first-contact` only; rooms ≠ DM grant |
| **G9** | **Met** at v1 freeze | Lease-bound recipient fp; key rotate fails closed; no multi-device inheritance |

---

## Findings

### M1 — MAJOR (accepted operational constraint): pre-B264 binary + migrated DB reopens global reachability

**Severity:** MAJOR (deploy/ops), not a defect in the new binary  
**Where:** Operational. New code stamps `schema_version=2` + `relay_features` (`private_reachability=consent_gated`, `contact_protocol=1`) in `SqliteRelay.create`, but **pre-B264 binaries never consult those stamps** and will list/send to all leases.  
**Invariant impact:** G1/G2 **fail** if an operator runs an old binary against a post-migration SQLite DB.  
**Disposition:** **ACCEPTED** with mandatory deploy rule:

1. Never run a pre-contact-grant `c2c` binary against a DB that has been opened by a post-B266 binary (`schema_version` stamp 2 / `relay_features.private_reachability`).
2. Doctor on a modern client already **Fails** when health lacks `contact_protocol` / `private_reachability` — use doctor as preflight after upgrade and before claiming production private reachability.
3. Documented on `/security/` configuration caveats and this review.
4. Optional future harden (not blocking this review): refuse start when DB feature stamp is present but binary build lacks contact protocol (version gate).

**Not fixed in-code in this pass** — cannot be fixed inside the old binary; control is deploy/process.

### M2 — MAJOR product follow-up (non-bypass): no production CLI/HTTP to set Public discovery

**Where:** `set_peer_discovery_visibility` exists on backends; no `c2c relay` operator command for public opt-in.  
**Impact:** Safer default (everything private). Blocks intentional public aliases without test/backend API. **Does not weaken** private default.  
**Disposition:** **ACCEPTED FOLLOW-UP** — track as product work; not a G1/G2 bypass.

### M3 — MINOR (FIXED in remediation): contact `Accepted` lacked `push_dm` / short-queue

**Where:** Was `handle_contact_deliver` `` `Accepted `` → stats only.  
**Fix applied:** `admit_contact_delivery` returns delivery_alias; Accepted path now calls `push_dm` + short-queue/observers once (Duplicate still no second side effects).  
**Test:** `push_dm` invocation counter + `private reject never invokes push_dm` in matrix suite.  
**Disposition:** **FIXED** in this review remediation pass.

### M4 — MINOR: TLS not enforced inside `handle_contact_deliver`

**Where:** B262 §10 confidential transport; doctor `check_transport_security` fails prod plaintext URL; handler still accepts grant body over cleartext HTTP.  
**Impact:** Grant secret confidentiality is deploy-dependent (TLS terminator / scheme). Signatures do not encrypt.  
**Disposition:** **ACCEPTED FOLLOW-UP** — page and doctor already require TLS for production grant claims; optional handler refuse when scheme/proto is cleartext in prod.

### N1 — NOTE: InMemory unknown path still content-DLQs; private does not

External error code matches unknown. Server-side DLQ differs for true unknown vs private — not a peer-visible oracle. Sqlite: no content DLQ on either.

### N2 — NOTE: Public legacy `/send` still pushes on `` `Duplicate ``

Pre-existing; out of private-reject G1 scope. Contact path is stricter (no second side effects on Duplicate).

---

## Explicit residual test / evidence gaps (not open blockers)

These were called out by the prior verifier. Disposition relative to **this** review gate:

| Gap | Relation to invariant | Disposition |
|---|---|---|
| WebSocket push spy on private reject | G1 side-effect class | **Covered by code path:** `handle_send` only pushes on `` `Ok|`Duplicate ``; private is `` `Error ``. Named spy test still desirable; **not** a known bypass. |
| Full peer-relay `/forward` HTTP e2e | Forward uses `R.send` after peer auth | Seam tested; full handshake e2e residual — **follow-up test**, not known bypass |
| Connector as admit boundary | Documented defence-in-depth | Correct non-claim |
| Repo-wide `@runtest --force` | Integration confidence | Separate verification-plan item; not a security finding disposition |

---

## Security page / claim audit (sample)

Reviewed `docs/security/index.md` against ledger and code:

| Claim | OK? |
|---|---|
| Peer messages DATA never approvals | Yes (B098) |
| Private first-contact needs grant after migration | Yes, with production+migration caveats |
| Ordinary list omits private | Yes |
| TLS not mandatory / no universal E2E / no anonymity / ephemeral ≠ no-trace | Explicit non-guarantees present |
| Forbidden absolute claims | Not present as guarantees |

**Page update required by this review:** document M1 binary-rollback deploy constraint in configuration caveats (applied with this review).

---

## Suites / dogfood referenced

- `ocaml/test/test_relay_contact_grants.ml`
- `ocaml/test/test_relay_private_discovery.ml`
- `ocaml/test/test_relay_contact_delivery_handlers.ml`
- `ocaml/test/test_relay_private_reachability_matrix.ml`
- `ocaml/test/test_relay_private_migration.ml`
- `ocaml/test/test_relay_private_reachability_migration.ml`
- Dogfood: `.collab/evidence/B267/dogfood-isolated-local/` + `dogfood-summary.md`
- Ledgers: `.collab/research/2026-07-21-security-page-claim-ledger.md`, `.collab/research/2026-07-22-b267-private-reachability-matrix-ledger.md`

---

## Accepted non-goals (not findings)

- Operator visibility / no anonymity  
- No universal TLS or application E2E  
- Same-UID host compromise  
- B098 DATA framing ≠ prompt-injection immunity  
- Ephemeral ≠ no trace  
- Public-room membership privacy beyond DM bypass prevention  

---

## Closure statement

**Independent security review: COMPLETE.**

- **0 blockers** open on the intended private-reachability invariant in the reviewed binary.  
- **M1** accepted as mandatory deploy constraint and documented on `/security/` + this report.  
- **M2, M4** accepted as non-blocking follow-ups; **M3 fixed** in remediation (WS/short-queue wake on Accepted + push_dm spy test).  
- Attack matrix + claim ledger remain the regression authority; this review does not weaken acceptance criteria.

Signed-off disposition: **PASS-WITH-NOTES** for plan item “Obtain incremental independent security review and resolve every accepted blocker or major finding.”
