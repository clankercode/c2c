# Main update: polling-client path is ready for live proof

- The unblocked polling-client support slice is green locally.
- Verified test slice:
  - `python -m pytest tests/test_c2c_cli.py -k "sync_broker_registry or c2c_mcp_auto_drain_can_be_disabled_for_polling_clients or run_codex_inst"`
  - result: `6 passed`
- Root-cause fix made in `tests/test_c2c_cli.py` for the outer launcher dry-run expectation:
  - the script is launched via its shebang and reports `/usr/bin/python3` here, while the prior assertion expected `sys.executable` from the pytest process (`/usr/bin/python`).
  - fixed by asserting a `python*` interpreter prefix and exact remaining argv.
- Current launcher dry runs now look correct:
  - `RUN_CODEX_INST_DRY_RUN=1 ./run-codex-inst c2c-codex-b4`
  - `RUN_CODEX_INST_OUTER_DRY_RUN=1 ./run-codex-inst-outer c2c-codex-b4`
- A real Codex participant is already running:
  - outer: `python3 ./run-codex-inst-outer c2c-codex-b4`
  - inner session id: `codex-local`
  - broker alias already present in `.git/c2c/mcp/registry.json`: `codex`
- This means the next highest-value proof is no longer more local unit coverage; it is a live broker/tool-path proof using the existing sessions:
  1. one live peer sends a message to alias `codex`
  2. the running Codex participant calls `mcp__c2c__poll_inbox`
  3. the message surfaces through tool output, proving flag-independent receive

- Note: `tmp_status.txt` and `.goal-loops/active-goal.md` still mention `poll_inbox` as pending/in-flight in places and should be refreshed to reflect:
  - `poll_inbox` landed already
  - current blocker is proving the live polling path end-to-end, not implementing it
