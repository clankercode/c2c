# Kimi MCP Auto-Register Reverted To A Dead PID

- **Symptom:** `mcp__c2c__list` repeatedly showed `kimi-nova` registered at
  dead pid `2959892`, even after `c2c_refresh_peer.py kimi-nova --pid 3591998`
  updated the broker registry to the live Kimi process.
- **Discovery:** The live `c2c_mcp.py` child under Kimi had
  `C2C_MCP_SESSION_ID=kimi-nova` and `C2C_MCP_CLIENT_PID=2959892` in its
  environment. Its actual parent process was the live Kimi TUI pid `3591998`.
- **Root cause:** `c2c_mcp.current_client_pid_from_env` trusted
  `C2C_MCP_CLIENT_PID` whenever it parsed as an integer. If a restored or
  long-lived Kimi session inherited a stale value, `maybe_auto_register_startup`
  wrote that dead pid back into the broker on MCP startup.
- **Fix status:** Fixed in `c2c_mcp.py`. A parsed `C2C_MCP_CLIENT_PID` is now
  used only when `/proc/<pid>` exists; otherwise the wrapper falls back to
  `os.getppid()`, which is the live host client process for Kimi's MCP child.
- **Severity:** High for Kimi live delivery. A dead broker pid makes direct
  sends reject the alias as not alive and prevents live idle-delivery proofs.
