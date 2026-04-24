## Codex MCP session recovery depends on per-request metadata, not inherited env

- Symptom:
  `mcp__c2c__whoami` returned `missing session_id` in a live Codex session launched with `c2c start codex`, even though the shell still showed `C2C_MCP_SESSION_ID` and `CODEX_THREAD_ID`.

- How it was discovered:
  Live `mcp__c2c__whoami` failed twice. The MCP debug log under `~/.local/share/c2c/mcp-debug/no-session.log` showed the server starting as `no-session` and then receiving `tools/call` requests with `_meta.x-codex-turn-metadata.session_id=<real-thread-id>`.

- Root cause:
  Codex is not reliably inheriting managed-session env into the MCP subprocess. The server therefore starts without `C2C_MCP_SESSION_ID` or `CODEX_THREAD_ID`. However, Codex does attach the real thread id on each `tools/call` request. c2c was ignoring that request metadata, so managed Codex MCP tools had no usable identity at runtime.

- Fix status:
  Fixed in working tree.
  Changes:
  - `ocaml/c2c_mcp.ml`: recover request-scoped session identity from Codex turn metadata, map managed Codex thread ids back to stable c2c instance session ids via `config.json`, and fall back to raw thread id for unmanaged Codex.
  - `ocaml/cli/c2c.ml`: native Codex install/config now writes `C2C_MCP_CLIENT_TYPE="codex"` to stay aligned with the Python writer.
  - `ocaml/test/test_c2c_mcp.ml`
  - `tests/test_c2c_mcp_channel_integration.py`
  - `tests/test_c2c_cli.py`

- Verification:
  - `opam exec -- dune exec ./ocaml/test/test_c2c_mcp.exe --no-buffer --force`
  - `python3 -m pytest -q tests/test_c2c_mcp_channel_integration.py -k 'auto_register_prefers_codex_thread_id_when_c2c_session_id_absent or codex_turn_metadata_maps_to_managed_session_id' --force-test-env`
  - `python3 -m pytest -q tests/test_c2c_cli.py -k 'native_install_codex_writes_client_type_env' --force-test-env`

- Severity:
  High. Managed Codex MCP tools could not self-identify unless Codex happened to preserve launch env, which broke `whoami` and any env-resolved tool path.
