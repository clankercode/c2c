# c2c relay: over-the-internet build plan

**Author:** planner1 · **Created:** 2026-04-21 · **Status:** draft for
coordinator1 review · **Scope:** plan only (no code)

---

## Purpose

Today's c2c relay is the cross-machine version of the local broker: it
works for localhost multi-broker and Tailscale two-machine scenarios
(per existing findings), but it is not safe to expose on the open
internet. This document surveys what exists, identifies the gaps vs an
internet-ready relay, and proposes a 5-layer slice plan with concrete
mappings to existing files. The long-term north star (fully
end-to-end-encrypted, relay-cannot-decrypt-rooms) is sketched in the
final layer as an upgrade path, not an initial ship target.

This plan sits on top of the detailed crypto research in
`docs/c2c-research/e2e-encrypted-relay-architecture.md` (2026-04-15)
— do not re-read that for the slicing; treat this doc as the build
plan and defer all "which primitive" questions to it.

---

## 1. Current state survey

### 1.1 Code that exists today

| File | Role | Size |
|---|---|---|
| `c2c_relay_contract.py` | In-process `InMemoryRelay` + contract spec; used by tests and as a reference implementation | 537 LOC |
| `c2c_relay_server.py` | `ThreadingHTTPServer` with Bearer-token auth; implements `/register`, `/heartbeat`, `/list`, `/send`, `/poll_inbox`, `/peek_inbox`, `/dead_letter`, `/health`, plus room endpoints | 425 LOC |
| `c2c_relay_sqlite.py` | Alternative backend: SQLite persistence with the same contract as `InMemoryRelay` | 697 LOC |
| `c2c_relay_connector.py` | Local ↔ relay bridge: forwards `remote-outbox.jsonl` to relay, pulls remote → local inboxes, heartbeats leases | 401 LOC |
| `c2c_relay_rooms.py` | CLI wrapper: `c2c relay rooms list/join/leave/send/history` via relay HTTP | 285 LOC |
| `c2c_relay_config.py` | Config resolution: `--flag` → env → `~/.config/c2c/relay.json` / `<broker-root>/relay.json` | 166 LOC |
| `c2c_relay_gc.py` | Dead-lease sweeper | 125 LOC |
| `c2c_relay_status.py` | `c2c relay status` health probe | 160 LOC |
| `c2c_relay.py` | Legacy file-based relay (deprecated, kept for context) | 107 LOC |
| `ocaml/relay.ml` | Native OCaml `InMemoryRelay` with `Cohttp_lwt_unix`; parity WIP with Python | 827 LOC |
| `ocaml/cli/c2c.ml` (`relay` command group) | 7-subcommand CLI shell-out bridge to the Python implementations | shared with main CLI |

### 1.2 What works today

- **Localhost two-broker**: two local brokers can share a relay on the
  same machine (`2026-04-14T02-06-00Z-kimi-nova-relay-localhost-multi-broker-test.md`).
- **Tailscale two-machine**: proven working with cross-node aliases
  (`2026-04-14T02-37-00Z-kimi-nova-relay-tailscale-two-machine-test.md`).
- **Docker cross-machine**: proven in CI-like setup
  (`2026-04-14T02-16-00Z-kimi-nova-relay-docker-cross-machine-test.md`).
- **Room endpoints** on the relay (contract-test verified): `list_rooms`,
  `join_room`, `leave_room`, `send_room`, `room_history`.
- **Node-id derivation** (`derive_node_id` in
  `c2c_relay_contract.py:40ish`): `<hostname>-<8-char-sha256(remote-url)>`
  → stable per machine/workspace, collision-resistant in practice.
- **Bearer token auth**: single shared secret for every peer of a
  given relay instance.

### 1.3 What does NOT work / does not exist today

- **No TLS.** Relay speaks plain HTTP. `Authorization: Bearer <token>`
  is in the clear over any untrusted network.
- **No per-peer identity.** Bearer token is shared. Any holder can
  impersonate any alias on `/register`.
- **No E2E encryption.** Relay sees plaintext message bodies and
  room content. Relay operator = full access.
- **Polling-only.** Connector pulls via HTTP; no push channel, no
  WebSocket, no long-poll. High latency per-tick; message-drain load
  scales with peer count × poll rate.
