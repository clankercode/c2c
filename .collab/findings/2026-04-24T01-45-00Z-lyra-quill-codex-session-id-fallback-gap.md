## Codex managed MCP session-id fallback gap

- Symptom:
  `mcp__c2c__whoami` returned `missing session_id` from a Codex session launched via `c2c start codex`.

- How it was discovered:
  Live check from the current managed Codex session reproduced the failure immediately.

- Root cause:
  `c2c start codex` already exports `CODEX_SESSION_ID=<instance-name>` in the managed child env, but the OCaml MCP resolver only treated `CODEX_THREAD_ID` as a Codex fallback key. The MCP server wrapper also had its own startup/session helper that only trusted `C2C_MCP_SESSION_ID`, so startup auto-register and watcher setup missed the same fallback path.

- Fix status:
  Fixed in the working tree.
  Changes:
  `ocaml/c2c_mcp.ml`
  `ocaml/server/c2c_mcp_server.ml`
  `ocaml/test/test_c2c_mcp.ml`
  `tests/test_c2c_mcp_channel_integration.py`

- Verification:
  `opam exec -- dune runtest ocaml/test/test_c2c_mcp.exe --no-buffer --force`
  `opam exec -- dune build ./ocaml/server/c2c_mcp_server.exe`
  `python3 -m pytest -q tests/test_c2c_mcp_channel_integration.py -k 'auto_register_works_without_session_id_env or auto_register_prefers_codex_session_id_when_c2c_session_id_absent' --force-test-env`

- Severity:
  High. Managed Codex could lose broker identity after an MCP reconnect or session replacement, breaking `whoami`, auto-register, and channel watcher setup.

- Notes:
  The server integration test initially failed because it inherited the live agent's `CODEX_SESSION_ID` from the outer environment. The test now clears conflicting native env vars explicitly so the derived-session paths are deterministic.
