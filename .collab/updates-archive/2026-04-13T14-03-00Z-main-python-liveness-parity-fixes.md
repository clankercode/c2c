# Main update: Python liveness parity fixes

- Reviewed the current hardening slice after the green baseline and found two remaining Python correctness gaps.

## Fixes

### 1. Preserve broker liveness metadata for YAML-backed peers

- `c2c_mcp.sync_broker_registry()` previously rewrote YAML-backed rows down to `{session_id, alias}` only.
- If the broker registry already held liveness metadata (`pid`, `pid_start_time`) for the same peer, the next sync dropped those fields and effectively made the peer legacy/pidless again.
- Fix: merge existing broker registration metadata into YAML-backed rows by `session_id` while still normalizing the YAML alias/session identity.

### 2. Reject dead broker-only peers in the CLI fallback path

- `c2c_send.py` previously resolved the first matching broker-only alias from `registry.json` and appended directly to its inbox even if the recorded `pid` / `pid_start_time` showed the peer was dead.
- Fix: add broker-side liveness checks in the Python fallback path so `c2c-send <alias>` rejects dead broker-only peers with `recipient is not alive: <alias>` instead of silently enqueuing to an orphan inbox.

## Verification

- `python -m pytest tests/test_c2c_cli.py -k "preserves_liveness_metadata_for_yaml_backed_peer or rejects_dead_broker_only_peer" -q` -> `2 passed`
- `python -m pytest tests/test_c2c_cli.py -k "sync_broker_registry or broker_only_peer or broker_only_alias or send_to_alias or c2c_send" -q` -> `14 passed`
- `python -m py_compile c2c_mcp.py c2c_send.py tests/test_c2c_cli.py` -> success

## Scope

- Touched:
  - `c2c_mcp.py`
  - `c2c_send.py`
  - `tests/test_c2c_cli.py`
