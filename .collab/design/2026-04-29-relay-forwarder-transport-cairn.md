# Relay-to-Relay Forwarder Transport — design

**Author:** cairn-vigil (coordinator1)
**Date:** 2026-04-29
**Status:** design / pre-slice
**Issue:** #330 (mesh validation), follows #379 S1+S2+S3 (alias@host
parsing + dead-letter contract)
**Predecessor scope doc:** `.collab/design/2026-04-28T12-26-00Z-coordinator1-330-relay-mesh-probe-scope.md`
**Validation companion:** `.collab/research/2026-04-29-330-relay-mesh-validation-plan-cairn.md`
**Cross-refs:** `ocaml/relay.ml:3163-3215` (handle_send / cross-host
seam), `ocaml/c2c_relay_connector.ml` (Ed25519 client to reuse),
`ocaml/relay_remote_broker.ml` (SSH transport, NOT used here — keep
distinct).

---

## TL;DR

Turn the synchronous `cross_host_not_implemented` 404 into a
**forwarder POST** to a peer relay listed in a static `peer_relays`
table. Reuse Ed25519 signing for relay→relay auth (each relay holds
its own keypair, signs forwarded `/send` like any client). Persist
nothing new on the sender side beyond today's `dead_letter` archive;
v1 is **best-effort with bounded synchronous retry then dead-letter**
— no durable outbox. Loop-prevention via `via:` envelope header
capped at 1 hop. Single dest-relay HTTP POST per message; no
WebSocket; no gossip discovery.

---

## 1. Today's seam (where rejection lives)

`ocaml/relay.ml:3163-3215` — `handle_send`. After body validation,
the host is split off the to-alias:

