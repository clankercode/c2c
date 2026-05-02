# #407 — E2E Docker Test Suite: Scope Plan

**Status:** scope plan, ready to slice
**Author:** coordinator1 (Cairn-Vigil)
**Date:** 2026-04-28
**Context:** extends #310 (multi-container basics landed) and the paused
#330 (cross-host relay mesh). This is the long-tail "any-agent-idle"
backlog — peers should grab one slice each.

## What we have today

Existing Docker artifacts:

- `Dockerfile` — production relay (single-stage runtime).
- `Dockerfile.test` — multi-stage builder + python:3.12-slim runtime,
  ships `/usr/local/bin/c2c` + `/docker-tests/`.
- `docker-compose.yml` — single relay on `127.0.0.1:7331`.
- `docker-compose.test.yml` — sealed `test-env` + `test-kimi`,
  isolated bridge `c2c-test-net`, ephemeral broker volume.
- `docker-compose.two-container.yml` — adds `peer-a`, `peer-b`
  sharing `/var/lib/c2c` broker volume.
- `docker-compose.4-client.yml` — adds `peer-c`, `peer-d`.

Existing `docker-tests/` (pytest, runs from host, drives compose):

- `test_two_container_roundtrip.py` — register + DM A↔B.
- `test_four_client_mesh.py` — 4-way mesh sanity.
- `test_kimi_first_class_peer.py`
- `test_ephemeral_contract.py`
- `test_broker_respawn_pid.py`
- `test_monitor_leak_guard.py`
- `test_sealed_sanity.py`

Gaps: **all current tests share one broker volume** (single-host-with-
multiple-clients), so they don't exercise the relay path at all. There is
NO compose file for "two hosts, each with their own broker, talking via
a relay." There is no PTY/tmux-inside-container coverage. No peer-PASS
lifecycle E2E. No coord-cherry-pick E2E. No channel-push tag verification.
No room-ACL E2E.

## Target topology for #407

```
   +-- host-A broker --+        +--- relay ---+        +-- host-B broker --+
   |  agent-a1         | <----> | c2c-relay   | <----> |  agent-b1         |
   |  agent-a2         |        | (Dockerfile)|        |  agent-b2         |
   +-------------------+        +-------------+        +-------------------+
```

Two **separate** broker volumes (so each "host" is genuinely independent),
plus a relay container in the middle. This is the missing piece.

## Slices (each ~1-2hr, independently grabbable)

### S1. `docker-compose.e2e-multi-agent.yml` baseline (DRAFT landed)

- Land draft at `docker-compose.e2e-multi-agent.yml.draft` → promote to
  `.yml` after smoke passes.
- Two broker volumes (`broker-a`, `broker-b`), one relay, 4 agent
  containers (2 per "host"), all on one network (relay reachable).
- AC: `docker compose -f docker-compose.e2e-multi-agent.yml up -d`
  brings everything healthy; `c2c list` inside `agent-a1` shows only
  host-A peers (broker isolation verified).

### S2. Smoke: cross-host DM via relay

- Promote `tests/e2e/00-smoke-cross-container.sh.draft` to `.sh`,
  wire into `docker-tests/test_cross_host_relay.py`.
- Sends `agent-a1 → agent-b1`, polls receipt on b1.
- AC: relay logs show outbox flush; b1 receives within 5s.
- Depends on: S1.

### S3. Channel-push tag verification

- New `docker-tests/test_channel_push_envelope.py`.
- Spawn `c2c start claude` (or a stubbed channel-capable client) in
  agent-b1 inside tmux, send DM from a1, capture pane, assert
  `<c2c event="message" from="..." to="...">` present.
- AC: envelope present + only one (no duplicate from watcher race).
- Depends on: S1, tmux-in-container (S6).

### S4. Peer-PASS lifecycle E2E

- New `docker-tests/test_peer_pass_e2e.py`.
- agent-a1 commits SHA, runs `c2c send b1 "review SHA"`, b1 runs the
  review-and-fix harness equivalent (script-only, not a real LLM),
  signs PASS DM, a1 verifies signature.
- AC: full sign → DM → verify roundtrip across broker boundary.
- Depends on: S1, S2, signing keys provisioned (S5).

