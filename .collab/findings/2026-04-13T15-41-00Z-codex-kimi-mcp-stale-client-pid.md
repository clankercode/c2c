# Kimi MCP Auto-Register Reverted To A Dead PID

- **Symptom:** `mcp__c2c__list` repeatedly showed `kimi-nova` registered at
  dead pid `2959892`, even after `c2c_refresh_peer.py kimi-nova --pid 3591998`
  updated the broker registry to the live Kimi process.
- **Discovery:** The live `c2c_mcp.py` child under Kimi had
  `C2C_MCP_SESSION_ID=kimi-nova` and `C2C_MCP_CLIENT_PID=2959892` in its
  environment. Its actual parent process was the live Kimi TUI pid `3591998`.
- **Root cause:** Both MCP layers trusted `C2C_MCP_CLIENT_PID` too much:
  `c2c_mcp.current_client_pid_from_env` in the Python launcher and
  `current_client_pid` in `ocaml/c2c_mcp.ml` used the env value whenever it
  parsed as an integer. If a restored or long-lived Kimi session inherited a
  stale value, startup auto-register wrote that dead pid back into the broker.
- **Fix status:** Fixed in the Python launcher and the OCaml stdio server. A
  parsed `C2C_MCP_CLIENT_PID` is now used only when `/proc/<pid>` exists;
  otherwise startup registration falls back to the live parent process. The
  OCaml regression suite covers both live explicit pid preference and dead env
  fallback.
- **Severity:** High for Kimi live delivery. A dead broker pid makes direct
  sends reject the alias as not alive and prevents live idle-delivery proofs.
