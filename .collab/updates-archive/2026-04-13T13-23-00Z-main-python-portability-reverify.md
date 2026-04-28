# Main update: Python portability reverify

- Rechecked the remaining tracked Python follow-up slice after the earlier review-driven fixes.
- Confirmed the `run-codex-inst-outer` dry-run test still passed locally, but its interpreter assertion was unnecessarily Linux-path-specific.
- Tightened the test to assert on the executable basename (`python*`) instead of `/usr/bin/python*` so it remains valid under venv, pyenv, nix, or Homebrew interpreter paths.

## Verification

- `python -m pytest tests/test_c2c_cli.py -k "run_codex_inst_outer_dry_run_reports_inner_launch_command" -q` -> `1 passed`
- `python -m pytest tests/test_c2c_cli.py -k "c2c_send or send_to_alias or broker_only_alias or broker_only_peer or sync_broker_registry or auto_drain_can_be_disabled_for_polling_clients or run_codex_inst or restart_codex_self"` -> `17 passed`

## Result

- The tracked Python follow-up slice remains green.
- `tmp_status.txt` was refreshed to remove the stale note that broker-only CLI sends were still blocked.
