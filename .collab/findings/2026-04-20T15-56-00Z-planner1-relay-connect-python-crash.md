# `c2c relay connect` shells to Python connector that crashes on JSON decode

- **Date:** 2026-04-20T15:56Z (2026-04-21 01:56 local +10)
- **Alias:** planner1
- **Severity:** low (v1-wise) — not a ship-gate blocker per coder1 /
  coder2-expert. Deprecation-cleanup track.
- **Fix status:** NOT FIXED — native OCaml connector port is an open
  piece of Layer-1 cleanup.

## Symptom

```
$ c2c relay connect --relay-url https://relay.c2c.im --once \
                    --node-id planner1-smoke-$$ --interval 5
Traceback (most recent call last):
  File "/home/xertrov/src/c2c/c2c_relay_connector.py", line 417, in <module>
    raise SystemExit(main())
  File ".../c2c_relay_connector.py", line 398, in main
    health = client.health()
  File ".../c2c_relay_connector.py", line 92, in health
    return self._request("GET", "/health")
  File ".../c2c_relay_connector.py", line 85, in _request
    return json.loads(exc.read())
  ...
```

The Python connector raises an `HTTPError` during `/health` and then
tries to JSON-decode `exc.read()` — but the error body is not JSON,
so `json.loads` itself throws. The actual `/health` endpoint is
returning 200 `{"ok":true}` from curl, so the connector is mis-
interpreting the response.

## How I discovered it

Trying to register a smoke-test alias against the just-restored
production relay via `c2c relay connect --once` as part of the
runbook §8 dry-run.

## Root cause (per coder2-expert, coder1 via swarm-lounge)

`c2c relay connect` (ocaml/cli/c2c.ml:1893) still shells out to
`c2c_relay_connector.py`. The Python script pre-dates the L2/L3/L4
server response shape changes and probably expects the old
`registrations` / unsigned `poll_inbox` payloads. On any non-200 it
tries to JSON-decode an HTML/plaintext body and explodes.

## Impact

- Users following the old build-plan §5 recipe hit a stacktrace.
- Does NOT affect v1 ship-gate — native `c2c relay {rooms, status,
  list, identity}` is the v1 surface; peer↔relay fan-in for agents
  is done via `c2c-mcp-server` + broker integration, not `connect`.

## Next step (deprecation track, not v1)

1. Log the slice as "port `c2c_relay_connector.py` → OCaml" under
   Layer 1 leftovers.
2. Until then, remove `c2c relay connect` from the user-facing CLI
   (shadow-alias it) or wrap the Python crash in a clear "legacy,
   superseded" message.
3. Update §8 runbook to skip `connect`.

## Related

- Runbook drift finding:
  `.collab/findings/2026-04-20T15-54-00Z-planner1-runbook-section-8-cli-drift.md`
- `docs/c2c-research/RELAY.md` Layer 1 has the "Port Relay_client
  contract-test coverage" slice in progress but no "port the
  connector" slice — should be added.
