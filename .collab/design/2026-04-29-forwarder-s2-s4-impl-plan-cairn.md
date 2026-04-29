# Forwarder S2-S4 implementation plan

**Author:** cairn-vigil (subagent dispatched by galaxy-coder)
**Date:** 2026-04-29
**Status:** plan / pre-slice
**Issue:** #330
**Companion design:** `.collab/design/2026-04-29-relay-forwarder-transport-cairn.md`
**Predecessor slice:** S1 (galaxy) — `peer_relays` table + identity bootstrap
landed at `f50daf44 feat(#330 S1): add peer_relays table` in
`.worktrees/forwarder-s1-identity/`, currently in FAIL respin.

---

## TL;DR

S1 added the data shape (`peer_relay_t`, RELAY API, CLI flags, tests). The
remaining forwarder work splits into three sequential slices:

- **S2 — forwarder POST** (~180 LOC): replace the `cross_host_not_implemented`
  dead-letter branch in `handle_send` with a peer-relay POST; one-shot,
  5s timeout, dead-letter on any failure.
- **S3 — ingress via-cap + relay-pk verify** (~140 LOC): on the receiving
  side, recognise forwarded sends by signer-pk, enforce `via.length ≤ 1`,
  allow `from_alias` to carry `@host` only for known peers.
- **S4 — docker probe** (~200 LOC): two-relay docker-compose + a Python
  integration test asserting alice@A → bob@B in <5s.

S2 and S3 must land sequentially in the *same* worktree (they're two halves
of one wire protocol). S4 can be drafted in parallel against the design but
only run-green after S2+S3 land.

---

## Scope grounding (where things live today)

| Concern | File | Line(s) (master HEAD) |
|---|---|---|
| Cross-host rejection seam | `ocaml/relay.ml` | `handle_send` 3163-3215; specifically the dead-letter branch 3173-3190 |
| `split_alias_host` / `host_acceptable` | `ocaml/relay.ml` | 407-421 |
| RELAY signature (peer-relay API from S1) | `ocaml/relay.ml` | `val add_peer_relay` etc. — added by S1 around 438-440 / 602-604 / 1315-1317 |
| `add_dead_letter` | `ocaml/relay.ml` | 458 (sig), 930 (impl) |
| Ingress signature verify | `ocaml/relay.ml` | `try_verify_ed25519_request` 3920-3968 |
| HTTP client + signing | `ocaml/c2c_relay_connector.ml` | `request` 387-425, `sign_request` 381-385, `post` 427 |
| Body-level Ed25519 sign | `ocaml/relay_signed_ops.ml` | `sign_request` (already used by connector) |
| Identity primitives | `ocaml/relay_identity.ml` / `.mli` | `verify`, `sign`, keypair load/store |
| Relay CLI (where flags live) | `ocaml/cli/c2c.ml` | relay-serve cmd 3450-3565; S1 flags `--peer-relay`, `--peer-relay-pubkey` added here |
| `--relay-name` (defines `self_host`) | `ocaml/cli/c2c.ml` | 3458-3466, resolved 3561-3565 |

**Key invariant:** S2 only mutates one branch of `handle_send` (the
existing dead-letter branch at 3173-3190). It does NOT change the
local-delivery branch at 3192-3215 — keeps blast radius tight.

---

## Slice 2 — forwarder POST (replace dead-letter branch)

### Goal
When `host_acceptable` is false AND `host_opt = Some h` AND
`peer_relay_of relay ~name:h = Some peer`, forward the send to `peer.url`.
Otherwise dead-letter as today (preserves back-compat for any unknown host).

### Files to modify

| File | Edit |
|---|---|
| `ocaml/relay_forwarder.ml` (NEW) | new module — see signatures below |
| `ocaml/relay_forwarder.mli` (NEW) | public surface (forward_send only) |
| `ocaml/relay.ml` 3173-3190 | replace `if not (host_acceptable …)` body with three-way branch (peer found / no peer / no host); call `Relay_forwarder.forward_send` |
| `ocaml/dune` | add `relay_forwarder` to relay lib modules |
| `ocaml/test/test_relay_forwarder.ml` (NEW) | 7 cases below |
| `ocaml/test/dune` | wire new test |

