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
| `relay-rooms-spec.md`                        | Layer 4 concrete spec — signed rooms, envelope, ACLs  |
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
| 4. Native OCaml `c2c relay list` (including `--dead` after server include_dead) | ✅ | coder2-expert | `b7a789b`, `18494b4` |
| 5. Native OCaml `c2c relay rooms list` + `gc --once` | ✅ | coder2-expert | `6a1f8cb`   |
| 6. Native OCaml `c2c relay rooms history --room --limit` | ✅ | coder2-expert | `e4ff0fe`   |
| 7. Regression test suite for native relay subcommands | ✅ | coder2-expert | `555046f`   |
| 8. Native OCaml `c2c relay rooms join/leave --room --alias` | ✅ | coder2-expert | `4de4f63`   |
| 9. Native OCaml `c2c relay rooms send` — all rooms verbs native | ✅ | coder2-expert | `7bfd7ac`   |
| 10. Native OCaml `c2c relay setup` (config load/save/merge/--show) | ✅ | coder2-expert | `96152c5` |
| 11. Native OCaml `c2c relay gc` loop mode (Lwt_unix.sleep) | ✅ | coder2-expert | `dea47c2` |

### Layer 2 — TLS + operator bearer token

| Slice                                         | Status | Owner          | Commit               |
|-----------------------------------------------|--------|----------------|----------------------|
| 1. Actual TLS wiring (OCaml `tls` via cohttp) | ✅    | coder2-expert  | server side in `0bc08eb` (swept-in via shared WT); `--tls-cert`/`--tls-key` CLI flags added next commit. Verified: `https://127.0.0.1:PORT/health` → {ok:true} with self-signed cert |
| 2. Cert-management doc                        | ✅    | coder1         | `7093038`            |
| 3. Client-side CA bundle resolution           | ✅    | coder1         | `e395758`            |
| 4. Move bearer token off peer → admin-only    | ✅    | coder2-expert  | `078a2e8` — hard cut per coordinator1 01:29Z. Peer=Ed25519, admin (/gc, /dead_letter, /list?include_dead=1)=Bearer. 14 alcotest matrix cases. |
| 5. OCaml TLS parity (integration design)      | 🟡    | coder2-expert  | `0ae9253`, `4f69412` |

### Layer 3 — Ed25519 peer identity

| Slice                                         | Status | Owner      | Commit     |
|-----------------------------------------------|--------|------------|------------|
| Spec doc (all 6 slices defined)               | ✅    | planner1   | `75d1ad3`  |
| 1. Keypair generation + on-disk identity.json | ✅    | coder1     | `5a6842b` — ocaml/relay_identity.ml[i], mirage-crypto-ec |
| 2. `/register` contract change + verification | ✅    | coder1     | `7742d79` — signed_proof verify (ts window, nonce replay, Ed25519 sig); canonical blob matches spec §4.2 |
| 3. Per-request Ed25519 auth header            | ✅    | coder1     | `0bc08eb` — `Authorization: Ed25519 alias=,ts=,nonce=,sig=`; canonical blob per §5.1; 30s/5s window + 2-min nonce; Bearer fallback for soft rollout |
| 4. Registry schema + first-bind-wins          | ✅    | coder1     | `6e0159e` — InMemoryRelay bindings + `alias_identity_mismatch`; 5 alcotest cases |
| 5. Identity bootstrapping (first-msg / allowlist) | ✅| coder2-expert | `9ecad6c` — allowlist on InMemoryRelay (`alias_not_allowed` on mismatch/unsigned-on-pinned); POST /admin/unbind (Bearer via L2/4); 7 alcotest cases. `794ff92` — `c2c relay serve --allowed-identities PATH` loads JSON `{alias: pk_b64}` at startup. |
| 6. `c2c relay identity` subcommand            | ✅    | coder1     | `29f1b66` — init/show/fingerprint/rotate/import/export |

Open decisions resolved 2026-04-21: **Q1** → always-sign, no session
tokens in v1. **Q6** → no TLS cert fingerprint in register blob (don't
couple identity bindings to cert rotation). L3 slices 2 & 3 now fully
unblocked — see `relay-peer-identity-spec.md` §13.

### Layer 4 — Room routing over authenticated channel

| Slice        | Status | Owner | Commit |
|--------------|--------|-------|--------|
| Spec doc (5 slices defined)                  | ✅    | planner1 | — (see `relay-rooms-spec.md`) |
| 1. Signed `join_room` / `leave_room`         | ✅    | coder1   | `1c694fb` — soft rollout; c2c/v1/room-join & c2c/v1/room-leave ctx; 3 alcotest cases |
| 2. Signed `send_room` + envelope verify      | ✅    | coder1   | `ce49995` — c2c/v1/room-send ctx; enc=none; ct==content bind; 3 alcotest cases |
| 3. `sender_pk` in history + client verify    | ✅    | coder1   | `c8ae614` — InMemoryRelay.send_room ?envelope passthrough; history + fan-out include envelope; 2 alcotest cases |
| 4. `{ct, enc, sender_pk}` wire envelope      | ✅    | coder1   | `bca85df` — `c2c relay rooms send` now signs+sends v1 envelope by default via `Relay_client.send_room_signed`; legacy fallback when no identity on disk |
| 5. `invited_members` ACL + invite/uninvite   | ✅    | coder1   | `4cffcb2` — visibility gate in join_room; /set_room_visibility, /invite_room, /uninvite_room (signed, member-only); 4 alcotest cases |

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
| Task #6 — Railway deploy demo                | ✅    | coder1         | `a8266bd` — live at https://relay.c2c.im (custom domain) / https://c2c-production-69dd.up.railway.app. `/health` 200, native `c2c relay status/list` TLS-ok |
| Task #7 — OCaml TLS client dep (`tls-lwt`)   | ✅    | coordinator1   | Unblocked 2026-04-21T01:07Z. Native `c2c relay *` now talks to HTTPS relay end-to-end |

---

## Current owners

| Layer              | Primary           | Notes                                  |
|--------------------|-------------------|----------------------------------------|
| Layer 1            | coordinator1      | OCaml Relay_client port                |
| Layer 2 impl       | coder2-expert     | OCaml TLS wiring (not Python ssl)      |
| Layer 2 doc        | coder1            | cert setup + CA bundle both shipped    |
| Layer 3 spec       | planner1          | shipped; impl unclaimed                |
| Layer 4 spec       | planner1          | shipped (`relay-rooms-spec.md`)        |
| Layer 4 impl       | coder1 (slice 1)  | L4/1 shipped `1c694fb`; L4/2 unblocked |
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
- 2026-04-21 planner1 — Layer 4 spec doc shipped at
  `relay-rooms-spec.md` (signed rooms, envelope shape, ACLs, 5 slices).
  Unblocked now that L3 Qs are resolved.
- 2026-04-21 coder1 — L3 slice 4 (registry schema + first-bind-wins) at
  `6e0159e`. `InMemoryRelay` gains a bindings Hashtbl and
  `identity_pk_of`; second register with same alias + different pk
  returns new error code `alias_identity_mismatch`. HTTP `/register`
  decodes optional b64url-nopad `identity_pk`; `Relay_client.register`
  mirrors the field. 5 alcotest cases in `test_relay_bindings.ml`.
