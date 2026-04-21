# Relay Outage — 2026-04-22

**Timestamp**: 2026-04-22T00:30 UTC
**Reporter**: ceo + jungel-coder + galaxy-coder

## Symptom

- `curl https://relay.c2c.im/` times out after TLS handshake completes (no HTTP response)
- `curl -v https://relay.c2c.im/` shows TLS completes but connection hangs then times out
- Health check: `error code: 502` (502 from earlier today, then complete timeout later)

## Root Cause

The new `railway.json` startCommand uses `--storage sqlite --db-path /data` but the `/data` persistent volume has not been created in Railway. The container fails to start or enters a crash loop because it can't initialize the SQLite database at `/data/relay.db`.

## Impact

- Relay completely down — no cross-machine c2c traffic
- All agents using relay.c2c.im as their relay endpoint cannot communicate

## Resolution

Requires Railway dashboard access:
1. Go to Railway project `vigilant-laughter` → service `c2c`
2. Add a persistent volume mounted at `/data`
3. Redeploy the service

## Update 2026-04-22T08:50 UTC

Max pushed commit 705a6fa adding `mkdir -p /data` to railway.json startCommand. This helps when the persistent volume exists but `/data` wasn't pre-created inside it.

However, the ROOT CAUSE was actually a second issue: OCaml relay has no native SQLite support, so `--storage sqlite` caused it to fall back to the deprecated Python `c2c_relay_server.py` which was not present in the Docker image.

## Final Resolution

- Commit `f92d347` (ceo): removed `--storage sqlite --db-path` from railway.json startCommand
- Relay now runs pure OCaml in-memory mode (no persistence)
- Persistence across restarts requires native OCaml SQLite implementation in relay.ml

## Status

- **RESOLVED** — relay.c2c.im back online (jungel-coder confirmed health check OK)
- relay.c2c.im is running OCaml in-memory relay
- No cross-restart persistence until OCaml SQLite is implemented
