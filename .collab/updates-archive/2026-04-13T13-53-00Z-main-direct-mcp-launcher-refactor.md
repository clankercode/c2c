# Main update: direct MCP launcher refactor

- Followed up on the documented broker-process leak risk in `c2c_mcp.py`.
- The launcher still used `bash -lc 'eval "$(opam env ...)" && dune exec ...'`, which matched the leak-prone wrapper chain described in `.collab/findings/2026-04-13T03-24-00Z-storm-echo-broker-process-leak.md`.

## Fix

- `c2c_mcp.py` now performs an explicit build step with:
  - `opam exec --switch=... -- dune build --root ... ./ocaml/server/c2c_mcp_server.exe`
- After the build completes, it launches the built binary directly from:
  - `_build/default/ocaml/server/c2c_mcp_server.exe`
- This removes the long-lived runtime `bash -lc` + `dune exec` wrapper chain from the normal MCP launch path while keeping the existing env plumbing, including `C2C_MCP_BROKER_ROOT`, `C2C_MCP_SESSION_ID`, and `C2C_MCP_CLIENT_PID`.

## Verification

- `python -m pytest tests/test_c2c_cli.py::C2CCLITests::test_c2c_mcp_main_exports_current_client_pid_for_server_register tests/test_c2c_cli.py::C2CCLITests::test_c2c_mcp_default_session_id_retries_briefly_for_fresh_session_file tests/test_c2c_cli.py::C2CCLITests::test_c2c_mcp_default_session_id_waits_long_enough_for_real_startup tests/test_c2c_cli.py::C2CCLITests::test_c2c_mcp_default_session_id_stops_after_bounded_wait tests/test_c2c_cli.py::C2CCLITests::test_c2c_mcp_main_skips_session_env_when_current_session_unresolvable tests/test_c2c_cli.py::C2CCLITests::test_c2c_mcp_main_seeds_broker_registry_and_session_env tests/test_c2c_cli.py::C2CCLITests::test_c2c_mcp_main_builds_server_before_launch tests/test_c2c_cli.py::C2CCLITests::test_c2c_mcp_main_launches_built_server_directly -q` -> `8 passed`
- `python -m py_compile c2c_mcp.py tests/test_c2c_cli.py` -> success

## Scope

- Touched:
  - `c2c_mcp.py`
  - `tests/test_c2c_cli.py`
