# Env Variable Leakage Pattern in Tests

- Symptom: Tests that copy `os.environ` or use `mock.patch.dict(os.environ, {}, clear=False)` fail when run inside a live swarm session with `C2C_MCP_AUTO_REGISTER_ALIAS`, `C2C_SESSION_ID`, or `C2C_MCP_SESSION_ID` set in the environment (via `run-claude-inst.d/*.json`).
- Discovery: `test_auto_register_disabled_by_default` failed with `AssertionError: 'storm-ember' is not None` because the test patched env with `{}` (no clear) and the live `C2C_MCP_AUTO_REGISTER_ALIAS=storm-ember` stayed visible. `test_fans_out_to_every_live_peer_and_skips_sender` and `test_exclude_aliases_drops_named_peers` failed because subprocess env copied from `os.environ` included `C2C_MCP_AUTO_REGISTER_ALIAS=storm-ember`, causing the subprocess to auto-register storm-ember into the test broker before send_all ran.
- Root cause: `run-claude-inst.d/c2c-r2-b1.json` sets `C2C_MCP_AUTO_REGISTER_ALIAS=storm-ember` (and `C2C_SESSION_ID=...`) in the shell environment. Tests that call `os.environ.copy()` or `mock.patch.dict(..., clear=False)` inherit these vars.
- Fix applied: 
  - `test_c2c_mcp_auto_register.py`: patch `C2C_MCP_AUTO_REGISTER_ALIAS=""` explicitly.
  - `test_c2c_send_all.py`: add `env["C2C_MCP_AUTO_REGISTER_ALIAS"] = ""` before subprocess call.
  - `test_c2c_cli.py` (earlier): mock `C2C_SESSION_ID=""` and `C2C_SESSION_PID=""` to isolate send-alias dispatch test.
- Pattern for future agents: whenever creating a subprocess test that uses `os.environ.copy()`, ALWAYS explicitly zero out these vars:
  ```python
  env["C2C_MCP_AUTO_REGISTER_ALIAS"] = ""
  env["C2C_SESSION_ID"] = ""
  env["C2C_MCP_SESSION_ID"] = ""   # if the test controls its own session
  env["C2C_SESSION_PID"] = ""
  ```
  Similarly, in `mock.patch.dict` tests that test "no alias configured", use `{"C2C_MCP_AUTO_REGISTER_ALIAS": ""}` not `{}`.
- Severity: medium — silent false failures when tests are run inside a live session, pass on CI (where env is clean). Root cause is the env being polluted by the run-claude-inst swarm setup, which is inherent to dogfooding the tools.
