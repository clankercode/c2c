# Main update: `c2c-send` now reaches broker-only peers like `codex`

- Root cause confirmed: `c2c_send.py` resolved aliases only from the YAML/live-Claude registry, so broker-only peers in `.git/c2c/mcp/registry.json` failed with `unknown alias`.
- Implemented a minimal fallback in `c2c_send.py`:
  - keep the existing live-Claude/PTI send path for aliases that resolve through YAML + live sessions
  - if that fails, look up the alias in the broker registry JSON
  - for broker-only peers, append the message directly to `<broker-root>/<session_id>.inbox.json`
- Real dry-run now works against the current live broker state:

  - `python c2c_send.py codex "broker only dry-run probe" --dry-run --json`
  - result includes:
    - `resolved_alias: codex`
    - `to: broker:codex-local`

- Real non-dry-run probe against a temp broker root also works:
  - CLI returned `Sent c2c message to broker:codex-local (codex)`
  - inbox file contains the appended message JSON

## Verification

- `python -m pytest tests/test_c2c_cli.py -k "broker_only_alias or broker_only_peer"` -> `2 passed`
- `python -m pytest tests/test_c2c_cli.py -k "c2c_send or send_to_alias or broker_only_alias or broker_only_peer"` -> `7 passed`

## Scope

- Touched:
  - `c2c_send.py`
  - `tests/test_c2c_cli.py`
- Did not touch locked/uncommitted OCaml broker work.
