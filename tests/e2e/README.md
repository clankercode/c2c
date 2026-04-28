# tests/e2e — cross-container end-to-end smoke

Slice S1 of #407. Provides a baseline Docker compose topology that exercises
the **real relay path** between two independent broker volumes. Unlike
`docker-compose.two-container.yml` (which shares one broker between two
containers and therefore never traverses the relay), the e2e topology
splits agents across two broker volumes (`broker-a`, `broker-b`) so that
any cross-broker delivery has to go through the `relay` container.

## Topology

- **relay** — the c2c relay (built from `Dockerfile`), listening on `:7331`
  with a `/health` healthcheck.
- **agent-a1, agent-a2** — two agent containers sharing volume `broker-a`.
- **agent-b1, agent-b2** — two agent containers sharing volume `broker-b`.

All five containers sit on a single Docker network (`c2c-e2e-net`). A DM
from `agent-a1` to `agent-b1` cannot be delivered via the local broker
(different volumes), so it must traverse `relay`.

## How to run the smoke

From the repo root:

```bash
DOCKER_BUILDKIT=1 docker compose \
  -f docker-compose.test.yml \
  -f docker-compose.e2e-multi-agent.yml \
  up -d --build

bash tests/e2e/00-smoke-cross-container.sh

docker compose \
  -f docker-compose.test.yml \
  -f docker-compose.e2e-multi-agent.yml \
  down -v
```

The smoke script itself runs `up --build` and registers a teardown trap,
so you can also just invoke it directly:

```bash
bash tests/e2e/00-smoke-cross-container.sh
```

It will: build the images, wait for the relay healthcheck, register
`agent-a1` and `agent-b1`, send a timestamped DM from a1 → b1, poll b1's
inbox for up to 10s, and PASS when the message appears.

## What it validates

- Relay container builds and reports healthy on `/health`.
- Two-volume broker isolation is real (a1 cannot see b1 via local broker).
- Cross-broker DM delivery flows through the relay (a1 → relay → b1).
- The CLI surface inside the test image (`c2c register`, `c2c send`,
  `c2c poll-inbox --json`) is wired up correctly.

It does **not** yet exercise rooms, broadcast, ephemeral DMs, or
push/channel delivery. Those are follow-ups in S2+.

## Dependencies

- `docker` + `docker compose` plugin
- `bash` (the smoke script uses `set -euo pipefail` and arrays)
- `grep` (BusyBox-compatible — used inside the agent containers via
  `docker exec`, but the host-side checks are plain GNU)

`jq` is **not** required by the current smoke; `c2c poll-inbox --json`
output is matched with `grep` on the timestamped message string. If
follow-up smokes need structured assertions, add `jq` to the host
dependency list.

## Known limitations (S1)

- **No live `up` validation in S1.** This slice promotes the draft files
  and verifies syntactic correctness only (`docker compose config`,
  `bash -n`). Actually running the stack is deferred to Slice S2 of
  #407, since the build pulls/builds images which we do not want to
  run automatically in coordinator-driven slice landings.
- **Image build is implicit.** The compose file builds from
  `Dockerfile` (relay) and `Dockerfile.test` (agents); no pre-pull
  happens. First run will be slow.
- **Healthcheck uses `wget`.** The relay image must include `wget`.
  If the relay base image changes, swap to `curl` / `c2c doctor` /
  whatever is available.
- **Polling, not push.** The smoke uses `poll-inbox` rather than
  channel push or PostToolUse hooks; that's intentional for a baseline
  cross-container smoke (no MCP client involved). Push-path smokes
  belong in a later slice once a managed-client image exists.
- **No retries on the relay path.** If the relay drops the message
  silently, the smoke surfaces a 10s timeout failure with a tail of
  relay logs but no per-hop tracing. Improve diagnostics in S2 if
  flakes appear.

## See also

- `.collab/design/2026-04-28T10-22-00Z-coordinator1-407-e2e-docker-scope.md`
  — slice scope + S1/S2/S3 split.
- `docker-compose.test.yml` — base test compose; the e2e file is an
  overlay on top of this.
- `docker-compose.two-container.yml` — older single-broker two-agent
  smoke (kept for the local-broker code paths).
