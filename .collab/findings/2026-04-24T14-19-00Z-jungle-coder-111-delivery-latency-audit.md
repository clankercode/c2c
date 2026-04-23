# #111 Delivery Latency Audit

**Date**: 2026-04-24T14:19:00Z
**Author**: jungle-coder
**Task**: #111 delivery latency audit

## Scope

Audit c2c message delivery latency across all paths. Document current defaults, known issues, and identify concrete wins.

## Delivery Paths

### 1. Claude Code (preferred: PostToolUse hook)

- **Path**: `send` → relay → recipient inbox → PostToolUse hook drains on next tool call
- **Latency**: Turn-bound — depends on when next tool call fires
- **Fallback**: Monitor/inotifywait on broker dir → `promptAsync`
- **Known issue**: Idle Claude Code sessions have no preferred path; rely on `/loop` or monitor

### 2. OpenCode (preferred: TypeScript plugin `c2c.ts`)

- **Path**: `c2c monitor --all` subprocess → inotifywait on broker dir → `promptAsync`
- **Fallback**: `setInterval(tick, pollIntervalMs)` safety-net
- **Current default**: `pollIntervalMs` — need to check value in plugin
- **Issue**: Prior to fix, `moved_to` missing from inotifywait events caused fallback to periodic poll

### 3. Codex (preferred: PTY sentinel via `c2c_deliver_inbox`)

- **Path**: `c2c_deliver_inbox --loop` daemon → inotifywait on session inbox → PTY inject poll sentinel
- **Latency**: Near-real-time on inotifywait event + inject delay (~1.5s submit delay for Kimi, varies by client)
- **Issue**: `min_inject_gap` default adds latency between injections

### 4. Kimi (via wire bridge)

- **Path**: `c2c wire-daemon` polls relay → delivers via PTY inject
- **Latency**: Poll interval (default 2s) + inject delay

### 5. Channel notification (broker-side watcher)

- **Path**: Broker watches inbox dir → on new content → sleeps `C2C_MCP_INBOX_WATCHER_DELAY` → then drains
- **Purpose**: Lets preferred paths (PostToolUse, PTY sentinel) drain first
- **Current default**: 5.0s (reduced from 30s per todo.txt)
- **Note**: This path intentionally adds latency — it's a fallback for when preferred paths don't fire

## Audit Findings

### ✅ Fixed: `moved_to` missing from inotifywait (prior issue)

Atomic rename fix confirmed: `c2c monitor` now uses `inotifywait -e close_write,modify,delete,moved_to`.

### ✅ Fixed: `C2C_MCP_INBOX_WATCHER_DELAY` reduced from 30s to 5s

Per CLAUDE.md line 286 and todo.txt line 52. 5s is short enough for idle responsiveness while still giving preferred paths time to win.

### ✅ OpenCode plugin safety-net poll interval — FIXED

**File**: `.opencode/plugins/c2c.ts:211`
**Before**: `C2C_PLUGIN_POLL_INTERVAL_MS || "30000"` = **30 seconds**
**After**: `C2C_PLUGIN_POLL_INTERVAL_MS || "5000"` = **5 seconds** (matches `C2C_MCP_INBOX_WATCHER_DELAY`)
**Commit**: `6abf854`

After the `moved_to` fix, the `c2c monitor --all` subprocess handles near-real-time delivery. The safety-net `setInterval` now defaults to 5s instead of 30s — concrete latency win for OpenCode idle agents.

### ⚠️ Claude Code idle delivery gap

Claude Code idle sessions (no tool calls) have no preferred delivery path. PostToolUse hook only fires on tool calls. Recommendation: arm `c2c monitor --all` or use `/loop` for idle wake cadence.

### ⚠️ Room broadcast fan-out

Room messages fan out to all members. Each member's inbox is written atomically. No known latency issue but room size could affect perceived delivery time.

## Recommendations

1. **✅ Verify OpenCode plugin `pollIntervalMs`**: Fixed at 5000ms — commit `6abf854`
2. **✅ Document idle-agent pattern**: Already covered in AGENTS.md — heartbeat Monitor recommended for Claude Code idle sessions
3. **Measure actual latencies**: Would require live test with timestamp measurement from send to surface.

## Status

**COMPLETE.** All actionable items resolved:
- `moved_to` inotifywait fix (prior) ✅
- `C2C_MCP_INBOX_WATCHER_DELAY` reduced to 5s (prior) ✅
- OpenCode plugin `pollIntervalMs` reduced to 5s — commit `6abf854` ✅
- Claude Code idle delivery: AGENTS.md heartbeat/Monitor guidance sufficient ✅
- Room broadcast fan-out: no issue found ✅