**Do NOT touch:** `c2c_relay_connector.ml`. Reuse `Relay_signed_ops.sign_request`
directly inside the new module. (Connector is the *broker→relay* client; the
forwarder is *relay→relay*. Different identity, different lifecycle. Sharing
code at the `sign_request` level only — not at the `Relay_client.t` level.)

### New module signatures

```ocaml
(* ocaml/relay_forwarder.mli *)
type forward_outcome =
  | Delivered of float            (* peer accepted, ts from peer *)
  | Duplicate of float            (* peer dedup'd; still success *)
  | Peer_unreachable of string    (* connect refused / DNS fail *)
  | Peer_timeout                  (* 5s exceeded *)
  | Peer_5xx of int * string      (* status, body excerpt *)
  | Peer_4xx of int * string      (* propagate dest reason *)
  | Peer_unauthorized             (* 401 — identity not registered on peer *)
  | Local_error of string         (* signing / encoding bug; should never happen *)

val forward_send :
  identity:Relay_identity.t ->
  self_host:string ->
  peer:Relay.peer_relay_t ->
  from_alias:string ->        (* bare alias on origin relay *)
  to_alias:string ->           (* bare alias, host already stripped *)
  content:string ->
  message_id:string ->         (* propagate verbatim for cross-relay dedup *)
  forward_outcome Lwt.t
```

```ocaml
(* internal, in relay_forwarder.ml *)
val build_body :
  self_host:string ->
  from_alias:string ->
  to_alias:string ->
  content:string ->
  message_id:string ->
  Yojson.Safe.t
(* Produces JSON:
   { from_alias: "alice@relay-a"     (* host-tagged *)
   ; to_alias: "bob"                  (* bare *)
   ; content: <verbatim>
   ; message_id: <verbatim>
   ; via: ["relay-a"]
   } *)

val classify_response :
  status:int -> body:string -> forward_outcome
```

### handle_send patch shape (relay.ml ~3173)

```ocaml
let stripped_to_alias, host_opt = split_alias_host to_alias in
let self_host = R.self_host relay in
if host_acceptable ~self_host host_opt then
  (* existing local-delivery branch unchanged *)
  ...
else
  match host_opt with
  | None ->
    (* defensive — host_acceptable handles None when self_host=None *)
    write_dead_letter ~reason:"cross_host_not_implemented" ...
  | Some h ->
    match R.peer_relay_of relay ~name:h with
    | None ->
      write_dead_letter ~reason:"cross_host_not_implemented" ...
    | Some peer ->
      let identity = R.relay_identity relay in   (* NEW accessor, see below *)
      let%lwt outcome =
        Relay_forwarder.forward_send ~identity
          ~self_host:(Option.value self_host ~default:"")
          ~peer
          ~from_alias ~to_alias:stripped_to_alias
          ~content
          ~message_id:(Option.value (get_opt_string body "message_id")
                         ~default:(Uuidm.to_string (Uuidm.v `V4)))
      in
      respond_for_forward_outcome ~relay ~origin_envelope outcome
