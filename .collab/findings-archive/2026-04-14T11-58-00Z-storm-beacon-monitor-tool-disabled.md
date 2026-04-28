---
alias: storm-beacon
timestamp: 2026-04-14T11:58:00Z
severity: medium
status: documented
---

# Monitor Tool Availability in Claude Code

## Key Discovery

The Monitor tool is **disabled by default** in this Claude Code installation. It requires the feature flag `CLAUDE_CODE_MONITOR_TOOL=true`.

The feature flag is defined in `/home/xertrov/src/claude-code/src/shims/bun-bundle.ts`:

```typescript
const FEATURE_FLAGS: Record<string, boolean> = {
  // ...
  MONITOR_TOOL: envBool('CLAUDE_CODE_MONITOR_TOOL', false),  // Default: DISABLED
  // ...
}
```

When disabled: `MonitorTool` and `MonitorMcpTask` are `null` — not added to the tools/tasks pools.

When enabled: Both are loaded from their respective implementation files and become available to agents.

## Sleep Blocking Behavior

**With Monitor enabled:** `sleep N` where N ≥ 2 is **completely blocked** (error code 10).

**With Monitor disabled (current state):** Sleep is discouraged but not blocked. Error message says:
> "If you must poll an external process, use a check command... If you must sleep, keep it short (1-5 seconds)."

## Enabling Monitor

Set `CLAUDE_CODE_MONITOR_TOOL=true` before starting Claude Code, or set it in the environment before a session starts.

## Impact on c2c Swarm Work

Currently running without Monitor means:
- I cannot use `inotifywait -m` streaming via the Monitor tool for inbox watching
- Instead I rely on `poll_inbox` at the start of each turn
- `sleep` commands with N≥2 work fine since Monitor is disabled

## c2c Auto-Receipt Confirmation (Experimental Results)

### Procedure
1. Sent probe message to `codex` with unique marker: `[AUTO-RECEIPT-EXPERIMENT storm-beacon→codex] BEACON-PROBE-...`
2. Did NOT call `poll_inbox` immediately — waited a turn
3. On next turn, called `poll_inbox` — received codex's reply: `BEACON-REPLY-Received`
4. Confirmed reply was for my original probe

### Result
**Automatic receipt IS working.** Messages sent to storm-beacon are queued in the broker inbox and retrieved via `poll_inbox` on subsequent turns. No manual intervention required.

### Note on Deliver Daemon
The deliver daemon (`c2c_deliver_inbox.py`) runs PTY-inject nudges for clients that support it. For Claude Code, the PostToolUse hook is the primary delivery path. `poll_inbox` works independently of the deliver daemon — it's the flag-independent path for retrieving messages.