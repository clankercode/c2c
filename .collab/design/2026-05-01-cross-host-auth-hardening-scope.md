# Cross-Host Mesh Auth Hardening — Design Scope
**Author**: galaxy-coder
**Date**: 2026-05-01
**Status**: Draft — scoping for next-phase work

---

## 1. Current Auth Surface

### Two-Tier Architecture

**Tier 1 — Admin routes** (`/gc`, `/dead_letter`, `/admin/unbind`, `/list?include_dead`):
- Require **Bearer token** (`C2C_RELAY_TOKEN` / `--token` flag)
- Prod mode: token required; dev mode: open
- Single relay-global secret — no per-alias granularity

**Tier 2 — Peer routes** (`/register`, `/send`, `/poll_inbox`, `/heartbeat`, `/join_room`, `/leave_room`, `/send_room`):
- Require **Ed25519 per-request signature** (`Authorization: Ed25519 alias=...,ts=...,nonce=...,sig=...`)
- Signature covers a **canonical_request_blob**: `method + path + query + body + ts + nonce`
- **30-second ts window** + **2-minute nonce TTL** against replay
- Prod mode: Ed25519 required; dev mode: unsigned allowed
- Envelope-level Ed25519 (v2): pins sender's Ed25519 key per-recipient in `relay_e2e` envelopes

### TOFU Pin Store

Two conceptually separate stores — **must not conflate**:

| Store | Owner | Purpose | Rotation |
|---|---|---|---|
| `Trust_pin` (`peer_review.ml`) | Peer-PASS | Artifact identity | Operator-attested `pin_rotate` |
| `known_keys_ed25519` (`c2c_broker.ml`) | Relay-e2e | Per-recipient TOFU | Hard reject on mismatch |

On **first contact**: `relay_e2e_pin_first_seen` logged; pin written to `known_keys_ed25519`.

On **subsequent contact**: key matches → accept; mismatch → `relay_e2e_pin_mismatch` CRIT logged + hard reject.

**No auto-rotation.** Mismatch requires operator-run `c2c relay-pins rotate --alias <a>`.

### Envelope Versions

| Version | Canonical Blob Fields | TOFU |
|---|---|---|
| v1 | `enc`, `from`, `recipients`, `room`, `to`, `ts` | None |
| v2 | v1 + `from_x25519` + `from_ed25519` + `envelope_version` | Ed25519 key pinned per first-contact |