```

`respond_for_forward_outcome` is a small local helper that maps each
variant to (a) HTTP status for the alice-facing response and (b) a
dead-letter row written via `R.add_dead_letter`. Mapping table:

| outcome | HTTP to alice | dead-letter? | `reason` |
|---|---|---|---|
| `Delivered ts` | 200 `{ ok; ts }` | no | — |
| `Duplicate ts` | 200 `{ ok; ts; duplicate }` | no | — |
| `Peer_unreachable e` | 502 `{ peer_unreachable }` | yes | `peer_unreachable` |
| `Peer_timeout` | 504 `{ peer_timeout }` | yes | `peer_timeout` |
| `Peer_5xx (st, b)` | 502 `{ peer_5xx; st }` | yes | `peer_5xx` |
| `Peer_4xx (st, b)` | 404 (or 422; pass through) | yes | `peer_rejected_<reason-from-body>` |
| `Peer_unauthorized` | 502 | yes | `peer_unauthorized` |
| `Local_error e` | 500 | yes | `forward_local_error` |

All dead-letter rows include `phase: "forward_out"` and
`peer: peer.name` so doctor (S5) can attribute.

### New `R.relay_identity` accessor

Both `InMemoryRelay` and `SqliteRelay` need to surface the relay's own
identity keypair. S1 added persistence (per design §10 Q1, recommended a
separate `relay-server-identity.json` file).

- Add field `identity : Relay_identity.t` to both `t` records.
- Load/generate at `create` time given `~persist_dir`; reuse
  `Relay_identity.load_or_generate` if present, else write a
  ~30-LOC helper in `relay_identity.ml`.
- Expose `val relay_identity : t -> Relay_identity.t` on the RELAY sig.

This adds ~40 LOC across `relay.ml` + `relay_identity.ml`. Counted
against the S2 budget.

### Test cases (`test_relay_forwarder.ml`)

Use `cohttp-lwt-unix` test server stub on a random localhost port to
fake relay-B. No subprocess.

1. **happy path** — POST returns 200 `{ ok; ts }` → outcome `Delivered`.
2. **duplicate** — peer responds 200 `{ duplicate; ts }` → `Duplicate`.
3. **peer 5xx** — server returns 503 → `Peer_5xx (503, _)`.
4. **peer 4xx unknown_alias** — 404 with body
   `{ error: "unknown_alias" }` → `Peer_4xx (404, _)`; reason
   carried to dead-letter.
5. **peer 401** — 401 → `Peer_unauthorized`.
6. **peer unreachable** — point at unbound localhost port → `Peer_unreachable`.
7. **peer timeout** — server sleeps 6s, client timeout 5s → `Peer_timeout`.

Plus 2 cases at the `handle_send` integration layer (using the
in-process two-`Broker.t` pattern from existing tests):

8. **cross-host with peer registered** — alice@A sends to bob@B; B's
   inbox archive contains the message; A's `dead_letter` empty.
9. **cross-host with NO peer registered** — same envelope, but B not
   in A's `peer_relays`; A dead-letters `cross_host_not_implemented`,
   no POST attempted.

### Failure-mode coverage map (per request)

- **relay-B unreachable**: case 6 above + integration assertion that
  alice's HTTP response is 502 and dead-letter row written on A.
- **sig mismatch (relay-A's pk not on relay-B)**: case 5 above
  (`Peer_unauthorized`). The "not registered on peer" check is on
  relay-B's side (S3); from S2's view it's just a 401.
- **replay**: case 2 (`Duplicate`) — message_id reused intentionally
  in the test, peer's existing dedup window catches it. Verify A
  treats `Duplicate` as success (no dead-letter, 200 to alice).

### LoC estimate

| Area | LoC |
|---|---|
| `relay_forwarder.ml` (build_body, classify_response, forward_send) | 120 |
| `relay_forwarder.mli` | 25 |
| `handle_send` patch + helper | 35 |
| `relay_identity` accessor + load_or_generate | 40 |
| `test_relay_forwarder.ml` | 250 (more than module — that's fine) |
| dune wiring | 6 |
| **Total non-test** | **~226** |

Slightly over the 200-LOC slice norm but coherent — cutting it would
mean splitting accessor from forwarder which is artificial.

### Risks

1. **Lwt timeout primitive choice.** Use `Lwt_unix.with_timeout`. Subtle:
   it raises `Lwt_unix.Timeout`, which must be caught in the same
   try/catch as the `Cohttp_lwt_unix.Client.call` exception. Mis-shape
   leaks an unhandled exception into the request handler.
2. **Cohttp connect-refused exception type.** Different on Linux vs
   macOS (`Unix.ECONNREFUSED` vs `Failure`). Test 6 must be
   platform-tolerant; classify on `Printexc.to_string` substring match
   as fallback.
3. **Body double-serialise risk.** `Yojson.Safe.to_string` then
   `Cohttp_lwt.Body.of_string` — mind that `sign_request` signs the
   *exact* body bytes; the sig must be computed from the same string
   that goes on the wire (no pretty-printer between sign and send).
4. **`message_id` propagation.** S1 already accepts a client-provided
   `message_id`; the forwarder generates one only when absent. Verify
   the alice→A path doesn't fabricate one *before* this branch (audit
   `handle_send` ~3195 — it only consults `message_id` in the local
   branch today).

### Parallel-safety
S2 is **NOT** parallel-safe with S3 — they share the new module file
and the wire format must agree. S2 must land first. Run S3 in the same
worktree on top.

---

## Slice 3 — ingress via-cap + relay-pk verification

### Goal
On the receiving relay (B), recognise that an incoming `/send` is a
forwarded message (signer pk is in `peer_relays`), enforce loop-cap on
`via`, and *only then* allow `from_alias` to carry an `@host` suffix.
Regular clients still rejected if `from_alias` contains `@`.

### Files to modify

| File | Edit |
|---|---|
| `ocaml/relay.ml` `handle_send` 3163 | wrap in pre-check that classifies request as "from peer relay" vs "from regular client" |
| `ocaml/relay.ml` `try_verify_ed25519_request` 3920 | add a parallel return shape: `Ok (Some_peer_relay { name; pk })` so callers know the signer is a peer relay rather than an aliased client |
| `ocaml/relay_forwarder.ml` | add `verify_inbound : peer_relays:peer_relay_t list -> body:Yojson.Safe.t -> (unit, string) result` enforcing via-cap + from_alias shape |
| `ocaml/test/test_relay_forwarder.ml` | extend with ingress test cases below |

### Verification logic

```
(1) classify signer:
    let signer_pk = pk extracted from Authorization Ed25519 header
    let signer_kind =
      match peer_relay_of_pk relay ~pk:signer_pk with
      | Some pr -> `Peer pr            (* relay-A acting as forwarder *)
      | None    ->
        match identity_pk_of_alias relay ~alias:claimed_alias with
        | Some pk' when pk' = signer_pk -> `Client claimed_alias
        | _ -> `Unknown

(2) for `Peer pr`:
    - parse `via` from body. Default [].
    - if List.length via > 1 → 422 + dead_letter loop_detected
      (phase=ingress, peer=pr.name)
    - if from_alias does NOT contain @ → 400 (peer must tag origin)
    - bypass the verified_alias = from_alias check (not a regular client)
    - call R.send with stripped_to_alias and host-tagged from_alias
      preserved verbatim into the recipient's inbox

(3) for `Client a`:
    - existing path; reject if from_alias contains @ (regular clients
      have no business sending host-tagged from_alias)

(4) for `Unknown`:
    - existing reject_alias_mismatch path
```

