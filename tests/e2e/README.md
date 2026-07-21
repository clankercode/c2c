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

### Full smoke (up + private-denial assert + down)

```bash
bash tests/e2e/00-smoke-cross-container.sh
```

It will: build the images, `up -d --wait --wait-timeout 60` so Docker
itself blocks until the relay healthcheck passes, register private
`agent-a1` and `agent-b1` on independent broker volumes, attempt an
unsolicited timestamped DM from a1 → b1, require the uniform
`contact_unauthorised` denial, and poll b1 once to prove rejected content
was not delivered. The cleanup trap always tears down (`-v` wipes broker
volumes) unless `--no-teardown` is passed and the smoke passed.

Manual control:

```bash
DOCKER_BUILDKIT=1 docker compose -f docker-compose.e2e-multi-agent.yml up -d --build --wait
bash tests/e2e/00-smoke-cross-container.sh --no-teardown
docker compose -f docker-compose.e2e-multi-agent.yml down -v
```

## What it validates

- Relay container builds and reports healthy on `/health`.
- Two-volume broker isolation is real (a1 cannot see b1 via local broker).
- Cross-broker first contact reaches the relay security boundary and is
  denied without recipient consent.
- Rejected private content never appears in the recipient relay inbox.
- The relay identity/register/dm-send/dm-poll CLI surface inside the agent
  image is wired up correctly.

It does **not** exercise authorised contact-grant delivery, rooms,
broadcast, ephemeral DMs, or push/channel delivery. Authorised grant flow
is covered by the hermetic grant/handler/matrix suites; the remaining paths
are follow-ups.

## Dependencies

- `docker` + `docker compose` plugin
- `bash` with arrays + `set -euo pipefail`
- `grep`, `sed` (smoke uses GNU host tools; in-container greps go through
  busybox-compatible flags only)

`jq` is **not** required: the denial and poll output are matched with
`grep` against the error code and timestamped message string.

## Known limitations

- **CI runs the live stack.** `.github/workflows/e2e-docker.yml` builds the
  images and runs the private-denial smoke on pushes and pull requests.
  Local operators can still use `--validate` for syntax-only checks.
- **First-run build is slow.** Both `Dockerfile` and `Dockerfile.test`
  do a full opam install + dune build; expect 10-15min cold, ~1min warm
  via BuildKit cache.
- **Polling, not push.** The smoke polls once only to prove a rejected
  message is absent; no MCP or managed-client push path is involved.
- **No authorised control in this Docker script.** Signed registration is
  exercised, but sender-bound grant issuance/delivery is covered by the
  hermetic security suites rather than duplicated here.

## See also

- `.collab/design/2026-04-28T10-22-00Z-coordinator1-407-e2e-docker-scope.md`
  — slice scope + S1/S2/S3 split.
- `.collab/design/2026-04-28T12-26-00Z-coordinator1-330-relay-mesh-probe-scope.md`
  — RAM/topology constraints inherited from the #330 probe.
- `Dockerfile` (relay runtime), `Dockerfile.test` (agent runtime).
- `docker-compose.two-container.yml` — older single-broker two-agent
  smoke (kept for the local-broker code paths).
