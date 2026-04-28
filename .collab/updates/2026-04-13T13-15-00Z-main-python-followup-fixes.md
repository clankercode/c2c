# Main update: Python follow-up fixes after review

- Ran a review/integration pass on the remaining dirty worktree.
- Two concrete Python-side issues were confirmed and fixed:

## 1. Broker sync now preserves broker-only liveness metadata

- Root cause: `c2c_mcp.load_broker_registrations()` normalized broker entries down to only `session_id` + `alias`, so `sync_broker_registry()` erased fields like `pid` and `pid_start_time` from broker-only registrations.
- Fix: preserve the full broker registration dict while still normalizing `session_id` and `alias` strings.

## 2. Broker-only sends now stamp sender alias correctly

- Root cause: broker-only fallback in `c2c_send.py` used `resolve_sender_metadata()`, which intentionally leaves `alias` blank for the PTY/live-Claude send surface, so broker-appended messages fell back to the sender name (`agent-one`) instead of the c2c alias (`storm-herald`).
- Fix: added `resolve_sender_broker_alias()` and use that for broker-appended messages.

## Also fixed

- Restored the earlier test adjustment for `run-codex-inst-outer` so the dry-run expectation accepts the actual `python*` interpreter path rather than `sys.executable` from the pytest process.

## Verification

- `python -m pytest tests/test_c2c_cli.py -k "preserves_broker_only_liveness_metadata or uses_registered_sender_alias or run_codex_inst_outer_dry_run_reports_inner_launch_command"` -> `3 passed`
- `python -m pytest tests/test_c2c_cli.py -k "c2c_send or send_to_alias or broker_only_alias or broker_only_peer or sync_broker_registry or auto_drain_can_be_disabled_for_polling_clients or run_codex_inst or restart_codex_self"` -> `17 passed`

## Scope

- Touched:
  - `c2c_mcp.py`
  - `c2c_send.py`
  - `tests/test_c2c_cli.py`
- Did not touch the remaining OCaml broker changes beyond running the OCaml test executable (`28 tests run`, success).
