# Local relay — docker-compose runbook

Purpose: run a full c2c relay locally in an isolated container for testing, without round-tripping through Railway. Useful for Phase-A security fix validation, mobile app dev, smoke-testing binary upgrades before deploy.

Filed 2026-04-23, task #103.

## TL;DR

```bash
DOCKER_BUILDKIT=1 docker compose up -d --build
curl http://localhost:7331/health     # {"status":"ok",...}
docker compose logs -f relay          # tail logs
docker compose down                   # stop (keeps data)
docker compose down -v                # stop + wipe volume
```

## First-time bringup (cold cache)

Cold build on a fresh machine takes ~5-8 min (opam pulls + OCaml compile).

```bash
# BuildKit enables cache mounts for faster warm rebuilds.
export DOCKER_BUILDKIT=1
docker compose up -d --build

# Confirm relay is live:
docker compose ps                     # should show relay (healthy)
curl -fsS http://localhost:7331/health
```

The compose file maps `127.0.0.1:7331 → container:7331` (localhost-only for safety). Adjust the ports mapping in `docker-compose.yml` if you need to expose it on the LAN.

## Iterating on OCaml code

BuildKit will cache the opam-deps layer across source changes. Expect source-only iterations to complete in ~30-60s:

```bash
# Make OCaml edits, then:
DOCKER_BUILDKIT=1 docker compose up -d --build relay
curl http://localhost:7331/health
```

If you're iterating fast, consider running the relay binary directly on the host instead: `c2c relay serve --listen 127.0.0.1:7331 --persist-dir ./local-relay-state`. Docker is best for validating the *deployed* shape of the binary (e.g. a Debian runtime matches Railway's).

## Smoke test

Once up, drive it with curl or the c2c CLI pointed at the local relay:

```bash
# Register a test peer (dev mode, no token):
curl -X POST http://localhost:7331/register -d '{"alias":"test","node_id":"n1","session_id":"s1"}' -H 'Content-Type: application/json'

# Or use the CLI against it:
C2C_RELAY_URL=http://localhost:7331 c2c list
```

The `scripts/relay-smoke-test.sh` script is intended for this too — verify with `C2C_RELAY_URL=http://localhost:7331 ./scripts/relay-smoke-test.sh` (check the script's env var name).

## Prod-mode Bearer auth

Uncomment the `RELAY_TOKEN` line in `docker-compose.yml` and rebuild. Then all admin routes need `Authorization: Bearer <token>`.

```yaml
environment:
  RELAY_TOKEN: "local-dev-token"
```

## Persistence

The named volume `c2c-relay-data` persists:
- SQLite DB (leases, nonces, dedup, rooms)
- Identity keypair (`relay_identity.json`)
- Room history JSONL

Survives `docker compose down`. Wiped by `docker compose down -v`.

Inspect the volume:

```bash
docker run --rm -v c2c_c2c-relay-data:/data alpine ls -la /data
```

## Teardown

```bash
docker compose down                   # stops container, keeps volume
docker compose down -v                # nukes volume too
docker image rm c2c-relay:local       # also free the image (optional)
```

## Known gaps (follow-up)

- **No BuildKit cache mount in Dockerfile.** Adding `RUN --mount=type=cache,target=/home/opam/.opam/download-cache` would halve cold build time. Task #103 second iteration.
- **No `relay-dev` profile with bind-mounted source.** For truly live-reload iteration we'd want a dev profile that mounts `./ocaml` into the container and runs `dune build --watch`. Deferred — if/when mobile dev needs it.
- **No observer/broker mock sidecar.** M5 research (`.projects/c2c-mobile-app/research-tauri-e2e-docker.md`) calls for an observer-fixture container eventually. Deferred.
- **TLS not tested.** Production Railway terminates TLS at the edge; local compose runs plain HTTP. Adequate for functional testing; inadequate for validating the `get_fd_from_flow` TLS branch (flagged in relay audit).

## Relation to Railway deploy

This uses the same `Dockerfile` Railway builds against, so "works in compose" ≈ "works on Railway" — modulo TLS, env vars, and secrets mounting. The compose file mimics Railway's single-service model intentionally.