CRIT-1 (#438): `canonical_json` extended to cover `from_x25519` in v2 (prevents MITM swap of X25519 key). Fixed.

CRIT-2 (#438): `from_ed25519` added to envelope + TOFU pin store. Fixed.

**Downgrade attack (Slice B-min-version)**: MITM rewrites `envelope_version: 2 → 1` on wire to bypass CRIT-1/2 fixes. Per-peer `min_observed_envelope_version` pin set after first v2 contact. Status: designed, implementation pending.

### What This Buys Us Today

- Peer impersonation on the wire (MITM swaps sender key) — **blocked** by Ed25519 signature on canonical request blob
- MITM swapping `from_x25519` in an envelope — **blocked** by v2 canonical blob including that field
- MITM swapping sender's Ed25519 key across sessions — **blocked** by TOFU pin store
- Replay within 30s window — **blocked** by ts + nonce TTL
- Replay across reorgs / old nonce reuse — **blocked** by 2-minute nonce TTL

---

## 2. Threat Model

### Trustable (under current implementation)

| Threat | Mitigation |
|---|---|
| Wire-level MITM (session hijack) | Ed25519 per-request signature |
| Envelope sender spoofing (x25519 swap) | v2 canonical blob includes `from_x25519` |
| Envelope sender spoofing (ed25519 swap per session) | TOFU pin on `known_keys_ed25519` |
| Replay within 30s | ts + nonce TTL |
| Peer-PASS artifact impersonation | `Trust_pin` + `pin_rotate` operator attestation |

### Not Trustable — Known Gaps

| Threat | Severity | Status |
|---|---|---|
| **Relay operator can read all messages** | Design — not a bug | Known; v2 capability tokens deferred |
| **Bearer token is relay-global** — any token holder can poll any session | MED (v1) | Design gap; v2 Ed25519 session tokens deferred |
| **Alias registration has no cryptographic proof of alias ownership** | MED | Partial mitigation via M1-M4 permission binding; relay-level alias binding still needed |
| **Rotate-pin audit log missing** — only stdout/stderr | MED | Filed #55 |
| **Pin store save has no flock** — cross-process lost-update race | MED | Filed #54 |
| **Size-unbounded JSON parse** — 1GB artifact DoS | MED | Filed #56 |
| **Path-traversal defence implicit** — future callers could reopen | MED | Filed #57 |
| **EACCES on identity persist** — fresh-key-per-restart breaks TOFU | CRIT | Fixed at `4f068a2d` — graceful degrade to in-memory |
| **Downgrade attack** (v2→v1 envelope rewrite on wire) | HIGH | Slice B-min-version pending |
| **DM spoofing** (`from_alias` body field not verified) | HIGH | Fixed at `13222e0` |
| **Room operations broken in prod mode** (body Ed25519 proof not reaching handler) | HIGH | Fixed at `fe8251c` |

### What Is NOT in Scope

Per #438 design scope:
- **Anti-DDoS / rate limits** — already tracked separately in #438; not a crypto/auth gap
- **Broker-level availability** — separate concern from auth hardening
- **OCaml-to-Python relay connector signed registration** — Python connector is deprecated; OCaml CLI has signed registration

---

## 3. Concrete Next-Step Slices, Ranked by Leverage

### Slice A — Downgrade Attack Defence (B-min-version)
**Implements**: per-peer `min_observed_envelope_version` pin — once a peer observed at v2, refuse v1 envelopes from them.

**Files**: `relay_e2e.ml`, `c2c_broker.ml`
**LoC**: ~80
**Failure mode**: Legitimate peer that never upgraded to v2 gets locked out after first v2 contact. Mitigated: ts window + explicit error message. Fallback: operator can clear pin via `c2c relay-pins delete`.

**Prerequisite**: Already designed at `6d59329f` (`.collab/design/2026-04-29T17-00-00Z-stanza-slate-relay-crypto-slice-b-min-version.md`). Ready to implement.

**Leverage**: CRITICAL — closes the only active MITM vector that bypasses existing Ed25519 protections.

---

### Slice B — Pin-Store flock + fsync (Cross-Process Race)
**Implements**: `flock` on `<broker>/peer-pass-trust.json.lock` + `fsync` before rename in `Trust_pin.save` and `known_keys_ed25519` persist. Also adds structured `peer_pass_pin_rotate` audit log entry.

**Files**: `peer_review.ml`, `c2c_broker.ml`
**LoC**: ~60
**Failure mode**: Two concurrent processes (broker + CLI in another worktree) racing `load → mutate → save` can silently lose one update. Attacker wins by racing their own pin-write against legitimate first-seen pin.

**Leverage**: MED — requires local access (already on same host as broker). Still worth shipping since the race is realistic in multi-agent environments.

---

### Slice C — Operator Surfaces: `c2c relay-pins list` + `delete`
**Implements**: `c2c relay-pins list` (show all pins with key fingerprints + first-seen + min-version) and `c2c relay-pins delete --alias <a>` (remove a pin to allow re-TOFU on next contact).

**Files**: `cli/c2c_relay_pins.ml` (new), `peer_review.ml`, `c2c_broker.ml`
**LoC**: ~120
**Failure mode**: Operator accidentally deletes a pin for a live peer → that peer's next message creates a new pin (first-seen event) → legitimate peer must re-verify. Non-destructive; recoverable.

**Leverage**: HIGH — absence of these tools forces operators to manually edit JSON files, which is error-prone and has caused incidents.

---

### Slice D — Structured Audit Log for `pin_rotate`
**Implements**: Structured `peer_pass_pin_rotate` broker.log entry inside `Peer_review.pin_rotate` (not just stdout/stderr). Format: `{ts, alias, operator, old_pin_fingerprint, new_pin_fingerprint, reason}`.

**Files**: `peer_review.ml`, `c2c_broker.ml`
**LoC**: ~30
**Failure mode**: Low — purely additive logging. No new attack surface.

**Leverage**: MED — without this, rotation events are invisible to structured log analysis and post-incident forensics.

---

### Slice E — Signed Registration Receipt
**Implements**: On `/register`, relay signs a registration receipt containing `(alias, identity_pk, ts, relay_pubkey)` and returns it to the client. Client stores it. On subsequent `/send`, client presents the receipt as additional proof of alias ownership.

**Files**: `relay.ml`, `relay_identity.ml`, `c2c_broker.ml`
**LoC**: ~200
**Failure mode**: Relay private key compromise → attacker can forge receipts for any alias. Mitigated: separate from peer Ed25519 — relay sig only proves "relay issued this receipt", not "alias owns this key". Two-layer: receipt + per-message Ed25519 sig still required.

**Leverage**: HIGH — closes the relay-level alias binding gap (alias registration has no cryptographic proof of alias ownership today). Reduces social engineering surface on relay operator.

---

### Slice F — JSON Parse Size Cap
**Implements**: `Yojson.Safe.from_file` replaced with `stat` first, refuse files > 64KB. Applied to all JSON load paths in broker.

**Files**: `c2c_broker.ml`, `relay_identity.ml`, `peer_review.ml`
**LoC**: ~40
**Failure mode**: Legitimate large artifact (shouldn't exist in practice; JSON artifacts are tiny). Cap is a hard limit — if breached, parse fails. Recovery: operator must trim artifact file.

**Leverage**: MED — DoS vector requires pre-existing file write on broker host; attacker already has host access in this threat model.

---

### Slice G — Ed25519 Session-Scoped Capability Token (v2 Remote Inbox Auth)
**Implements**: Replace relay-global Bearer token for remote inbox polling with a per-session Ed25519 capability token. Token = signed blob `(session_id, alias, expires_at, permitted_paths)` by relay's Ed25519 key.

**Files**: `relay.ml`, `relay_identity.ml`, `c2c_broker.ml`, `c2c_relay_connector.ml`
**LoC**: ~300
**Failure mode**: Relay private key compromise → attacker forges capability tokens for any session. Mitigated: separate from peer Ed25519. In v1 threat model, relay operator is already trusted to read all messages.

**Leverage**: LOW for current single-operator swarm (Bearer token is sufficient); HIGH when multi-operator support is needed.

---

## 4. What's NOT in Scope

| Topic | Reason |
|---|---|
| Anti-DDoS / rate limits | Already tracked in #438; separate from auth |
| Broker availability HA | Separate concern |
| Python relay connector signed registration | Python deprecated; OCaml CLI canonical |
| Mutual TLS (mTLS) between relay and peers | Would require CA infrastructure; current threat model assumes wire is observable but not injectable by relay operator |
| Post-quantum key exchange | Future work; not applicable to current Ed25519+X25519 stack |
| Hardware security modules (HSM) for relay identity key | Infrastructure dependency; defer until relay runs on dedicated hardware |

---

## Cross-References

- `.collab/runbooks/worktree-discipline-for-subagents.md` Pattern 23 (this doc is a design doc, not a runbook)
- `.collab/findings/` — auth/relay/TOFU findings from 2026-04-29 audit burst
- `.collab/design/2026-04-29-relay-crypto-crit-fix-plan-cairn.md` — CRIT-1 + CRIT-2 master plan
- `.collab/design/2026-04-29T17-45-00Z-slate-stanza-relay-crypto-crit2-tofu-design.md` — CRIT-2 TOFU design
- `.collab/design/2026-04-29T17-00-00Z-stanza-slate-relay-crypto-slice-b-min-version.md` — B-min-version design (Slice A above)
- `.collab/runbooks/broker-log-events.md` — audit log event catalog
- `.collab/runbooks/peer-pass-audit-log.md` — peer-PASS pin_rotate audit + operator rotation interface
- `ocaml/relay.ml:2680` — `auth_decision` function
- `ocaml/relay_e2e.ml:259` — `verify_envelope_sig`
- `ocaml/c2c_broker.ml:586` — `known_keys_ed25519` TOFU pin store
- `ocaml/peer_review.ml:405` — `Trust_pin.save`
