# Bug: client_type=null registry — C2C_MCP_CLIENT_TYPE not wired to register

**Date:** 2026-04-22T06:30:00Z
**Agent:** jungel-coder
**Severity:** medium (registry is missing useful metadata for all peers)

## Symptom

All 13 peers in `c2c list` show `client_type: null` despite commit `44ffa2d`
wiring `C2C_MCP_CLIENT_TYPE` into all client install scripts (`c2c install <client>`
writes the env var to the shell profile).

## Root Cause

Two calls to `Broker.register` in `ocaml/cli/c2c.ml` did not pass `client_type`:

1. **`c2c register`** (line ~1423): `Broker.register broker ~session_id ~alias ~pid ~pid_start_time ()`
   — missing `~client_type:(env_client_type ())`

2. **`c2c init`** (line ~4949): `Broker.register broker ~session_id ~alias ~pid:None ~pid_start_time:None ()`
   — same omission

The `env_client_type ()` helper function (reading `C2C_MCP_CLIENT_TYPE`) did not exist.

## Fix

1. Added `env_client_type ()` helper after `env_auto_alias ()` (line ~141):
   ```ocaml
   let env_client_type () =
     match Sys.getenv_opt "C2C_MCP_CLIENT_TYPE" with
     | Some v when String.trim v <> "" -> Some (String.trim v)
     | _ -> None
   ```

2. Updated `c2c register` call: `~client_type:(env_client_type ())` added to `Broker.register`

3. Updated `c2c init` call: same

4. Rebuilt with `just install-all` — verified manually that a new registration
   (`test-session-789`, `alias=test-client-type`) stores `"client_type": "opencode"`
   correctly in registry.json.

## Existing Registrations

Pre-existing registrations will NOT be retroactively fixed — they will continue
to show `client_type: null` until they re-register (restart the client or call
`c2c register` again).

## Note on OCaml Tests

OCaml tests (`test_c2c_mcp.ml`) have existing `client_type` coverage for sweep
exemption (`test_human_client_type_exempt_from_provisional_sweep`) but no
dedicated unit test for the CLI → broker path. The manual verification above
is sufficient for now.