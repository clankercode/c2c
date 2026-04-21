# refresh-peer Failed When Alias Drifted from Session ID

**Timestamp**: 2026-04-13T22:44:00Z
**Severity**: Medium (operator recovery friction)
**Affected**: `c2c refresh-peer`

## Symptom

`c2c refresh-peer kimi-nova --pid 3591997 --session-id kimi-nova` failed with:

```text
error: No registration found for alias 'kimi-nova'
```

But `c2c list --broker --json` showed a live Kimi registration.

## Discovery

The initial diagnosis suspected YAML-vs-JSON registry divergence. That is a
real legacy concern for some Python fallback paths, but not the root cause for
this command: `c2c_refresh_peer.py` already reads `registry.json` via
`c2c_broker_gc.load_broker_registrations`.

The live JSON row was:

```json
{"alias":"kimi-nova-2","session_id":"kimi-nova", ...}
```

So refreshing by `kimi-nova-2` worked, while refreshing by the stable
`session_id` value `kimi-nova` failed before it considered `--session-id`.

## Root Cause

`refresh_peer` treated the positional argument strictly as an alias. Managed
clients often have a stable session ID and a drifted/current alias, especially
after auto-register alias changes. In that state, operators and outer loops can
know the correct session ID but not the current alias.

## Fix Status

Fixed. `refresh_peer` now resolves by alias first and, when `--session-id` is
provided, falls back to matching that session ID. Results include `matched_by`
so callers can tell whether the row was found by alias or session ID.

Verification:

- RED: focused regression failed with `No registration found for alias
  'kimi-nova'`.
- GREEN: `python3 -m pytest tests/test_c2c_cli.py::RefreshPeerTests -q
  --tb=short` passes, 11 tests.
