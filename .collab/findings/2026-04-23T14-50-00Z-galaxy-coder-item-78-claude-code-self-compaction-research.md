# Item 78 Research: Claude Code Self-Compaction

## What item 78 asks for
Claude agents should compact when above 250k tokens of context. Need to understand how Claude Code supports programmatic self-compaction.

## Key findings

### 1. Current compaction triggers in Claude Code

| Trigger | Mechanism | Agent-controllable? |
|---------|-----------|-------------------|
| Automatic | Claude Code compacts when ~95% context used | NO |
| Manual | `/compact` slash command (user types) | NO |
| Hook-based | `PreCompact`/`PostCompact` hooks fire AROUND compaction | NO (can't trigger) |

### 2. Existing c2c integration (already working)
- `c2c-precompact.sh` → fires on PreCompact → `c2c set-compact --reason "context-limit-near"`
- `c2c-postcompact.sh` → fires on PostCompact → `c2c clear-compact`
- These work for **automatic compaction** events

### 3. Gap: No programmatic trigger exists
Confirmed by GitHub issue #38925 (filed Mar 25, 2026):
- Hooks cannot trigger compaction — only react to it
- No tool or CLI flag to trigger `/compact` programmatically
- Statusline exposes `context_window.used_percentage` but can't act on it
- Requested API: `{"hookSpecificOutput": {"action": "compact"}}` — not implemented

### 4. What agents CAN do
- Monitor context via statusline (`context_window.used_percentage`)
- Set compacting flag before auto-compaction (already wired)
- Clear compacting flag after (already wired)
- **Cannot trigger compaction on demand**

## Assessment

**Item 78 as stated (agent triggers compaction at 250k tokens) is NOT FEASIBLE.**

Claude Code does not expose a programmatic compaction trigger. Agents must wait for automatic compaction (~95% context) or rely on manual `/compact`.

## What IS possible

1. **Automatic compaction coverage** — PreCompact/PostCompact hooks already properly mark agents as compacting. When Claude Code auto-compacts, c2c peers receive the warning.

2. **Context monitoring** — A hook could monitor `context_window.used_percentage` and emit warnings, but this is advisory only.

3. **Upstream request** — Issue #38925 is open requesting programmatic compaction trigger. If/when Anthropic implements `hookSpecificOutput.action: "compact"`, this becomes feasible.

## Recommendation

Close item 78 as NOT FEASIBLE (current Claude Code limitations). Document that:
- c2c compacting-status integration WORKS for automatic compaction
- Agents cannot trigger compaction on demand
- Feature request filed upstream (GitHub #38925)

If proactive compaction is critical, consider:
- Using Opus (200k context) instead of Sonnet (100k) for long-running tasks
- Designing agent workflows that avoid accumulating 250k+ tokens in single session
