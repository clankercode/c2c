# c2c relay — master index

**Purpose:** single entry point for humans and agents picking up relay
work. Lists every relay doc, current slice status, owners, and the
one-paragraph "where are we vs. the destination."

**Audience:** anyone (Max, a new swarm agent, reviewers) who needs
the relay picture in under a minute.

---

## North star — one paragraph

c2c today routes messages between **local** agents via a file-based
broker in `.git/c2c/mcp/`. The relay layer extends that so two hosts
on the open internet can talk to each other over the same message
envelope, with the relay server acting as a mailbox the peers can't
read. Shipping this happens in five layers (see master plan below).
At Layer 2 it's usable over TLS+Tailscale; at Layer 3 peer alias
spoofing becomes cryptographically impossible; at Layer 5 the relay
operator cannot read message contents even if fully compromised.
Python is being displaced in favor of OCaml as each layer lands.

---

## Documents

| Doc                                          | Purpose                                               |
|----------------------------------------------|-------------------------------------------------------|
| `relay-internet-build-plan.md`               | Master plan: 5 layers, slices, pass gates, open Qs    |
| `e2e-encrypted-relay-architecture.md`        | Crypto architecture research (X3DH, Double Ratchet…)  |
| `relay-tls-setup.md`                         | Operator recipe for certs (LE, self-signed, proxy)    |
| `relay-peer-identity-spec.md`                | Layer 3 concrete spec — Ed25519 format, handshake     |
| `relay-railway-deploy.md`                    | Operator recipe for Railway deployment                |
| `RELAY.md` (this file)                       | Dashboard / status index                              |

---

## Slice status

Legend: ✅ shipped · 🟡 in progress · ⏳ blocked · ⚪ open · ⏸ deferred

### Layer 1 — Transport abstraction

| Slice                                         | Status | Owner        | Commit      |
|-----------------------------------------------|--------|--------------|-------------|
| 1. Typed public methods on RelayClient (OCaml-first per steering) | ✅ | coordinator1 | `9d16860`   |
| 2. Port Relay_client contract-test coverage   | 🟡    | coordinator1 | —           |
| 3. Native OCaml `c2c relay status`            | ✅    | coordinator1 | `bbaf8e8`   |
| 4. Native OCaml `c2c relay list` (--dead still shells out) | ✅ | coder2-expert | `b7a789b`   |
| 5. Native OCaml `c2c relay rooms list` + `gc --once` | ✅ | coder2-expert | `6a1f8cb`   |

### Layer 2 — TLS + operator bearer token

| Slice                                         | Status | Owner          | Commit               |
|-----------------------------------------------|--------|----------------|----------------------|
| 1. Actual TLS wiring (OCaml `tls` via cohttp) | 🟡    | coder2-expert  | —                    |
| 2. Cert-management doc                        | ✅    | coder1         | `7093038`            |
| 3. Client-side CA bundle resolution           | ✅    | coder1         | `e395758`            |
| 4. Move bearer token off peer → admin-only    | ⚪    | —              | —                    |
| 5. OCaml TLS parity (integration design)      | 🟡    | coder2-expert  | `0ae9253`, `4f69412` |

### Layer 3 — Ed25519 peer identity

| Slice                                         | Status | Owner      | Commit     |
|-----------------------------------------------|--------|------------|------------|
| Spec doc (all 6 slices defined)               | ✅    | planner1   | `75d1ad3`  |
| 1. Keypair generation + on-disk identity.json | ⚪    | —          | —          |
| 2. `/register` contract change + verification | ⚪    | —          | —          |
| 3. Per-request Ed25519 auth header            | ⚪    | —          | —          |
| 4. Registry schema + first-bind-wins          | ⚪    | —          | —          |
| 5. Identity bootstrapping (first-msg / allowlist) | ⚪| —          | —          |
| 6. `c2c relay identity` subcommand            | ⚪    | —          | —          |

Open decisions flagged before coding starts: **Q1** (always-sign vs
session tokens) and **Q6** (TLS cert fingerprint inside register
blob) — see `relay-peer-identity-spec.md` §13.

### Layer 4 — Room routing over authenticated channel

| Slice        | Status | Owner | Commit |
|--------------|--------|-------|--------|
| Spec + slices defined only at master-plan level | ⚪ | — | — |

Blocked on Layer 3. Needs its own spec doc — planner should draft
once Layer 3 Qs are resolved.

### Layer 5 — E2E crypto upgrade path

| Slice                                         | Status | Owner | Commit |
|-----------------------------------------------|--------|-------|--------|
| Research (X3DH + Double Ratchet + Megolm)     | ✅    | —     | `e2e-encrypted-relay-architecture.md` |
| Implementation slices                         | ⏸    | —     | —      |

Deferred to v2. v1 envelope is E2E-ready (`{ct, enc: "none",
sender_pk}`) so this doesn't require another wire break.

### Layer-adjacent tasks

| Task                                         | Status | Owner  | Notes                        |
|----------------------------------------------|--------|--------|------------------------------|
| Task #6 — Railway deploy demo                | ✅    | coder1 | `a8266bd` — `docker build` + `railway up` unverified by coder1 (no daemon in sandbox); operator smoke still pending |

---

## Current owners

| Layer              | Primary           | Notes                                  |
|--------------------|-------------------|----------------------------------------|
| Layer 1            | coordinator1      | OCaml Relay_client port                |
| Layer 2 impl       | coder2-expert     | OCaml TLS wiring (not Python ssl)      |
| Layer 2 doc        | coder1            | cert setup + CA bundle both shipped    |
| Layer 3 spec       | planner1          | shipped; impl unclaimed                |
| Layer 4            | —                 | blocked on L3 decisions                |
| Layer 5            | —                 | deferred to v2                         |

---

## Cross-cutting steering (2026-04-21, Max via coordinator1)

> Python is deprecated long-term. "It's okay for testing but even
> now the python scripts sometimes cause issues. So we definitely
> want to use ocaml if we can."

Concrete consequences already applied:

- Layer 1 pivoted off Python cleanup, straight to OCaml
  `Relay_client` port (`9d16860`).
- Layer 2 implementation target flipped from `ssl.SSLContext` to
  OCaml-native `tls`/`cohttp-lwt-unix.tls`.
- Layer 3 spec demotes PyNaCl to test-only; primary lib is
  `mirage-crypto-ec` (reuses the Layer 2 TLS dep).
- Any new relay feature lands in OCaml before Python. Python gets
  it only if a test needs it. Full OCaml parity unlocks Python
  relay deletion.

---

## Maintenance

- Update this file when a slice lands. One commit per status change
  is fine — it's an index, not a narrative.
- Keep the owner column honest: if you've dropped a slice, clear
  your name so another agent can pick it up.
- Slice descriptions should match the source-of-truth (the layer
  spec doc). If they drift, fix the index, not the spec.

---

## Changelog

- 2026-04-21 planner1 — initial RELAY.md. Seeded from status
  reported in swarm-lounge at 00:31Z.
- 2026-04-21 coder2-expert — added Layer 1 slices 4–5 (native `relay
  list`, `rooms list`, `gc --once`) at `b7a789b`, `6a1f8cb`.
