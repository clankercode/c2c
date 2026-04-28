# tests/e2e — cross-container end-to-end smoke

Slices S1+S2 of #407. Provides a baseline Docker compose topology that
exercises the **real relay path** between two independent broker volumes.
Unlike `docker-compose.two-container.yml` (which shares one broker between
two containers and never traverses the relay), the e2e topology splits
agents across two broker volumes (`broker-a`, `broker-b`) so any
cross-broker delivery has to go through the `relay` container.

## Topology

- **relay** — the c2c relay (built from `Dockerfile`), listening on
  `:7331` with a `/health`-based healthcheck driven by `c2c relay status`
  (the runtime image is debian:12-slim, no `wget`/`curl`, so we reuse
  the binary).
- **agent-a1, agent-a2** — two agent containers sharing volume `broker-a`.
- **agent-b1, agent-b2** — two agent containers sharing volume `broker-b`.

All five containers sit on a single Docker network (`c2c-e2e-net`). A DM
from `agent-a1` to `agent-b1` cannot be delivered via the local broker
(different volumes), so it must traverse `relay`.

The agent image is `Dockerfile.test` — thin `python:3.12-slim` runtime
with the c2c binary at `/usr/local/bin/c2c`, NO MCP harness, NO LLM
client. Per #330 probe scope: total RAM budget ≤600MB enforced via
compose `deploy.resources.limits` (relay 128MB + 4 agents @ 96MB =
512MB cap).

## How to run the smoke

The smoke script lives at `tests/e2e/00-smoke-cross-container.sh` and
supports three modes.

### Validate-only (CI-friendly, no daemon interaction)

```bash
bash tests/e2e/00-smoke-cross-container.sh --validate
```

Runs `docker compose config --quiet` + `bash -n` against the script
itself. No images built, no containers started. Suitable for a PR
gate that just confirms the YAML and script remain syntactically
correct.

### Build-only (warm the local image cache)

```bash
bash tests/e2e/00-smoke-cross-container.sh --build-only
```

Builds the relay + agent images. Does NOT bring the stack up. Useful
to pre-warm before the full smoke or to confirm Docker layer caching
works.

### Full smoke (up + send + assert + down)

```bash
bash tests/e2e/00-smoke-cross-container.sh
```

It will: build the images, `up -d --wait --wait-timeout 60` so docker
itself blocks until the relay healthcheck passes, register `agent-a1`
and `agent-b1`, send a timestamped DM from a1 → b1, poll b1's inbox
for up to 10s, and PASS only when the message appears. The cleanup
trap always tears down (`-v` wipes broker volumes) unless
`--no-teardown` is passed and the smoke passed.

Manual control:

```bash
DOCKER_BUILDKIT=1 docker compose -f docker-compose.e2e-multi-agent.yml up -d --build --wait
bash tests/e2e/00-smoke-cross-container.sh --no-teardown
docker compose -f docker-compose.e2e-multi-agent.yml down -v
```

## What it validates

- Relay container builds and reports healthy on `/health`.
- Two-volume broker isolation is real (a1 cannot see b1 via local broker).
- Cross-broker DM delivery flows through the relay (a1 → relay → b1).
- The CLI surface inside the agent image (`c2c register`, `c2c send`,
  `c2c poll-inbox --json`) is wired up correctly.

It does **not** yet exercise rooms, broadcast, ephemeral DMs, or
push/channel delivery. Those are follow-ups in S3+.

## Dependencies

- `docker` + `docker compose` plugin
- `bash` with arrays + `set -euo pipefail`
- `grep`, `sed` (smoke uses GNU host tools; in-container greps go through
  busybox-compatible flags only)

`jq` is **not** required: `c2c poll-inbox --json` output is matched with
`grep` against the timestamped message string.

## Known limitations

- **No live `up` validation in CI.** Per #330 probe scope, this slice
  ships syntactic validation (`--validate`) and a runnable smoke, but
  does NOT auto-run the full stack against the dev swarm — bringing up
  4 agent containers + a relay during a slice landing would compete with
  live work for resources. Operators run the full smoke manually when
  changing relay/broker code paths.
- **First-run build is slow.** Both `Dockerfile` and `Dockerfile.test`
  do a full opam install + dune build; expect 10-15min cold, ~1min warm
  via BuildKit cache.
- **Polling, not push.** The smoke uses `poll-inbox` rather than channel
  push or PostToolUse hooks; that's intentional for a baseline
  cross-container smoke (no MCP client involved). Push-path smokes belong
  in a later slice once a managed-client image exists (#407 S3).
- **No retries on the relay path.** If the relay drops the message
  silently, the smoke surfaces a 10s timeout failure with a tail of relay
  + agent-a1 logs but no per-hop tracing. Improve diagnostics in S3 if
  flakes appear.
- **No signing keys provisioned.** Cross-broker delivery in this smoke
  uses unsigned envelopes. Signed-message verification is #407 S5.

## S5 — signing keys provisioning E2E

The `tests/e2e/test_peer_pass_signing_e2e.py` pytest harness and
`tests/e2e/05-peer-pass-signing.sh` bash script cover S5:
`c2c relay identity init` provisions an ed25519 key inside each
agent container; `c2c peer-pass sign` creates a signed artifact for a
test commit; `c2c peer-pass verify` validates it on a peer agent across
the relay. A shared Docker volume (`s5-artifact`) is used to transfer
the artifact from agent-a1's broker volume to agent-b1's view.

AC:
1. `c2c relay identity show --json` returns `alg: ed25519` + fingerprint
   on every agent container.
2. A peer-PASS artifact signed by agent-a1 verifies successfully on
   agent-b1 across the two-broker topology.

## See also

- `.collab/design/2026-04-28T10-22-00Z-coordinator1-407-e2e-docker-scope.md`
  — slice scope + S1/S2/S3 split.
- `.collab/design/2026-04-28T12-26-00Z-coordinator1-330-relay-mesh-probe-scope.md`
  — RAM/topology constraints inherited from the #330 probe.
- `Dockerfile` (relay runtime), `Dockerfile.test` (agent runtime).
- `docker-compose.two-container.yml` — older single-broker two-agent
  smoke (kept for the local-broker code paths).