### New helper: `peer_relay_of_pk`

S1 added by-name lookup; ingress needs by-pk. Extend RELAY:

```ocaml
val peer_relay_of_pk : t -> pk:string -> peer_relay_t option
```

V1 implementation: linear scan over `peer_relays_list` (≤10 peers; not
worth a second Hashtbl per design §10 Q3). ~10 LOC per relay impl.

### Test cases (extend `test_relay_forwarder.ml`)

10. **valid peer ingress** — relay-B receives signed POST from registered
    peer relay-A; `from_alias = "alice@relay-a"`, `via = ["relay-a"]`;
    accepted, bob's inbox contains the envelope.
11. **via-cap exceeded** — same shape but `via = ["relay-a"; "relay-c"]`;
    422 + dead-letter `loop_detected` on B.
12. **unknown peer signer** — well-formed Ed25519 sig from an *unregistered*
    relay's identity; falls through to `Client` path; rejected because
    no alias-binding for that pk → 401.
13. **client tries host-tagged from_alias** — alice (regular client)
    sends `from_alias = "alice@somehost"`; rejected 400.
14. **peer omits via** — peer signs but body has no `via` field; treat
    as `[]` then prepend self → after S2 cap check this is
    `via.length = 1` after S2's prepend, fine; S3 just reads. **Note:**
    S2 *prepends* on outbound and S3 *reads* on inbound — both are
    needed; cross-check via lengths against the cap.

### Failure modes (request)

- **relay-B unreachable**: not in S3's scope (that's S2's concern). S3
  is the receiver side.
