# Kimi Wire Child PID Clobbered Durable Registration

- **Symptom:** `./c2c status --json` temporarily dropped `kimi-nova-2` from the
  alive peer list, leaving `swarm-lounge` at 4/5 alive. The Wire daemon was
  still running at pid `709877`, but the broker registration for session
  `kimi-nova` / alias `kimi-nova-2` pointed at dead pid `734646`.
- **Discovered by:** Heartbeat resume status check after the duplicate-PID
  health work.
- **Root cause:** The persistent Kimi Wire daemon launches short-lived
  `kimi --wire` subprocesses for delivery. Their generated MCP config included
  `C2C_MCP_SESSION_ID` and `C2C_MCP_AUTO_REGISTER_ALIAS`, but did not set
  `C2C_MCP_CLIENT_PID`. When the child MCP server auto-registered, it used the
  short-lived child process identity and overwrote the durable daemon PID.
- **Immediate mitigation:** Refreshed `kimi-nova-2` back to the live Wire daemon
  pid with `./c2c refresh-peer kimi-nova-2 --pid 709877 --json`; `swarm-lounge`
  returned to 5/5 alive.
- **Fix status:** Fixed in `c2c_kimi_wire_bridge.py`. Generated Kimi Wire MCP
  configs now set `C2C_MCP_CLIENT_PID` to the bridge process PID, so child MCP
  auto-registration refreshes the broker row to the durable bridge/daemon
  process rather than the short-lived `kimi --wire` child.
- **Severity:** Medium. Delivery still worked when manually refreshed, but the
  room liveness signal could drop and future sends could route to a dead PID
  until an agent noticed and repaired it.
