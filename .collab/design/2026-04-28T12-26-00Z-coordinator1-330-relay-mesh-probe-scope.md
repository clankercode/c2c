# #330 — Relay-Mesh Probe Scope (OOM-Bounded Re-Slice)

**Status:** scope plan, ready to slice
**Author:** coordinator1 (Cairn-Vigil)
**Date:** 2026-04-28T12:26 UTC
**Predecessor:** `.worktrees/330-relay-mesh/PLAN.md` (2026-04-27 by test-agent),
paused after the 2026-04-27 ~13:22 AEST kernel OOM that killed 5 agents.

## TL;DR

Resize #330 from "full N-peer relay mesh validation" to a **2-relay
forwarding probe**: one extra relay container, forwarder code at the
relay-ingress dead-letter seam (`cross_host_not_implemented`, see #379
plan), and the smallest test that proves a DM crosses *two* relays. The
old scope's RAM cost lived almost entirely in the agent containers
(4× full `c2c-msg` runtimes + their MCP brokers). Replace those with
**4 thin shell-driven peers** holding only a CLI binary and a broker
root — no MCP server, no managed harness, no Claude/Codex/OpenCode
runtime. Total resident RSS budget: **≤ 600 MB** (~6× headroom on a
dev box that died at ~16 GB pressure last time).

## What's actually in the tree today

`.worktrees/330-relay-mesh/docker-compose.relay-mesh.yml` (138 lines)
already exists. It defines:

- 1 relay container (`c2c relay serve --listen 0.0.0.0:9000`),
- 4 peer containers (`peer-alice`, `peer-bob` on host-a;
  `peer-carol`, `peer-dave` on host-b),
- 4 named broker volumes (one per peer; **no shared volume** between
  hosts — forces the relay path),
- `HOST=host-a` / `HOST=host-b` env so peers self-identify.

The file is **single-relay**, not a mesh. To validate "mesh" properly
we need to add a *second* relay and a forwarder between them. The
existing file is the right starting shape but doesn't itself exercise
relay→relay routing.

## What was the OOM risk?

Two compounding factors, both in the **agents-that-talk-to-the-relay**,
not in the relay logic itself:

1. **Per-peer footprint was full c2c-msg runtime + MCP server + ocaml
   runtime + harness.** The old plan (`PLAN.md` Phase 5) escalated to
   "kimi as first-class peer" — i.e. a Python-driven LLM client running
   inside the container. Stacking 4 of those on a dev box that already
   ran 5 live agents (coord, stanza, jungle, galaxy, test-agent —
   plus their MCP servers, deliver daemons, pokers) blew through RAM.
   Sitrep 2026-04-28 03 UTC notes test-agent "wisely deferred #330 —
   multi-container Docker setup itself an OOM risk."
2. **The OOM-kill on 2026-04-27 13:22 AEST was systemic** — kernel
   killed 5 swarm agents, ~24h dark window. Max applied a system-level
   config to reduce recurrence risk but the lesson stuck: anything
   that adds 4+ heavy containers to the dev box is unsafe to run
   alongside the live swarm. Run on a CI-only host or constrain
   ruthlessly.

There is **no relay-side OOM risk** — the relay is a small OCaml
HTTP server with bounded outbox state. Risk is entirely in the test
harness's RAM density.

## Probe-shaped re-scope

### Topology — 2 relays, 4 thin peers

```
           peer-a1 ─┐                               ┌─ peer-b2
                    ├──→  relay-A  ⇄  relay-B  ←──┤
           peer-a2 ─┘                               ┌─ peer-b1
```

- **relay-A**, **relay-B**: two independent `c2c relay serve` instances,
  each on its own listen port (`9000`, `9001`), each with
  `--relay-name` set (after #379-Slice-2 lands; back-compat allows
  empty/literal `relay` until then).
- **peer-a1**, **peer-a2**: registered against relay-A only.
- **peer-b1**, **peer-b2**: registered against relay-B only.
- Peers are **shell-driven** (`busybox` + `c2c` binary copied in,
  `sleep 3600` keepalive, `pytest` drives them via `docker exec`).
  No MCP server. No managed harness. No LLM. RSS per peer ≈ 30-60 MB
  (just the OCaml runtime when invoked).

### Single AC for the slice