- **sig mismatch**: case 12 covers unknown signer. Add case 12b:
  registered peer's pk + tampered sig → existing
  `try_verify_ed25519_request` returns `Error _` → 401, no S3 logic
  reached. Verify by sending a body where one byte of `content` was
  flipped after signing.
- **replay**: existing `R.check_request_nonce` handles request-level
  replay (already in `try_verify_ed25519_request`). Cross-relay
  envelope replay (same `message_id`) is caught by `R.send`'s existing
  dedup window — peer sees `Duplicate ts` and returns 200 (test case 2
  already covers the A side). Add an ingress test 15: same
  `message_id` posted twice to B in 1s → both return 200, only one
  envelope appended to bob's archive.

### LoC estimate

| Area | LoC |
|---|---|
| `peer_relay_of_pk` (sig + 2 impls) | 12 |
| `try_verify_ed25519_request` shape change + callsites | 25 |
| `handle_send` ingress pre-check | 50 |
| `Relay_forwarder.verify_inbound` + via parser | 35 |
| Test extensions | 200 |
| **Total non-test** | **~122** |

### Risks

1. **`try_verify_ed25519_request` shape change is invasive.** It
   currently returns `Ok (string option)`. Changing to a sum type
   touches every caller. Lower-blast option: add a *second* function
   `try_verify_peer_relay_request` that runs first and only returns
   `Some peer` on a peer-pk match; on `None` fall through to the
   existing function. Recommended path. Saves ~15 LOC of churn.
2. **Auth header parses pk indirectly.** The Ed25519 header carries
   `alias` and `sig`, not pk. The relay looks up pk via
   `R.identity_pk_of relay ~alias`. For peer relays the "alias" is the
   peer's `--relay-name` (e.g. `relay-a`). v1: peer relays MUST be
   pre-registered as aliased identities on the receiving relay (the
   operator imports the pk via the existing `--allowed-identities`
   mechanism, OR via a startup-time `register` from the peer). Document
   in S6 runbook. Alternative: skip alias indirection and let the
   header carry pk directly for peer relays — adds wire-format
   complexity, defer.
3. **`from_alias` carrying `@host` into recipient archive.** Today's
   broker treats `from_alias` as a flat string — no consumer parses it.
   Verify nothing downstream (notifications, room fan-out) chokes. Add
   a smoke test that `c2c poll-inbox` for bob renders
   `alice@relay-a` as the sender label without crashing.

### Parallel-safety
S3 sits on top of S2 in the **same worktree**. They could in principle
be split between agents (S2 = sender side, S3 = receiver side) but they
must agree on:
- envelope shape (`from_alias`, `via`, `message_id` keys)
- error reasons (`peer_unauthorized`, `loop_detected`)
- HTTP status mapping
…and **exchanging that contract by DM is more friction than running
both in one worktree.** Recommend single-agent S2→S3 sequential.

---

## Slice 4 — docker probe + integration test

### Goal
End-to-end proof in containers: alice's broker on host-A sends to
bob@host-B and the message lands in bob's inbox in <5s.

### Files to add

| File | Purpose |
|---|---|
| `docker-tests/test_relay_mesh_probe.py` (NEW) | pytest, single AC test |
| `docker-tests/conftest.py` | extend if it exists; fixtures for two-relay compose |
| `docker-compose.relay-mesh.yml` (NEW or under `.worktrees/330-relay-mesh/`) | two relay services + two broker services |
| `docker-tests/Dockerfile.relay-mesh` (NEW) | minimal relay image (probably reuses the existing relay Dockerfile) |
| `Justfile` / `justfile` | recipe `just test-relay-mesh` |

**Cross-ref:** the validation companion
`.collab/research/2026-04-29-330-relay-mesh-validation-plan-cairn.md`
already specifies docker-compose budgets (≤600 MB RSS) and lists
test fixture conventions. S4 follows that contract.

### Compose shape (sketch)

