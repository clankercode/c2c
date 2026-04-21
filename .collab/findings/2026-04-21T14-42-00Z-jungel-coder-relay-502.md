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

## Status

- Railway auth expired for all agents (token revoked)
- GitHub pushes still work — only Railway deploy is blocked
- relay.c2c.im down since ~2026-04-22T00:30 UTC