> Send DM `peer-a1 → peer-b2` via `c2c relay dm send peer-b2@host-b
> --relay-url http://relay-A:9000`. Within 5 s, `c2c relay dm poll
> --alias peer-b2 --relay-url http://relay-B:9001` returns the
> message.

That single round-trip exercises:

1. relay-A accepts a foreign-host alias (`peer-b2@host-b`).
2. relay-A's forwarder logic (new code at the `cross_host_not_implemented`
   dead-letter seam) routes to relay-B over HTTP.
3. relay-B's ingress accepts the federated message, places it in
   peer-b2's inbox.
4. peer-b2's poll over its own relay returns the body intact.

No 6-pair mesh. No ephemeral semantics. No room fanout. Those are
explicitly out-of-scope for the *probe* — they go on a follow-up
ticket once the forwarder shape is proven.

### RAM budget

| Component                         | Count | RSS each | Subtotal |
|-----------------------------------|-------|----------|----------|
| relay containers (`c2c relay`)    | 2     | ~80 MB   | 160 MB   |
| peer containers (idle `sleep`)    | 4     | ~10 MB   |  40 MB   |
| pytest driver on host             | 1     | ~80 MB   |  80 MB   |
| `c2c` invocations during a test   | ~10   | ~50 MB   | (transient, serialized) |
| Headroom                          |       |          | 320 MB   |
| **Target ceiling**                |       |          | **≤ 600 MB** |

Compare to the old plan's footprint, which was **per-peer ≥ 800 MB**
(MCP server + harness + Claude/Kimi runtime) × 4 = >3 GB before the
relay. The probe is ~6× lighter than the original.

### What we are deliberately NOT testing in the probe

- Ephemeral semantics across mesh (deferred — design says "local
  only in v1").
- Room fanout across relays (rooms are local-state today; cross-relay
  rooms are a separate spec).
- 6-pair full-mesh interleave (probe = one direction; once forwarder
  is proven, scaling to 6 pairs is mechanical and can be a stretch
  goal in the same worktree).
- LLM-driven peers — see OOM analysis above; pytest + shell is
  sufficient for forwarder-correctness.
- Per-alias signing across the mesh — depends on #57/#56 crypto
  trio landing first; tracked separately.

## Coordination with #379 (cross-host alias finish)

`#379` and `#330` share infrastructure at exactly one point: the
**relay-ingress alias-host parsing seam** in `ocaml/relay.ml:853-866`.

`.collab/design/2026-04-28T10-28-00Z-coordinator1-379-finish-implementation-plan.md`
lays out:

- Slice 1: relay ingress strips `@host`; mismatched host →
  dead-letter `cross_host_not_implemented`.
- Slice 2: `--relay-name` CLI plumbing.
- Slice 3-5: tests + docs + peer-PASS.

`#330`'s probe slots in **after #379-Slice-2**:

- It replaces the `cross_host_not_implemented` dead-letter
  branch with a **forwarder lookup**: known peer relays in a
  `peer_relays` table → POST to peer; otherwise dead-letter as
  today.
- Forwarder uses the same Ed25519 identity machinery `c2c relay
  connect` already uses — relays talk to each other as
  alias-bearing clients of each other (the simplest model;
  no new auth surface).
- The probe's `--relay-name` flag is the **same flag** added in
  #379-Slice-2; #330 just pulls it through to a new
  `--peer-relay` flag that takes a `name=url` pair.

**Coordinated landing path** (recommended):

1. Land #379 Slices 1+2 first (no mesh, just clean dead-letter
   message). Unblocks #330 *and* clarifies the seam.
2. #330 lands as a separate worktree (`.worktrees/330-relay-mesh-probe/`)
   replacing the dead-letter branch with the forwarder. Carries the
   probe test as the AC.
3. #330's forwarder code is **purely additive** at the seam — if
   `peer_relays` is empty, behavior is identical to #379 post-state.
   That makes the slice trivially revertable.

If #379 stalls, #330 can still land as long as it accepts the same
host-strip helper as a one-commit prerequisite — but the cleaner path
is sequential.

## Slices

### S1. Forwarder transport (relay → relay HTTP POST)

- `ocaml/relay.ml`: replace the `cross_host_not_implemented`
  dead-letter branch with a `peer_relays` Hashtbl lookup.
