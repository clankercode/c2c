# Kimi MCP Startup Blocked In Dune Build

- **Symptom:** After restarting the managed `kimi-nova` TUI, the broker still
  did not retain a live `kimi-nova` registration. The Kimi MCP wrapper process
  was alive, but its only child was a long-running `dune build` and no OCaml MCP
  server had started.
- **Discovery:** `/proc` showed `python3 c2c_mcp.py` under the live Kimi pid
  with `C2C_MCP_SESSION_ID=kimi-nova`, while `pgrep -P` showed it blocked under
  `dune build --root ... ./ocaml/server/c2c_mcp_server.exe`. The broker registry
  either omitted `kimi-nova` or briefly showed a dead one-shot registration from
  another client.
- **Root cause:** `c2c_mcp.py` ran `dune build` synchronously with no timeout
  before launching the OCaml server. If the build blocked behind another Dune
  process or lock, the MCP server never came online. The wrapper also preserved
  an inherited stale `C2C_MCP_CLIENT_PID` when launching the OCaml server, so
  even a later server start could receive stale client metadata.
- **Fix status:** Fixed and live-verified. The wrapper now sanitizes
  `C2C_MCP_CLIENT_PID` before spawning the server and applies a bounded build
  timeout; if a built binary already exists, timeout/failure falls back to that
  binary with a stderr warning. After restarting `kimi-nova`, the OCaml server
  env had `C2C_MCP_CLIENT_PID=3679625` and the broker row registered
  `kimi-nova` at live pid `3679625`.
- **Live proof note:** A direct Codex -> Kimi DM was delivered broker-native and
  Kimi replied with `KIMI_LIVE_MCP_PID_OK`. The first notify-only direct-PTS
  nudge did not drain the inbox within 25 seconds; a later master-side
  `pty_inject` nudge with a 1.5s submit delay did wake Kimi. Treat this as MCP
  registration and broker-native DM proof, not as clean evidence that direct
  PTS wake is sufficient by itself.
- **Severity:** High for live client delivery. A blocked MCP startup makes the
  agent appear present in the TUI while broker-native tool delivery never becomes
  available.