```ocaml
let stripped_to_alias, host_opt = split_alias_host to_alias in
let self_host = R.self_host relay in
if not (host_acceptable ~self_host host_opt) then
  (* #379: dead-letter + 404 cross_host_not_implemented *)
  let msg_id = ... in
  let dl = `Assoc [...; ("reason", `String "cross_host_not_implemented")] in
  R.add_dead_letter relay dl;
  respond_not_found (json_error_str "cross_host_not_implemented" ...)
else
  ... local-delivery branch ...
```

Behavior today:

- Sender (broker / CLI / MCP) submits `bob@relay-b` to relay-A.
- relay-A computes `host_opt = Some "relay-b"`, `self_host = "relay-a"`.
- `host_acceptable` returns false (host_opt is Some and ≠ self_host
  and ≠ literal "relay" back-compat).
- Envelope is appended to relay-A's `dead_letter` archive with
  `reason: cross_host_not_implemented`.
- Sender receives a synchronous 404 with the same reason string.

This is the **single seam** the forwarder replaces. The branch becomes:
"is `host_opt` in our `peer_relays` table? if yes → forward; if no →
dead-letter as today."

## 2. Forwarder topology

### Link shape: per-message HTTP POST, NOT persistent connection

- **Per-message POST** to peer's existing `/send` ingress, NOT a
  persistent stream.
- Reasons: zero new transport surface (peer relay's `/send` already
  authn/authz/dedup); dead-letter semantics are the v1 retry policy
  (no in-memory queue to lose); fits relay's existing Lwt request
  loop; recovers automatically when peer comes back without a
  reconnect dance.
- **NOT** WebSocket / HTTP/2 streams in v1. Considered: persistent
  connection would amortize TLS handshake — but v1 forwarder budget
  is "10 msg/sec across the seam, dev probe scale." Per-POST is
  fine. Revisit at v3 if production traffic warrants.
- **Single direction per send.** The forwarder POST is one-shot
  fire-and-respond. Bidirectional ack is implicit in the HTTP
  response. Reverse traffic (replies bob→alice) goes through the
  same shape from relay-B → relay-A — symmetric per-message POST,
  not a shared duplex pipe.

### Why not WebSocket

- Adds connection-state machine to relay (currently stateless
  request/response).
- Doesn't help dead-letter semantics — we still need persistence
  on disconnect; WS just changes the disconnect detection latency.
- Defers the "real outbox" question without solving it.

### Why not HTTP/2

- Cohttp_lwt_unix in tree is HTTP/1.1; HTTP/2 is a dependency
  upgrade with no v1 throughput justification.

## 3. Discovery

### v1: static config (`--peer-relay name=url`, repeatable)

- Repeatable CLI flag on `c2c relay serve`:
  `--peer-relay relay-b=http://relay-b:9001 --peer-relay relay-c=...`
- Populates an in-process `peer_relays : (string, peer_relay_t)
  Hashtbl.t` keyed on relay-name (host).
- TOML/`.c2c/relay.toml` equivalent for production deploys.
- No discovery protocol. No DNS SRV. No gossip.

### Why static for v1

- Two-relay probe is the AC; static config is sufficient.
- Discovery introduces a trust-bootstrap problem (which relay do
  you trust to tell you about other relays?) that's orthogonal to
  the forwarding seam.
- Keeps the v1 attack surface flat — operator wrote down each peer
  explicitly.

### v2 paths, NOT in v1 but design must not foreclose

- DNS SRV / TXT records (`_c2c._tcp.relay-b.example` → host:port +
  pubkey fingerprint).
- Gossip via existing peer-relay links (relay-A learns about
  relay-C from relay-B's response). Requires loop-prevention
  beyond `via:` — leave for v2.
- DHT-style discovery for fully-decentralized topology — v3+.

The `peer_relays` Hashtbl is the only abstraction; swapping its
populator (static-config → DNS resolver → gossip cache) is a
follow-up that doesn't touch the forwarder code path.

## 4. Auth model

### v1: Ed25519 per-relay identity, reused from `c2c_relay_connector.ml`

- Each `c2c relay serve` boots with an **identity keypair** stored
  at `<broker_root>/relay-identity.json` (same shape as connector
  identity today). Auto-generated on first boot if missing.
- The relay binds its public key to its `--relay-name` at boot;
  exposes `/relay_info` (already exists) returning
  `{ name, identity_pk, version }`.
- Forwarded `/send` calls are signed exactly like client `/send`:
  body-level Ed25519 proof per `Relay_signed_ops.sign_request`.
- The receiving relay treats the sender-relay as a regular
  alias-bearing client: relay-A's identity is registered (via
  bootstrap or first-contact register flow) on relay-B with alias
  `relay-a` (mirror of `--relay-name`).

### Trust bootstrap

- v1: **out-of-band, operator-exchanged.** When relay-A is
  configured with `--peer-relay relay-b=URL`, the operator also
  configures relay-B with relay-A's identity_pk. Concretely:
  `--peer-relay-pubkey relay-a=<base64-pk>` on relay-B's CLI.
- Equivalent shape to a pre-shared key (PSK) but using existing
  Ed25519 identity rather than a fresh symmetric secret. **No new
  PSK substrate needed.** The current PSK draft
  (`.collab/design/DRAFT-per-alias-signing-keys.md`) is for
  per-alias signing; relay-relay reuses the same keypair model
  but at relay-identity granularity.

### Why not mutual TLS

- TLS termination today is the operator's reverse-proxy concern
  (Caddy/Nginx in front of relay). Adding mTLS would push cert
  management into the relay binary. Ed25519 over plain HTTP
  (TLS-terminated upstream) gives the same trust-bound-to-identity
  property without certificate machinery.

### Why not per-message signed envelope (separate from request)

- Considered: "the original sender alice signs the envelope, every
  relay just verifies and forwards." That's the right end-state.
  But: today's clients don't sign envelopes (only requests), so
  the forwarder would have to forge sender signatures or pass an
  unsigned body. v1 ducks this by signing **as the forwarding
  relay**, treating relay-A as alice's delegate. End-to-end
  envelope signing is a v2 design that requires client-side change.

## 5. Message flow

```
alice@relay-a → bob@relay-b

t=0  alice MCP send → relay-A /send
       body: { from_alias: "alice", to_alias: "bob@relay-b", content, message_id }
t=1  relay-A.handle_send:
       - split_alias_host("bob@relay-b") → ("bob", Some "relay-b")
       - host_acceptable false (≠ self_host "relay-a")
       - peer_relays.find "relay-b" → Some { url, pubkey }
       - construct forwarder body:
           { from_alias: "alice@relay-a"  (* CHANGED: tag origin host *)
           ; to_alias: "bob"               (* stripped *)
           ; content
           ; message_id  (* same UUID *)
           ; via: ["relay-a"]  (* hop list, capped at 1 in v1 *)
           }
       - sign with relay-A identity (Ed25519 over body-bytes)
       - POST relay-B/send
t=2  relay-B.handle_send:
       - verify Ed25519 signer is in known peer-relay table (relay-A)
       - via.length ≤ 1 ⇒ accept; > 1 ⇒ dead-letter loop_detected
       - host_acceptable("bob") true (bare alias, self_host accepts)
       - existing local delivery: append to bob's inbox archive
       - dedup_window catches duplicate message_id
       - 200 OK { ok, ts }
t=3  relay-A receives 200 → returns 200 to alice's original /send call
       alice sees `Ok ts` (same as local delivery)
t=4  bob's poller (local broker on relay-B) returns the message;
       envelope reads `from_alias: "alice@relay-a"` so bob's UI shows
       the origin host.
```

### Confirmation back to alice

- **Inline.** Relay-A's POST to relay-B is awaited inside the
  original handle_send. alice's HTTP request blocks until relay-B
  ACKs (or timeout fires).
- Latency budget: ~50ms for local Docker, <200ms for cross-WAN. v1
  timeout: 5s. Above budget for sync delivery (we already
  synchronously talk to local fs); below user-perceptible threshold.

### Reverse path (bob → alice)

- Symmetric. bob@relay-b sends to alice@relay-a; relay-B forwards
  to relay-A; same shape, swapped roles. Each direction needs the
  peer to be configured in BOTH relays' `peer_relays` tables — not
  automatic.

## 6. Failure modes

| Mode | Detection | v1 behavior |
|---|---|---|
| Peer relay TCP refused | connect() fails immediately | dead-letter `peer_unreachable`; sender 502 |
| Peer relay timeout (5s) | Lwt timer fires | dead-letter `peer_timeout`; sender 504 |
| Peer 5xx response | HTTP status | dead-letter `peer_5xx`; sender 502 |
| Peer 4xx (e.g. unknown_alias on dest) | HTTP status | dead-letter `peer_rejected`; sender 404 (propagate the dest relay's reason) |
| Auth rejection (relay-A pk not registered on relay-B) | HTTP 401 | dead-letter `peer_unauthorized`; sender 502 — **operator config error** |
| Loop (via.length > 1 on inbound) | relay-B's ingress check | dead-letter `loop_detected`; respond 422 to forwarding relay |
| Replay attack (forwarded message_id reused) | relay-B's existing dedup_window | silent dedupe; respond `Duplicate ts` (which propagates back as success — sender already considers it delivered) |
| Identity mismatch (signer pk ≠ peer-relay table entry) | Ed25519 verify fails | 401 from relay-B, sender dead-letters |
| Persistent split-brain (relay-B unreachable for hours) | repeated POST fails | every cross-host send dead-letters; doctor surfaces UNREACHABLE; **no auto-replay in v1** |
| Transient network blip | one POST fails, next succeeds | dead-letter the failed one; manual replay via `c2c send`; v1 explicitly does NOT retry within the same POST |

### What v1 does NOT do

- No exponential-backoff retry within a single send. (One POST,
  one outcome.)
- No durable outbox spool that survives relay-A restart.
- No auto-replay of dead-lettered messages on relay-B recovery.
- No half-open detection between forwarder POSTs (next POST will
  re-discover unreachable).

## 7. Outbox semantics

### v1: no new persistent outbox

- The sender-side broker's `remote-outbox.jsonl` (existing,
  consumed by `c2c_relay_connector`) is **upstream** of the relay
  forwarder. It already provides per-broker durability.
- The relay forwarder itself is **stateless across the POST**. If
  the POST fails, the dead-letter archive is the only record; no
  in-memory retry queue.
- This is deliberate v1 minimalism: the forwarder is a transparent
  pipe, not a store-and-forward agent. Durability is the broker's
  job (already done) and the dead-letter's job (already done).

### Retry policy

- **None within a single send.** One POST attempt, 5s timeout, fail
  → dead-letter.
- **Caller-driven replay** is the v1 retry: dead-lettered messages
  surface in `c2c doctor relay-mesh` (validation V2 slice) and the
  operator/sender re-sends manually.

### When does dead-letter happen

| Trigger | Dead-letter file | Reason |
|---|---|---|
| Cross-host with no peer-relay entry | relay-A's archive | `cross_host_not_implemented` (kept for back-compat — same as today) |
| Peer-relay connect/timeout/5xx | relay-A's archive | `peer_unreachable` / `peer_timeout` / `peer_5xx` |
| Peer relay rejected message | relay-A's archive | `peer_rejected_<reason>` |
| Loop detected | relay-B's archive | `loop_detected` |
| Auth failure (signer not in peer table) | relay-B's archive | `peer_unauthorized` |

All dead-letter rows include the original envelope plus
`{relay: "relay-a" | "relay-b", phase: "forward_out" | "ingress"}`
so doctor can attribute the failure to the right hop.

## 8. v1 scope (minimal viable)

The slice that lands the forwarder:

- 2 relays (relay-A, relay-B). Each on its own port (or host).
- Static `peer_relays` table per relay, populated from
  `--peer-relay name=url --peer-relay-pubkey name=base64pk` flags.
- Ed25519 auth using relay's own identity keypair (auto-generated).
- Single POST, 5s timeout, no retry, dead-letter on any failure.
- `via:` hop count cap at 1 (no multi-hop forwarding).
- `from_alias` rewritten to `alice@relay-a` form on forward so
  recipient sees origin.
- `message_id` propagated verbatim for cross-relay dedup.

What's deliberately deferred to v2+:

- More than 2 relays in a single mesh (works structurally but
  untested at >2).
- Cross-relay rooms.
- Cross-relay ephemeral semantics.
- Multi-hop forwarding (loop-cap raised to 3 + path-vector).
- Durable outbox spool with retry + auto-replay.
- End-to-end envelope signatures (alice's signature carried verbatim).
- Discovery beyond static config.
- mTLS; bring-your-own-CA.

## 9. Implementation slices

5 slices, each ≤200 LOC, sequential:

### S1 — peer_relays table + identity bootstrap (~150 LOC)
- Add `relay-identity.json` autogen at `<broker_root>/relay-identity.json`
  on `c2c relay serve` boot.
- Add `peer_relays : (string, peer_relay_t) Hashtbl.t` to `Relay.t`.
- Type `peer_relay_t = { name: string; url: string; identity_pk: string }`.
- CLI flags: `--peer-relay name=url` (repeatable),
  `--peer-relay-pubkey name=base64`. Validate pairs match at boot;
  refuse to start on mismatch.
- **AC:** unit test — boot relay with two peer entries, assert
  table populated, identity file persisted across restart.

### S2 — forwarder POST replacing dead-letter branch (~180 LOC)
- In `handle_send`, replace the dead-letter-only branch with:
  `match Hashtbl.find_opt peer_relays host with
   | Some peer → forward_send relay peer ~from ~to_ ~content ~msg_id
   | None → dead_letter as today`.
- New `forward_send`: builds body with rewritten `from_alias`, adds
  `via: [self_host]`, signs with relay identity, POSTs to peer URL,
  awaits response, returns mapped result.
- 5s Lwt timeout. All failure modes → dead-letter + propagate
  matching status to caller.
- **AC:** unit test (in-process two `Broker.t` instances, fake HTTP
  via stub) — happy path delivers, peer-down dead-letters, loop is
  detected.

### S3 — ingress side: via-cap + relay-pk verification (~120 LOC)
- `handle_send` ingress: if request signer's pk is in `peer_relays`
  by-pk index → mark request as "from peer relay" → enforce
  `via.length ≤ 1` (else dead-letter `loop_detected`); else treat
  as regular client send.
- `from_alias` allowed to contain `@host` only when sender is a
  peer relay (regular clients still rejected if from_alias has @).
- **AC:** unit test — relay-B receives forwarded message from
  relay-A (registered peer): accepted; from unknown signer with
  `@host` from-alias: rejected.

### S4 — docker probe + integration test (~200 LOC)
- Extend `.worktrees/330-relay-mesh/docker-compose.relay-mesh.yml`
  to add a second relay service + cross-link flags. (Actually this
  lives in the validation V3 slice; cross-ref.)
- `docker-tests/test_relay_mesh_probe.py` — single AC: alice@host-a
  → bob@host-b round-trip in <5s.
- **AC:** test green; total compose RSS ≤ 600 MB per validation
  doc budget.

### S5 — `c2c doctor relay-mesh` + dead-letter visibility (~150 LOC)
- New `c2c doctor relay-mesh` subcommand: prints peer-relay table
  with last_forward_status, last_seen_at, classification.
- Dead-letter rows now include `phase` field; doctor surfaces the
  forwarder-attributable subset distinctly.
- **AC:** doctor output visually distinguishes forwarder failures
  from local rejections; operator can grep by phase.

### S6 — docs + closeout (~not really code)
- Update `docs/cross-machine-broker.md` v1-probe section.
- New runbook `.collab/runbooks/relay-mesh-forwarder.md` covering
  the boot sequence, the pubkey exchange, and the dead-letter
  triage flow.
- Coord-PASS, push when validated, close #330.

### S7 — (stretch) reverse-path symmetry test
- The probe in S4 covers alice→bob. Add a bob→alice reply test in
  the same compose to assert symmetry. Cheap if S4 is green.

**Sequencing:** S1 → S2 → S3 in one worktree (~450 LOC, the
forwarder slice proper). S4-S5-S6 follow. S7 stretch.

## 10. Open questions

1. **Where do relay identity keypairs live?**
   `<broker_root>/relay-identity.json` matches the existing
   connector identity pattern. Same on-disk shape? Or a parallel
   `relay-server-identity.json` to clearly separate "this relay
   acting as a server" from "this host's connector identity"?
   Recommend: separate filename for clarity.

2. **Should `from_alias` rewriting happen at the forwarding relay
   or at the sender broker?** v1 says forwarding relay (alice
   sends "alice", relay-A rewrites to "alice@relay-a"). Cleaner
   would be sender-side (alice already knows her host). But that
   requires every client to learn host-tagging which is a much
   bigger change. Forwarder rewrite is the v1 compromise; document
   clearly.

3. **What's the `peer_relays`-by-pk index structure?** Two reads
   per ingress (by-host on outbound, by-pk on inbound). v1: two
   Hashtbls or one Hashtbl + linear scan-by-pk? Linear scan fine
   for ≤10 peers. Note in code.

4. **Does the forwarder set a `Connection: keep-alive` and pool
   per-peer connections?** Cohttp_lwt_unix supports it but
   per-message create-and-close is simpler. Probe will tell us if
   handshake cost is real. Default: no pooling in v1.

5. **What if the dest relay says `unknown_alias`?** Today the
   user's broker would dead-letter locally. With forwarding, the
   sender-side relay-A receives a 404 from relay-B and dead-letters
   on relay-A's side. This means dead-letter inspection requires
   doctor to query *both* relays. Acceptable for v1; flag in
   runbook.

6. **Does relay identity need rotation?** Out of scope for v1
   (matches per-alias signing posture — keys are
   create-once-and-keep). Flag for v2.

7. **Should we propagate alice's *original* HTTP signature, or
   re-sign at relay-A?** v1 = re-sign. End-to-end signing of the
   send body is the v2 design that needs alice's client to sign
   the envelope (not just the request) — bigger change.

8. **`via:` field — envelope or request-header?** Recommend
   envelope (in body JSON) so it travels with the message into
   the dead-letter / archive. Request-header would be cleaner HTTP
   but lose history.

---

## Appendix — file map

- **Touch:** `ocaml/relay.ml` (handle_send seam at 3163; ingress
  signer-table check at ~3917; new `forward_send` helper).
- **Touch:** `ocaml/cli/c2c_relay.ml` (CLI flags).
- **New:** `ocaml/relay_forwarder.ml` (~250 LOC: peer_relays
  table, forward_send, via-cap logic).
- **Reuse:** `ocaml/c2c_relay_connector.ml` (`request` /
  `sign_request` / `Relay_signed_ops.sign_request`).
- **NOT touched:** `ocaml/relay_remote_broker.ml` (SSH transport,
  orthogonal).
- **New tests:** `ocaml/test/test_relay_forwarder.ml` (S2/S3 ACs);
  `docker-tests/test_relay_mesh_probe.py` (S4 AC).
- **New doc:** `.collab/runbooks/relay-mesh-forwarder.md` (S6).

**Next action:** flag this design in `swarm-lounge`, request a
read-through from stanza/jungle/lyra, then split off worktree
`.worktrees/330-forwarder-s1-s3/` for the core forwarder slice.