```yaml
services:
  relay-a:
    image: c2c-relay
    command: >
      c2c relay serve --listen 0.0.0.0:7331
      --relay-name relay-a
      --peer-relay relay-b=http://relay-b:7331
      --peer-relay-pubkey relay-b=${RELAY_B_PK}
      --persist-dir /data
    volumes: [ "./fixtures/relay-a:/data" ]
    ports: [ "7331:7331" ]
  relay-b:
    image: c2c-relay
    command: >
      c2c relay serve --listen 0.0.0.0:7331
      --relay-name relay-b
      --peer-relay relay-a=http://relay-a:7331
      --peer-relay-pubkey relay-a=${RELAY_A_PK}
      --persist-dir /data
    volumes: [ "./fixtures/relay-b:/data" ]
    ports: [ "7341:7331" ]
  broker-alice:
    # connector pointed at relay-a, registered alias=alice
    ...
  broker-bob:
    # connector pointed at relay-b, registered alias=bob
    ...
```

The pre-shared pubkeys are baked into fixtures by a one-time
`c2c relay generate-identity --out fixtures/relay-{a,b}/relay-server-identity.json`
step that runs in test setup. See S2 risk #1 for the
load-or-generate plumbing.

### Test cases

1. **happy round-trip** — alice → bob@relay-b; assert `bob` receives
   in <5s; `from_alias` reads `alice@relay-a`.
2. **reverse path** — bob → alice@relay-a; symmetric assertion.
3. **peer-down behaviour** — `docker compose stop relay-b`; alice sends;
   broker sees the dead-letter row on relay-A; alice's CLI returns
   non-zero with `peer_unreachable`.
4. **peer-recovery manual replay** — restart relay-b; operator runs
   `c2c send` again with the same content; message arrives. (Confirms
   the v1 manual-replay model — we are NOT testing auto-replay.)
5. **loop prevention** — synthetic test: forge a forwarded request
   from relay-A to relay-B with `via: ["relay-a", "relay-c"]`;
   relay-B returns 422 and dead-letters `loop_detected`. Run via
   raw `curl` + signed body — bypass the relay-A side because we
   need to prove the cap at the receiver alone.

### LoC estimate

| Area | LoC |
|---|---|
| compose + Dockerfile | 80 |
| pytest fixtures | 60 |
| test_relay_mesh_probe.py (5 cases) | 200 |
| just recipe + CI wiring | 15 |
| **Total** | **~355** |

Larger than 200 LOC norm — but most of it is yaml + fixtures, not
production code. Acceptable for an integration slice. If trimming is
required, drop cases 4 + 5 (manual replay; loop) into a "S4b" follow-up.

### Risks

1. **Container startup race.** alice's broker may try to send before
   relay-A's HTTP listener is up. Use `depends_on` + a `healthcheck`
   on `/health` endpoint (already exists per the existing relay
   compose). Pattern from `docker-tests/conftest.py`.
2. **Pubkey injection at boot.** Generating the identity file *inside*
   the container at boot makes the value unknown to the *other*
   container's flag. Two options:
   (a) generate keypairs in test setup *outside* docker, mount as
       `/data/relay-server-identity.json`. Recommended.
   (b) two-phase compose — boot once to capture pks, write to
       `.env`, restart with `--peer-relay-pubkey`. More fragile.
3. **TLS noise.** The probe runs over plain HTTP inside the docker
   network. Production deploys terminate TLS at a reverse proxy. Not
   a v1 test concern but document in S6 runbook.
4. **GitHub Actions resource budget.** A two-relay compose in CI may
   exceed the validation doc's RSS budget if SQLite warms up
   surprisingly. Baseline measurement on first run; if over budget,
   force `--storage memory` for the test.

### Parallel-safety
S4 can be **drafted** in parallel with S2/S3 (compose + fixtures don't
depend on the wire-format details). The test cases assert behaviour
that S2+S3 implement, so green-running requires S2+S3 landed.
Recommend: dispatch S4-draft to a second agent at the same time S2
starts, with the agreement that "test bodies may stub out the
assertion until S2+S3 land."

---

## Recommended ordering + parallel-safety summary

