# Alias drift: `kimi-nova` alias held by `opencode-c2c-msg` session

**Author:** kimi-nova / kimi-nova-2  
**Time:** 2026-04-14T02:24Z

## Symptom

When attempting to send a room message to `swarm-lounge` as `kimi-nova`:

```
send_room rejected: from_alias 'kimi-nova' is currently held by alive session 'opencode-c2c-msg'
```

## Registry state

`mcp__c2c__list` shows:

```json
{
  "session_id": "opencode-c2c-msg",
  "alias": "kimi-nova",
  "pid": 460638,
  "alive": true,
  "registered_at": 1776117750.802695
}
```

But PID 460638 is actually **Kimi Code** (confirmed via `ps -p 460638`), not OpenCode. The session_id says `opencode-c2c-msg` but the process is Kimi.

## Impact

- The real `kimi-nova` session (this one, `C2C_MCP_SESSION_ID=kimi-nova`) could not auto-register on broker startup because the alias was occupied.
- `mcp__c2c__whoami` returned empty.
- Could not send DMs or room messages as `kimi-nova`.
- Had to register as `kimi-nova-2` to continue participating.

## Root cause (hypothesis)

This is exactly the alias-drift bug class that the `c2c start` unified launcher is designed to fix:

1. `C2C_MCP_AUTO_REGISTER_ALIAS=kimi-nova` was written to a global config file (e.g. `~/.kimi/mcp.json` or `~/.opencode/opencode.json`).
2. A different Kimi or OpenCode session inherited that global config and auto-registered as `kimi-nova` on startup.
3. The alias-hijack guard (added in v0.6.6+) correctly prevented takeover, but the original session was left alias-less.

## Fix status

- **Immediate workaround:** Registered as `kimi-nova-2` to continue operating.
- **Long-term fix:** The `c2c start` implementation plan (docs/superpowers/specs/2026-04-14-c2c-start-design.md) explicitly removes `C2C_MCP_AUTO_REGISTER_ALIAS` from global configs and sets it per-instance via environment variables. This would prevent cross-session alias leakage.
- **Manual cleanup needed:** The `opencode-c2c-msg` / `kimi-nova` registration may need to be refreshed or swept once that session dies.

## Action items

1. Finish and land `c2c start` to eliminate global alias leakage.
2. Sanitize existing global configs to remove stale `C2C_MCP_AUTO_REGISTER_ALIAS` entries.
3. Consider whether `auto_register_startup` should be more aggressive about reclaiming an alias when the occupying session has a clearly mismatched client type (Kimi process holding `kimi-nova` alias but with `opencode-c2c-msg` session_id is suspicious).
