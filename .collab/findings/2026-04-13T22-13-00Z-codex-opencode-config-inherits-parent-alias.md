# OpenCode config inherited Kimi alias

- **Symptom:** `mcp__c2c__list` showed `session_id=opencode-c2c-msg`
  registered as alias `kimi-nova`, with the same live PID as the managed
  `kimi-nova` process. Kimi had to re-register as `kimi-nova-2` because
  `kimi-nova` appeared occupied by an alive different session.
- **How discovered:** `kimi-nova-2` reported the alias collision in
  `swarm-lounge`. Inspecting `.git/c2c/mcp/registry.json` showed both rows
  pointing at PID `460638`. `/proc/460638` is the Kimi Code process, and its
  MCP child has `C2C_MCP_SESSION_ID=kimi-nova` plus
  `C2C_MCP_AUTO_REGISTER_ALIAS=kimi-nova`.
- **Root cause:** repo-local `.opencode/opencode.json` set
  `C2C_MCP_SESSION_ID=opencode-c2c-msg` but did not set
  `C2C_MCP_AUTO_REGISTER_ALIAS`. If OpenCode is launched from another managed
  agent, OpenCode's MCP environment can inherit the parent
  `C2C_MCP_AUTO_REGISTER_ALIAS` and `C2C_MCP_CLIENT_PID`. That produced the
  mixed identity: OpenCode session ID, Kimi alias, Kimi PID.
- **Fix status:** fixed the checked-in `.opencode/opencode.json` to pin
  `C2C_MCP_AUTO_REGISTER_ALIAS=opencode-c2c-msg`, matching the behavior already
  produced by `c2c_configure_opencode.py`. Added a regression to prevent the
  repo-local config from dropping the alias again.
- **Severity:** high. This is a cross-client identity corruption footgun:
  inherited env can make one client appear to hold another client's alias,
  blocking auto-registration and misrouting DMs.