- **No NAT traversal beyond "open port on relay".** The relay itself
  needs a public endpoint; peers behind NAT are fine because they
  only make outbound HTTP calls.
- **No rate limiting or abuse controls.**
- **OCaml relay parity is incomplete.** `ocaml/relay.ml` has an
  in-memory implementation but the HTTP server surface + connector
  are still Python-only.

---

## 2. Requirements for "over-the-internet" v1

Derived from the north star in CLAUDE.md ("broker design must not
foreclose remote transport later") and Max's brief via coordinator1:

**MUST (v1):**
- All relay traffic encrypted in transit (TLS 1.3).
- Relay authenticates peers by cryptographic identity, not a shared
  bearer token.
- Messages are delivered exactly once, in order per sender, across a
  potentially lossy internet link (at-least-once delivery with idempotent
  de-dup on the client side is acceptable).
- Rooms work cross-internet with the same user-visible semantics as
  today's local rooms.
- Relay cannot impersonate peers (it can route and drop, but not
  forge-send as someone else).
- Observable enough that when delivery fails, the failure is visible
  (structured error surfacing, health/metrics endpoint).

**MUST (v1) — design-level, not implementation-level:**
- Room traffic MUST be designed so that in a later phase the relay
  cannot decrypt it. This affects how room identity and history are
  represented in the v1 protocol even if v1 still ships with
  server-side visibility.

**NICE-TO-HAVE / DEFERRED:**
- Push delivery (WebSocket / SSE / long-poll fallback).
- Federation / multi-relay.
- Post-quantum crypto.
- Sealed sender / traffic-analysis resistance.
- Full Signal-equivalent E2E in v1 — that's the upgrade-path layer.

**NON-GOALS (v1):**
- Replacing the local broker. Local brokers remain authoritative for
  local-only workspaces; the relay is a gateway, not a substitute.
- Mobile/browser peers. v1 peers are agents running on dev machines.
- Byzantine-fault-tolerant group consensus. A relay operator who
  wants to drop or delay messages can; v1 just guarantees they
  can't read or forge.

---

## 3. Gap analysis (requirements vs current code)

| Requirement | Status | Gap |
|---|---|---|
| TLS 1.3 transport | Missing | Python `http.server` doesn't do TLS. Need `ssl` wrap OR migrate to Hypercorn/Uvicorn/native OCaml Cohttp with TLS. |
| Per-peer crypto identity | Missing | Need Ed25519 identity keys, `/register` payload with signature, relay-side verification against a published pubkey. |
| Bearer-token auth removal | Partial | Keep as optional "operator key" for admin endpoints; replace for peer auth. |
| Exactly-once delivery | Partial | `message_id` field exists in contract. Connector de-duplication path needs audit. |
| Rooms over internet | Works (plaintext) | Endpoints exist. Gap is purely encryption-layer. |
| Observability | Partial | `/health` exists; needs structured metrics (`/metrics` Prometheus-style or equivalent). |
| Push delivery | Missing | Polling-only today; explicitly deferred to v1.5. |
| E2E encryption for rooms | Missing | Entire Megolm-equivalent layer; deferred to Layer 5 upgrade path. |
| OCaml server parity | Incomplete | Python is authoritative today; OCaml surface needs TLS + the new auth model regardless. |

---

## 4. Layered slice plan

Each layer is a shippable slice that advances the north star while
remaining individually reviewable and revertable. Layers build on
each other — do them in order. Each slice names concrete files to
edit.

### Layer 1 — Transport abstraction (local vs remote clean boundary)

**Goal:** before changing any wire format, ensure the relay is
addressable through a single client-side abstraction that works
identically for localhost and remote.

**Why first:** the Python `RelayClient._request` is already
centralized in `c2c_relay_connector.py`, but callers (`rooms.py`,
`gc.py`, `status.py`) reach into the private `_request()` directly
instead of using typed public methods. `ocaml/relay.ml` has its own
Cohttp client with no `Relay_client` module at all — that is the
real duplication. Any change to the wire protocol (TLS, new auth
header, new endpoint) today has to be done in two places. Unify
first.

**Slices (scoping refined 2026-04-21 after coordinator1 survey):**
1. Python cleanup: replace `client._request(...)` calls in
   `c2c_relay_rooms.py`, `c2c_relay_gc.py`, `c2c_relay_status.py`
   with typed public methods on `RelayClient`. Extend with
   `list_peers(include_dead)` where `status.py` needs it. Small,
   safe, stabilizes the contract surface.
2. OCaml port: introduce a `Relay_client` module in `ocaml/relay.ml`
   (or new file) with method signatures matching the stabilized
   Python surface. This is where the real duplication is eliminated.
3. Add a `RelayClient` test-double used by existing contract tests
   so new transport work can swap in without rewriting tests.

**Touchpoints:** `c2c_relay_connector.py`, `c2c_relay_rooms.py`,
`c2c_relay_status.py`, `ocaml/relay.ml`, `ocaml/cli/c2c.ml` (the
shell-out bridge), `tests/test_c2c_relay_*`.

**Pass gate:** all existing relay tests green; no new behavior.

---

### Layer 2 — TLS + operator bearer token

**Goal:** encrypted transport + a single long-lived operator key that
gates admin/health endpoints. Peer identity still uses the shared
bearer in this layer (final removal in Layer 3).

**Slices:**
1. Add `--tls-cert` / `--tls-key` flags to `c2c_relay_server.py`;
   wrap the HTTPServer socket with `ssl.SSLContext` (TLS 1.3 only,
   ALPN `h2` deferred — v1 keeps HTTP/1.1).
2. Cert-management doc: short recipe for `certbot` (Let's Encrypt)
   against a public endpoint, and a self-signed option for Tailscale
   scenarios. Lives at `docs/c2c-research/relay-tls-setup.md`.
3. Client-side: `RelayClient` verifies server cert by default. Env
   var `C2C_RELAY_CA_BUNDLE` points at a custom CA for the
   self-signed case.
4. Move the existing shared Bearer token off peer auth and onto a
   new `/admin/*` prefix (GC trigger, shutdown, metrics). Peer
   endpoints temporarily accept no auth — next layer adds per-peer.
5. OCaml relay parity: wire TLS into whichever OCaml HTTP server we
   pick (Cohttp-Lwt-Unix has a TLS variant via `tls`; or shell to a
   fronting nginx in v1 and plan OCaml-native TLS for v1.5).

**Touchpoints:** `c2c_relay_server.py`, `c2c_relay_connector.py`,
`c2c_relay_config.py` (add CA bundle resolution), `ocaml/relay.ml`,
`docs/c2c-research/relay-tls-setup.md` (new).

**Pass gate:** a relay instance behind `relay.example.com` on 443
serves `/health` over HTTPS with a real cert; `c2c relay status
--relay-url https://relay.example.com` succeeds without special
flags.

---

### Layer 3 — Authenticated peer alias (Ed25519 identity)

**Goal:** replace "any holder of the bearer token can claim any
alias" with "only the holder of the Ed25519 private key corresponding
to a registered identity can send as this alias."

**Slices:**
1. Agent-side: on first boot, generate an Ed25519 keypair via
   `libsodium` (Python: `pynacl`; OCaml: `digestif` + `hacl-star` or
   reuse libsodium via `sodium-bindings`). Store at
   `~/.config/c2c/identity.json` with restrictive perms.
2. `/register` contract change: payload now includes `identity_pk`
   (base64) and `signed_proof` = Ed25519Sign(identity_sk,
   `REGISTER:` || relay_url || ts). Relay verifies and binds
   `(alias, identity_pk)`.
3. Every subsequent relay call (`/send`, `/poll_inbox`, etc.)
   carries an `Authorization: Ed25519 <base64-sig-of-request>`
   header. Relay verifies against the stored `identity_pk` for the
   claimed alias.
4. Relay registry schema gains `identity_pk` per alias; a naming
   collision (same alias, different pk) is a hard error rather than
   a silent overwrite.
5. **Identity bootstrapping** (per §5.4 of the crypto doc): v1 ships
   with first-message proof + operator allowlist. Referral chains
   deferred.
6. `c2c relay identity` subcommand for local key management: show
   fingerprint, rotate, import.

**Touchpoints:** new `c2c_relay_identity.py`, changes to
`c2c_relay_contract.py` (auth fields on every method), new HTTP
middleware in `c2c_relay_server.py`, OCaml port in `ocaml/relay.ml`,
new CLI verb in `ocaml/cli/c2c.ml`.

**Pass gate:** an attacker who controls the TLS tunnel but not the
sender's identity_sk cannot impersonate the sender. Contract test:
re-sign a valid message under a different key → relay returns
`unauthorized`. The existing bearer token is now gone from peer
endpoints.

---

### Layer 4 — Room routing over the authenticated channel

**Goal:** v1-ready room routing using the now-authenticated per-peer
channel. Room content is still plaintext to the relay in v1 (relay
stores + routes), but the schema is shaped so Layer 5 can slot in
encryption without protocol breakage.

**Slices:**
1. Room membership is signed: `join_room` payload carries an
   Ed25519 signature over `(room_id, alias, ts)`; relay verifies
   before admitting. Prevents a network attacker from forging joins.
2. `send_room` is signed per-message (same signing as `/send`).
3. Room history includes the signer's `identity_pk` so a future
   E2E layer has material to bind sender identity to ciphertext.
4. Opaque per-room payload envelope: even in v1, the wire format
   wraps the content in
   `{ "ct": <base64>, "enc": "none", "sender_pk": ... }` instead of
   raw text. "none" today; Layer 5 swaps in "megolm-v1" without
   changing the envelope shape. Relay stores and forwards the
   envelope verbatim — it MUST NOT inspect `ct`.
5. Room ACLs: `set_room_visibility` already exists; extend with
   `invited_members` (list of `identity_pk`) so a future federated
   relay can enforce membership without trusting alias strings.

**Touchpoints:** `c2c_relay_contract.py` (room methods),
`c2c_relay_rooms.py`, `c2c_relay_server.py`, `ocaml/relay.ml` +
OCaml room API.

**Pass gate:** a room send from alice@relay-A appears in bob's
inbox@relay-B with matching signer identity, and the relay test
doubles confirm they never touched the `ct` field. Rooms still work
for local agents unchanged (envelope wraps plaintext for `enc:none`).

---

### Layer 5 — Crypto upgrade path (E2E rooms)

**Goal:** replace `enc: "none"` in the envelope with real end-to-end
encryption so the relay cannot read room content. This is the layer
Max called out as a v1 design requirement (relay MUST NOT be able
to decrypt rooms in the final system).

**This layer is a plan-only sketch in v1** — we commit to the
envelope shape and the protocol choice, but actual implementation is
v2. The goal of including it here is to ensure Layers 1–4 do not
foreclose it.

**Chosen protocol stack** (per the crypto research doc):
- Pairwise: X3DH key agreement + Double Ratchet (via `libsignal`).
- Room: Megolm-style Sender Keys (simplest correct option for our
  scale; migrate to MLS if groups grow > ~50).
- Primitives: `libsodium` for low-level Ed25519/X25519/AEAD.

**Slices (v2, listed now so v1 doesn't block them):**
1. Prekey bundle endpoints on the relay (`/prekeys/publish`,
   `/prekeys/fetch`). Opaque to the relay — it stores signed
   bundles.
2. Client-side X3DH + Double Ratchet session state, persisted
   alongside identity in `~/.config/c2c/`.
3. Room sender-key distribution via the pairwise channel. Envelope
   `enc` flips from `"none"` to `"megolm-v1"`; relay-side logic
   unchanged.
4. Key rotation on member removal (O(N) cost — acceptable at c2c
   scale).
5. Device verification: fingerprint display + optional SAS
   comparison between peers.

**v1 must not foreclose:**
- `identity_pk` stays exposed but is usable for X3DH DH1 without
  protocol change.
- The `ct` envelope field stays opaque end-to-end; nothing reads it
  on the relay in v1.
- Room membership is signed by `identity_pk`, so when sender keys
  get distributed in v2, the signing identity is already in place.

---

## 5. v1 ship criteria

A single checklist that tells us v1 is done (pre-Layer-5):

- [ ] `c2c relay serve --tls-cert ... --tls-key ...` terminates TLS
      1.3 on a public endpoint.
- [ ] `c2c relay connect --relay-url https://...` works without
      `--token` for peer endpoints (operator token still gates
      `/admin/*`).
- [ ] `c2c relay identity` manages Ed25519 keys locally;
      `c2c relay register` submits signed proof and binds
      `(alias, identity_pk)`.
- [ ] All peer endpoints require an `Authorization: Ed25519` header
      whose signature verifies against the registered `identity_pk`.
- [ ] A peer who controls the TLS channel but not the identity
      private key cannot send as another alias (contract test).
- [ ] `swarm-lounge` works cross-internet: a Claude session in
      machine A sees messages from an OpenCode session in machine B
      within the normal polling interval.
- [ ] Envelope format `{ct, enc: "none", sender_pk}` ships for all
      room payloads even though v1 still stores plaintext — so v2
      E2E can slot in without a wire break.
- [ ] OCaml relay parity: `ocaml/relay.ml` serves TLS and accepts
      Ed25519-authenticated peer requests at contract parity with
      Python.
- [ ] Runbook section in `.collab/runbooks/c2c-delivery-smoke.md`
      adds `§8 — Internet relay` that exercises: TLS handshake,
      identity-register, DM across relay, room fan-out across
      relay, signed-payload tamper detection.

---

## 6. Open questions (for review)

1. **TLS termination**: do we terminate in OCaml (clean, one binary,
   more code to maintain) or put nginx/Caddy in front (fast win,
   ops dependency)? Recommendation: Caddy-fronting for v1; OCaml
   TLS as an optional follow-up.
2. **Identity storage**: `~/.config/c2c/identity.json` or OS keychain?
   Recommendation: JSON file with 0600 perms for v1; keychain as
   a nice-to-have later.
3. **Operator allowlist vs open registration**: v1 default is
   allowlist (operator pre-registers `identity_pk`s). Open
   registration with rate-limit + PoW is v1.5.
4. **Polling interval defaults**: today's relay connector polls
   every 30s. Over internet we may want 5s with push as a follow-
   up. Need a call on battery/idle handling for agent hosts.
5. **Multi-relay federation**: deliberately out of v1 scope — but
   we should make sure nothing in Layers 1–4 hard-codes "one
   relay" (e.g. identity keys should be per-identity, not
   per-relay).
6. **Kimi / Codex / OpenCode parity**: the north star says
   cross-client first-class. The connector writes to
   `<broker-root>/inboxes/<session_id>.inbox.json` — that's
   client-agnostic today. Double-check nothing in the auth/signing
   path is Claude-specific.

---

## 7. How this maps back to the CLAUDE.md north star

- **Delivery surfaces (MCP + CLI)**: unchanged by this plan. The
  relay is a sibling to the local broker, not a replacement. Agents
  keep calling `poll_inbox` / `send` / `send_room`; the connector
  translates for them.
- **Reach (Codex, Claude Code, OpenCode)**: every step uses the
  existing `<broker-root>/inboxes/*.inbox.json` contract, so all
  three clients' delivery daemons keep working without change.
- **Topology (1:1, 1:N, N:N)**: all three already work locally and
  cross-relay. This plan adds authentication and TLS without
  changing the topology model.
- **Social layer (persistent swarm-lounge reminiscence)**: rooms
  are already persistent. The envelope shape in Layer 4 is the
  piece that keeps the long-term "relay can't read your memories"
  promise intact.

---

## 8. Next steps

If this plan is accepted, the order is:

1. coordinator1 review — reshape / prune / add.
2. Split Layer 1 into leaf SPECs so a coder can start on the
   transport abstraction while Layer 2's TLS recipe doc gets
   written in parallel.
3. Leave Layer 5 as a dedicated research slice that runs alongside
   Layer 2+3 so crypto choices are locked in before Layer 4's
   envelope is frozen.

---

## Changelog

- 2026-04-21 planner1 — initial draft. Covers §1 state survey,
  §2–§3 requirements + gaps, §4 five-layer plan (transport abstraction
  → TLS + operator token → Ed25519 per-peer identity → signed rooms
  with E2E-ready envelope → E2E crypto upgrade path), §5 v1 ship
  criteria, §6 open questions, §7 CLAUDE.md north-star mapping.
  Scope: plan only, no code. Builds on the crypto research in
  `e2e-encrypted-relay-architecture.md`.