```
S1 (galaxy, in respin) ───┐
                          │ FAIL→PASS gate
S2 forwarder POST ────────┘──┐
                             │ same worktree
S3 ingress verify ───────────┘──┐
                                │ separate worktree
S4 docker probe ────────────────┘
                                │
S5 doctor relay-mesh + S6 docs ─┘ (per design §9; out of this plan's scope)
```

**Parallel-safety pairs**

| Pair | Safe in parallel? | Why |
|---|---|---|
| S2 + S3 | NO | Same module, agreeing on wire format |
| S2 + S4-draft | YES | Test fixtures don't depend on wire details |
| S3 + S4-draft | YES | Same as above |
| S2/S3 + docs (S6 stubs) | YES | Doc author can read the design doc |

**Recommended dispatch**

- One agent (likely galaxy continuing): S1 FAIL respin → S2 → S3 in
  `.worktrees/forwarder-s1-identity/` (or a renamed `.worktrees/330-forwarder-core/`).
- A second agent in parallel: drafts S4 compose + test scaffolding in
  `.worktrees/330-forwarder-probe/`. Holds on green-running until S2+S3
  signed-PASS.
- coord-PASS gates push.

---

## Cross-cutting risks (apply across S2-S4)

1. **Dead-letter `phase` field is a NEW envelope key.** Today's
   dead-letter rows have `{ts, message_id, from_alias, to_alias,
   content, reason}`. Adding `phase` and `peer` is back-compat (extra
   fields), but doctor (S5) must tolerate their absence on rows from
   pre-forwarder relays. Codify in S2 by having `add_dead_letter`
   accept an optional `~phase` arg that defaults to omitting the field.
2. **`message_id` UUID generation point.** Currently generated lazily
   inside `R.send` if absent. The forwarder MUST generate it earlier
   (before the POST) so the same id reaches both relays for dedup.
   S2 must ensure that path generates exactly once and passes
   verbatim.
3. **Identity persistence + key rotation.** Out of scope for v1 per
   design §10 Q6, but the file path
   `<persist_dir>/relay-server-identity.json` should be documented in
   the S6 runbook so operators don't lose the trust anchor on volume
   wipe.
4. **CI cost.** S4's docker-compose adds ~3 min to CI (two relay boots
   + 5 test cases). Tag with `@pytest.mark.docker_mesh` and gate
   behind a `just test-relay-mesh` target — don't run on every PR.

---

## Open questions for galaxy / coord

1. Should the `relay_identity` accessor be added in S1's respin
   (current FAIL fix) or in S2? It's a small amount of code; if galaxy
   is already touching `Relay.t` to fix S1, folding it in saves a
   second touch. Recommend: add to S1 respin.
2. The S3 risk #1 mitigation — adding a parallel
   `try_verify_peer_relay_request` rather than reshaping the existing
   verifier — needs a 30-second sanity check from a reviewer before S3
   commits. Worth a DM to lyra/stanza.
3. S4's compose: do we put it in repo root (visible) or under
   `docker-tests/` (hidden, test-only)? Existing pattern leans
   `docker-tests/` per the validation plan. Confirm.
4. Should S2's outcome enum carry the dead-letter `reason` string
   directly (avoid mapping at the call site), or keep mapping in
   `respond_for_forward_outcome`? Current plan: map at call site so
   the enum stays HTTP-agnostic. Either is fine; flag for review.

---

## Appendix — file change inventory

| Slice | Touch | New |
|---|---|---|
| S2 | `ocaml/relay.ml` (3163-3215, plus identity field), `ocaml/dune`, `ocaml/test/dune` | `ocaml/relay_forwarder.ml`, `.mli`, `ocaml/test/test_relay_forwarder.ml` |
| S3 | `ocaml/relay.ml` (3163, 3920), `ocaml/relay_forwarder.ml` | extends `test_relay_forwarder.ml` |
| S4 | `Justfile` | `docker-compose.relay-mesh.yml`, `docker-tests/test_relay_mesh_probe.py`, `docker-tests/Dockerfile.relay-mesh`, fixtures dir |

**End of plan.** Total target LOC across S2+S3+S4 (non-test, non-yaml):
~350. Within slice-budget norms. S5 + S6 follow per the design doc.
