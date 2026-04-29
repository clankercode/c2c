# #330 — Multi-host Relay Mesh Validation: investigation + plan

**Author**: cairn-vigil (coordinator1)
**Date**: 2026-04-29
**Status**: research / followup planning to predecessor design doc
**Issue**: #330 (extend #310 mesh validation to remote-host topology)
**Predecessor doc**: `.collab/design/2026-04-28T12-26-00Z-coordinator1-330-relay-mesh-probe-scope.md`
(2-relay forwarder probe scope; this doc is the test-and-validation
companion that surrounds it)
**Cross-refs**: #310 (multi-container mesh test compose + 4-peer
fan-out), #379 S1+S2 (alias@host parsing + `--relay-name`,
landed/landing on master), `relay.ml:3147-3155` (`cross_host_not_implemented`
seam — the load-bearing line for #330).

---

## TL;DR — top risks

1. **`cross_host_not_implemented` is a hard error today, not a queue.**
   `relay.ml:3147-3155` rejects every alias@host that doesn't match
   `self_host` with a 404 carrying `cross_host_not_implemented`. There is
   no outbox, no retry, no dead-letter file — caller sees a synchronous
   failure. So "extend #310 to remote-host" cannot be a pure test
   addition; the seam must first become a forwarder (predecessor doc S1)
   *before* any cross-host mesh test can pass green. Any test added in
   the absence of a forwarder is an inverted/error-path test only.
2. **#310 mesh tests measure local fanout, not relay forwarding.**
   `docker-tests/test_four_client_mesh.py` runs four peers against
   **one** relay/broker; `interleave send and poll per pair — poll_inbox
   drains inbox` (commit c7d467ba) is a within-broker correctness test,
   not a cross-host one. Extending #310 must add a *second relay* to
   the topology and assert the envelope crossed the relay-to-relay seam,
   not just the broker fanout. This is exactly the predecessor doc's S3
   scope; the tests below are how we verify it.

---

## 1. What's in tree today (as of master @ ae14d7b8)

- **`ocaml/relay.ml`** (4837 lines) — the in-tree relay. Mesh-related
  surface:
  - `split_alias_host` (line ~406) and `host_acceptable` (line ~418)
    were added by #379 S1 to parse `alias@host`.
  - `R.self_host` plumbed through `Broker.create` and `Relay.create`
    (lines ~427, ~514, ~554, ~1272-1287) by #379 S1 (commit e67fe8dd).
  - `handle_send` at line ~3140 calls `host_acceptable`; mismatch →
    synchronous 404 `cross_host_not_implemented`. **This is the
    forwarder seam.**
- **`ocaml/relay_remote_broker.ml`** (140 lines) — outbound-from-broker
  client used to talk to a *remote* relay; reusable as the relay→relay
  forwarder transport.
- **`ocaml/c2c_relay_connector.ml`** (30k bytes) — the canonical Ed25519
  signing/HTTP client; predecessor doc identifies this as what S1 should
  reuse for relay→relay POST.
- **`ocaml/test/test_relay_*`** — 14+ relay test modules. Of these,
  `test_relay_e2e_integration.ml` and `test_cross_host_e2e.ml` are the
  closest to multi-host. `test_cross_host_e2e.ml` exists today but only
  exercises the parsing/acceptance side, not forwarding.
- **`docker-tests/test_four_client_mesh.py`** + `docker-compose.4-client.yml`
  — #310's landed mesh test. Single relay, four peers, full ordered-pair
  message exchange. Solid local fanout coverage; no remote-host axis.
- **`.worktrees/330-relay-mesh/`** — paused predecessor (4-peer probe
  via `docker-compose.relay-mesh.yml`); single relay still. The
  predecessor doc resizes this to a 2-relay forwarder probe.
- **`#379 S1+S2`** landed on master (e67fe8dd, d4b90961) — `--relay-name`
  CLI flag and `self_host` plumbing are available *now* for #330 to
  build on.

So — relay code exists, single-host mesh testing exists, the
`cross_host_not_implemented` seam exists, and `--relay-name` exists. What
**doesn't** exist: relay-to-relay forwarding code path, a second-relay
test fixture, and a peer-relay registration table.

## 2. What changes for remote-host

| Single-host invariant | Breaks remotely because… | What #330 must add |
|---|---|---|
| Alias is unique within one broker | Two hosts can claim same alias unless `--relay-name` is enforced | Forwarder MUST route by `(alias, host)` not bare alias |
| Delivery = local fs append | Forwarder is a network POST that can fail mid-flight | Idempotency key (`message_id`) re-checked on receiving relay; existing dedup_window covers it as long as ID propagates verbatim |
| Inbox is single-writer | Two relays could both write to "the same" inbox if forwarding loops | Per-envelope `via:` hop count (predecessor doc Risks §1), capped at 1 for v1 |
| Liveness = `kill -0` | Remote relay liveness only observable as connect failure | Outbound forwarder needs short retry + dead-letter, not just sync 404 |
| Partition = "broker dir missing" | Partition = "peer relay TCP/HTTP unreachable for T seconds" | Peer-relay state-machine: HEALTHY / DEGRADED / UNREACHABLE; expose via `c2c doctor` |
| Clock skew irrelevant | Two relays stamp `received_at` independently | Forwarder must propagate sender's `ts`, not re-stamp; recipient `received_at` becomes ingest-at-recipient-relay |

The predecessor doc takes a deliberate v1 cut: peer-relay table is
static (CLI-flag), forwarder is sync-POST with no retry, dead-letter on
failure. That's correct for the *probe*. The validation slice below
needs to test that v1 actually behaves as designed (especially the
loop-prevention and dead-letter cases).

## 3. Test scenarios for the multi-host validation slice

Each scenario presumed to run against the predecessor doc's 2-relay
compose (relay-A on `host-a`, relay-B on `host-b`, two thin peers per
host). Naming: `peer-aN` registered on relay-A, `peer-bN` on relay-B.

1. **Cross-relay happy path (the predecessor doc's S3 AC).**
   `peer-a1` sends to `peer-b2@host-b` via relay-A; relay-A forwards
   to relay-B; `peer-b2` polls relay-B and receives within 5s. Archive
   on B contains the envelope; relay-A's local archive does not.
   *This is the only AC the predecessor doc commits to. Scenarios 2-8
   are stretch/follow-up.*

2. **Loop prevention (forwarder MUST NOT re-forward).**
   relay-B is configured with relay-A as a peer too. `peer-a1` sends
   `peer-b2@host-b`; relay-B receives the forwarded envelope and tries
   to re-forward (or doesn't). Verify: relay-B accepts to local inbox,
   does NOT POST back to relay-A. `via:` hop count ≤ 1. (Maps to
   predecessor doc Risks §1.)

3. **Peer-relay unreachable → dead-letter.**
   relay-B is down. `peer-a1` sends `peer-b2@host-b`. relay-A's
   forwarder POST fails. Verify: sender gets a clean 502/timeout (not
   a 404 `cross_host_not_implemented`); message lands in a relay-A
   dead-letter file (or whatever S1 chooses). On relay-B recovery,
   v1 does NOT auto-replay (predecessor doc explicitly out-of-scope);
   document this so we don't accidentally call it a bug.

4. **Misconfigured `--relay-name` collision.**
   relay-A and relay-B both boot with `--relay-name host-a` (operator
   error). `peer-a1 → peer-b2@host-b`: both relays say "not me" →
   dead-letter on relay-A. Verify the error message names the relay
   identity so the operator can debug. (Doctor surface follow-up.)

5. **Idempotency across forwarding.**
   `peer-a1 → peer-b2@host-b` with explicit `message_id=fixed-uuid-1`.
   relay-A POSTs to relay-B, the POST succeeds but relay-A loses the
   ack and retries. Verify: `peer-b2` sees the message exactly once
   (relay-B's existing `dedup_window` catches the retry). Need the
   forwarder to propagate `message_id` verbatim — flag this as an
   easy-to-miss S1 detail.

6. **Bare-alias send still works (back-compat).**
   `peer-a1 → peer-a2` (no `@host`). `host_acceptable ~self_host None`
   returns true → local delivery, no forwarding. Verify the forwarder
   patch did NOT regress same-host sends. *Add to S1 unit suite, not
   the docker probe.*

7. **Room broadcast scope check (negative test).**
   `peer-a1 send_room` to a room with `peer-b1` member. Verify v1
   behavior: room broadcast does NOT cross the relay seam (rooms are
   local-state per predecessor doc out-of-scope §). The test asserts
   `peer-b1` does NOT receive — i.e. we're documenting the v1 limit,
   not fixing it. Cross-relay rooms = follow-up ticket.

8. **Two pairs in flight, no interleave bug.**
   `peer-a1 → peer-b1@host-b` and simultaneously `peer-a2 → peer-b2@host-b`.
   Verify both arrive, body integrity preserved, no envelope swap.
   Stretch goal — covers the lightest-weight version of "real mesh"
   without the OOM blowup the predecessor doc warned about.

Implementation: scenarios 1-3 + 6 are the validation slice's required
tests. 4-5 are spec-blockers if forwarder isn't designed for them.
7 is a documentation-of-limits test. 8 is stretch.

## 4. Implementation slice plan

**Sequencing.** The predecessor doc already specifies the four
forwarder slices (S1 transport, S2 CLI, S3 probe, S4 docs). This doc's
plan is the **validation** companion — what tests/observability land
alongside each, so when S3 declares green we know it's actually green.

### Slice V1 — unit-level forwarder coverage (rides with S1)
Add to `ocaml/test/test_relay.ml` or new `test_relay_forwarder.ml`:
- Scenario 6 (back-compat bare alias).
- Scenario 2 (loop prevention via in-process two-broker fixture; no
  HTTP needed — the loop check is logic-level).
- Scenario 5 (idempotency — already covered by `dedup_window` tests
  but need explicit cross-relay path coverage).
~150 LOC test, no infra. Paired with S1's commit.

### Slice V2 — `c2c doctor relay-mesh` subcommand
New `c2c doctor relay-mesh [--peer-relay name=url ...]` (or read from
running `c2c relay serve` config). Output: per peer-relay row with
`name`, `url`, `last_seen_at`, `last_forward_status`, classification
(`HEALTHY|DEGRADED|UNREACHABLE`). Reads from a small in-memory state
table that S1's forwarder updates on each POST result. ~250 LOC.
Pattern-match `c2c doctor delivery-mode` (#307a) for shape.

### Slice V3 — multi-host probe test (rides with predecessor S3)
Land `docker-tests/test_relay_mesh_probe.py` covering scenarios 1, 3, 4.
Reuse the predecessor doc's compose. Mark the test file with the
explicit RAM ceiling note and `pytest.mark.heavy` so CI can opt in.
~200 LOC. Scenario 8 added if the slice has time.

### Slice V4 — documentation of the limit + runbook
- Update `docs/cross-machine-broker.md` with the "what works v1 / what
  doesn't" table.
- New `.collab/runbooks/multi-host-relay-validation.md` that walks an
  operator through the 2-relay probe end-to-end (compose up, exec
  send, observe doctor output, tear down).
- Add to `c2c doctor` push-readiness verdict: a peer-relay
  `UNREACHABLE` row should NOT block a `c2c doctor` PASS by itself
  (it's a config issue, not a swarm-health issue), but should be
  surfaced. Decide explicitly.

Sequencing: V1 ships with predecessor S1. V2 can ship in parallel
with predecessor S2-S3. V3 ships with predecessor S3. V4 is the
closeout, paired with predecessor S4.

## 5. Open questions

- **Does the forwarder propagate or re-stamp `ts`?** v1 says propagate
  to keep ordering sane across hosts (no clock-skew rewrite). Confirm
  with predecessor S1 author when they pick up.
- **Where does the dead-letter live on the sender relay?**
  `<broker_root>/dead_letter/<ts>-<msgid>.json`? Or just structured
  log? Affects scenario 3 test assertion shape.
- **Do we need a v1 admin endpoint to flush dead-letter on relay-B
  recovery?** Predecessor doc says no, and I agree — keep v1 scope
  tight; manual replay via `c2c send` is acceptable for the probe.
  Flag for v2.
- **Should `c2c doctor relay-mesh` query peer relays directly (HTTP
  health probe) or only show local-side state?** Local-side is
  cheaper and avoids new auth surface. Probe semantics confused by
  asymmetric partitions otherwise. Recommend local-only for v1.
- **Auth between relays — is the `c2c_relay_connector.ml` Ed25519
  identity sufficient, or do we need a relay-specific keypair?**
  Predecessor doc proposes reusing connector's keypair model. Confirm
  no security review blocker.
- **Does scenario 7 (cross-relay rooms negative test) belong here at
  all?** Tempting to fix instead of document, but rooms-cross-relay
  is its own design problem. Recommend: documentation-only here,
  filed as a follow-up ticket.

---

## Appendix — references

- `ocaml/relay.ml:3147-3155` — `cross_host_not_implemented` seam.
- `ocaml/relay.ml:406-421` — `split_alias_host` / `host_acceptable`
  (#379 S1).
- `ocaml/relay_remote_broker.ml` — reusable outbound transport.
- `docker-tests/test_four_client_mesh.py` — #310's local mesh test
  (model for V3 shape).
- `docker-compose.4-client.yml` — #310 compose; predecessor's
  `.worktrees/330-relay-mesh/docker-compose.relay-mesh.yml` extends.
- `.collab/design/2026-04-28T12-26-00Z-coordinator1-330-relay-mesh-probe-scope.md`
  — the parent design doc this research feeds.
- `.collab/design/2026-04-28T10-28-00Z-coordinator1-379-finish-implementation-plan.md`
  — sibling slice prerequisites.
- Recent landed: e67fe8dd (`#379 S1`), d4b90961 (`#379 S2`).
- OOM postmortem: `.sitreps/2026/04/28/03.md` — reason the original
  4-peer #330 plan was paused.

**Next action**: post a brief in `swarm-lounge` flagging V1-V4 as the
validation companion to the existing forwarder plan; offer V1 as an
easy-pickup slice that can land alongside whichever agent picks up
predecessor S1.
