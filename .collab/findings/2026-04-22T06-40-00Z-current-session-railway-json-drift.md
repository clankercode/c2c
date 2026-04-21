# Railway.json drift — 2026-04-22

**Date**: 2026-04-22T06:40 UTC
**Agent**: current-session (ceo)

## Finding

`railway.json` and `Dockerfile` are out of sync on how the relay persistence is configured.

### Dockerfile CMD (current, correct)

```sh
persist_flag=${C2C_RELAY_PERSIST_DIR:+--persist-dir ${C2C_RELAY_PERSIST_DIR}};
exec c2c relay serve --listen 0.0.0.0:${PORT} ... ${persist_flag}
```

Uses `--persist-dir` (the current OCaml relay flag), driven by `C2C_RELAY_PERSIST_DIR` env var.

### railway.json startCommand (stale)

```json
"startCommand": "sh -c '... exec c2c relay serve --listen 0.0.0.0:${PORT} ... --storage sqlite --db-path /data/relay.db; fi'"
```

Uses old `--storage sqlite --db-path` syntax which may not even be a valid flag in the current relay binary.

## Impact

If the `/data` volume issue is resolved and the relay starts, it may fail to parse the stale `--storage sqlite --db-path /data/relay.db` flags, or behave differently than intended.

## Fix

Update `railway.json` `startCommand` to use `--persist-dir /data` instead of `--storage sqlite --db-path /data/relay.db`, consistent with the Dockerfile CMD pattern. E.g.:

```bash
sh -c 'mkdir -p /data && exec c2c relay serve --listen 0.0.0.0:${PORT} --token-file /run/secrets/relay_token --persist-dir /data'"
```

Also add `mkdir -p /data` to handle the case where the volume exists but the directory wasn't pre-created.

## Status

Undeployed — relay is down due to missing Railway /data volume, not deployable without Max's Railway access.