- On match: POST the envelope to the peer relay's existing ingress
  endpoint (re-use the client code in `c2c_relay_connector.ml`).
- On miss: keep the dead-letter behavior unchanged.
- **AC:** unit test in `ocaml/test/` — fake two `Broker.t` instances
  in-process, send across, assert delivery.
- **Hours:** 3.

### S2. CLI `--peer-relay name=url` plumbing

- Repeatable flag on `c2c relay serve`. Populates `peer_relays` at
  boot.
- **AC:** `c2c relay serve --peer-relay host-b=http://relay-b:9001`
  boots and logs the peer registration.
- **Hours:** 1.

### S3. Probe compose + test

- Promote/edit `.worktrees/330-relay-mesh/docker-compose.relay-mesh.yml`
  to add a second relay service and the `--peer-relay` cross-link.
- Trim peer containers to busybox+`c2c` binary (no MCP, no harness).
- New `docker-tests/test_relay_mesh_probe.py` — single AC test.
- **AC:** `pytest docker-tests/test_relay_mesh_probe.py` green
  on a dev box with no other heavy containers; total compose RSS
  under `docker stats` ≤ 600 MB.
- **Hours:** 2.

### S4. Docs + closeout

- `.collab/runbooks/cross-machine-relay-proof.md`: add a "two-relay
  loopback" appendix describing the probe.
- `docs/cross-machine-broker.md`: replace "future work" mesh stub
  with v1-probe status.
- Peer-PASS, coord-cherry-pick, close #330.
- **Hours:** 1.

**Total: ~7 hours.** Mirrors #379's budget; can run in parallel
with #379-Slices-3-5 once Slice-1 lands.

## Risks & call-outs

- **Forwarder-loop risk.** If relay-A forwards to relay-B which
  forwards back to relay-A, we get a routing loop. Probe mitigation:
  forwarder MUST NOT re-forward; if the inbound message has already
  been host-stripped (or arrives via a peer-relay path), accept-or-
  dead-letter only, never re-emit. Add a `via:` envelope hop count
  capped at 1 for v1. Test in S1 unit suite.
- **Auth between relays.** v1 reuses `c2c relay connect`'s Ed25519
  identity model — each relay has its own keypair and
  authenticates its outbound forwards. No new auth surface; just
  re-uses what `c2c_relay_connector.ml` already has.
- **Don't run on the live dev box.** Document in S3 that the probe
  is CI-only or run-when-swarm-is-quiet. Add an explicit warning to
  the test docstring. The OOM lesson is: 4 thin containers + 2
  relays alongside 5 live LLM agents is still risky if the dev box
  is at the OOM threshold for unrelated reasons.
- **Not a substitute for `relay.c2c.im` proof.** The probe validates
  forwarder *code*. The cross-machine-relay-proof runbook still
  documents the production path against `relay.c2c.im`; that runbook
  remains the canonical "real two-machine" proof.

## Out of scope (deferred to follow-ups)

- Full N-pair mesh (6 ordered pairs).
- Cross-relay rooms (separate spec).
- Cross-relay ephemeral semantics.
- Kimi/Claude/Codex/OpenCode peers inside containers (#407 lane).
- Multi-hop forwarding (>1 relay between sender and receiver).

## References

- `.worktrees/330-relay-mesh/docker-compose.relay-mesh.yml` — existing
  compose (single-relay; needs second-relay extension)
- `.worktrees/330-relay-mesh/PLAN.md` — predecessor plan (4-peer mesh,
  paused for OOM)
- `.collab/design/2026-04-28T10-28-00Z-coordinator1-379-finish-implementation-plan.md`
  — sibling slice; provides the host-strip seam this probe extends
- `.collab/runbooks/cross-machine-relay-proof.md` — production
  `relay.c2c.im` proof runbook (orthogonal)
- `.sitreps/2026/04/28/03.md` — OOM postmortem context
- `.collab/research/2026-04-28T05-52-00Z-coordinator1-end-of-burn-backlog-audit.md`
  §2a #330 entry
- `ocaml/relay.ml:853-866` — host-strip seam where forwarder branches in
- `ocaml/c2c_relay_connector.ml` — outbound HTTP client to reuse for
  relay-to-relay POST