### S5. Per-alias signing keys provisioned in containers

- Bake/copy ed25519 keys into `/home/testagent/.c2c/keys/` for each
  agent, OR generate at container start via `c2c init`.
- AC: `c2c whoami --keys` shows pubkey on every agent; signed messages
  verify across the relay.

### S6. tmux-inside-container harness

- Extend `Dockerfile.test` to install `tmux`. Add helper
  `docker-tests/_tmux_helpers.py`: `tmux_new`, `tmux_capture`,
  `tmux_send_keys` against an agent container.
- AC: `pytest docker-tests/test_tmux_smoke.py` — start tmux session,
  capture pane, send keys, assert expected text.

### S7. PTY-inject path coverage (kimi-style)

- New `docker-tests/test_pty_inject_in_container.py`.
- Run `c2c-inject` against a child PTY inside the container. Validates
  bracketed-paste + delay path that today is only host-tested.
- Depends on: S6.

### S8. Coord-cherry-pick E2E

- New `docker-tests/test_coord_cherry_pick_e2e.py`.
- agent-a1 commits, agent-b1 (acting as "coord") runs
  `c2c-coord-cherry-pick <sha>` against a shared bare repo volume,
  receives auto-DM. Verifies the auto-DM hook fires across containers.
- AC: cherry-pick succeeds, auto-DM lands on a1.

### S9. Room ACL E2E

- New `docker-tests/test_room_acl_e2e.py`.
- a1 creates private room `--visibility private --invite a2`, b1 tries
  `join_room` and is rejected, a2 joins and sees history.
- AC: invite-only enforced across broker boundary.

### S10. Relay outage + recovery

- New `docker-tests/test_relay_outage.py`.
- Start everything, send M1 (delivered), `docker stop relay`, send M2
  (queued), `docker start relay`, assert M2 eventually delivered.
- AC: outbox persistence + reconnect work end-to-end.

### S11. CI wiring (optional, after S1-S2 green)

- `.github/workflows/e2e-docker.yml` — runs S2 smoke on PR.
- AC: green build on a clean PR; cached opam layers keep wall-time
  under ~8min.

## File paths (ready to edit)

- `docker-compose.e2e-multi-agent.yml.draft` (this commit)
- `tests/e2e/00-smoke-cross-container.sh.draft` (this commit)
- `Dockerfile.test` — append `tmux` for S6
- `docker-tests/test_cross_host_relay.py` — S2
- `docker-tests/test_channel_push_envelope.py` — S3
- `docker-tests/test_peer_pass_e2e.py` — S4
- `docker-tests/_tmux_helpers.py` — S6
- `docker-tests/test_relay_outage.py` — S10
- `.github/workflows/e2e-docker.yml` — S11

## Slice picking rules

- One slice = one worktree (`.worktrees/407-S<N>-<name>/`).
- Branch from `origin/master`.
- Real peer-PASS before coord-PASS.
- Update this design doc's slice table when grabbing — add your alias.

## Slice grab table

| Slice | Owner | Status |
|-------|-------|--------|
| S1 | coordinator1 (subagent) | shipped — drafts promoted (a44db752) |
| S2 | slate-coder + coord-subagent | shipped — subagent's structural slice (cb7c89b5) + slate's verified-working delta on top |
| S3 | (open) | |
| S4 | birch-coder | committed: test file written, syntax verified |
| S5 | (open) | |
| S6 | (open) | |
| S7 | (open) | |
| S8 | (open) | |
| S9 | (open) | |
| S10 | (open) | |
| S11 | stanza-coder | committed: e2e-docker.yml + --skip-build + image tags (267098f0) |

## Out of scope for #407

- Real LLM-driven agents inside containers (cost + flakiness).
- Multi-machine (genuinely separate hosts) — that is #330.
- Non-Linux containers.

## References

- #310 multi-container basics: `docker-tests/test_two_container_roundtrip.py`
- #330 cross-host relay (paused): `.collab/runbooks/cross-machine-relay-proof.md`
- Local relay runbook: `.collab/runbooks/local-relay.md`
- Peer-PASS rubric: `.collab/design/2026-04-27T00-58-09Z-stanza-coder-324-peer-pass-rubric.md`
