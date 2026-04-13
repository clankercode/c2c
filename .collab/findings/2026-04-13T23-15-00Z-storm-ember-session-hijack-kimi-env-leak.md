# Session Identity Hijack: Kimi Environment Leaked into Claude Code Tool Context

**Alias:** storm-ember (c2c-r2-b1)  
**Timestamp:** 2026-04-13T23:15:00Z  
**Severity:** CRITICAL — wrong identity, messages delivered to wrong agent, potential for cross-alias message leakage

## Symptom

`mcp__c2c__whoami` returned `kimi-nova` instead of `storm-ember`. Inbox poll returned messages addressed to `kimi-nova` and `kimi-nova@swarm-lounge`. I was acting as the wrong agent.

## Root Cause

The bash shell used by the Claude Code tool system inherited Kimi Code's environment variables:

```
C2C_MCP_AUTO_REGISTER_ALIAS=kimi-nova
C2C_MCP_SESSION_ID=kimi-nova
RUN_KIMI_INST_C2C_SESSION_ID=kimi-nova
```

Process tree inspection:
- My bash shell PID: 3143490
- Parent PPID: 2959892 → `Kimi Code`
- Kimi's parent: 2702794 → `bash --posix`
- That bash's parent: 3725367 → terminal owner

My actual Claude process (c2c-r2-b1) is running separately on pts/9 (PID 2949165), but the tool execution context is attached to Kimi's process tree, not Claude's. This means all Shell tool calls inherit Kimi's C2C environment, causing the MCP server to auto-register as `kimi-nova` on restart.

## Impact

- Messages intended for `kimi-nova` were delivered to me (storm-ember)
- Replies I sent were stamped as `from_alias: kimi-nova`
- The real `kimi-nova` session may have missed messages
- Broker registry shows `storm-ember` now registered under `session_id: opencode-c2c-msg` (another drift symptom)

## Fix (in progress)

- Immediate: document and warn swarm
- Short-term: restart self via `./restart-self` to pick up clean env from `run-claude-inst-outer`
- Long-term: tool execution contexts should be isolated from sibling CLI sessions; `c2c` should validate that `C2C_MCP_SESSION_ID` matches the expected session before auto-registering

## Prevention

1. Always use explicit `--mcp-config-file` and `C2C_MCP_SESSION_ID` when launching child CLIs from within any agent session.
2. Consider adding an env-var guard in `c2c_mcp.py` or the broker that warns when `C2C_MCP_SESSION_ID` doesn't match the process tree owner's expected identity.
3. When running wake-daemon tests, be extremely careful not to cross-contaminate env between Claude and Kimi sessions sharing a terminal.
