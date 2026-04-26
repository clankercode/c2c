# SPEC: Message Delivery Latency — Symptom Survey & Concrete Wins

**Date:** 2026-04-24
**Author:** galaxy-coder
**Status:** implemented
**Shipped:** SHA 8171bc6 (watcher 5s→2s, poker 600s→180s)

## Context

Item #145 from Max (2026-04-23): audit and reduce message delivery latency across the c2c swarm. This doc surveys known symptom areas and proposes 2-3 concrete wins.

## Known Delivery Paths

### Preferred (push) paths — fast
| Client | Path | Latency |
|--------|------|---------|
| Claude Code | PostToolUse hook → `drain_inbox` on every tool call | ~immediate |
| OpenCode | `promptAsync` in c2c.ts plugin on inbox write | ~immediate |
| Kimi | Wire bridge JSON-RPC | ~immediate |
| Codex | PTY sentinel on inbox write | ~immediate |

### Fallback (polling) paths — slower
| Path | Interval | Notes |
|------|----------|-------|
| Channel-capable inbox watcher | 1s poll + configurable `C2C_MCP_INBOX_WATCHER_DELAY` (default 5s) | Drains only for `experimental.claude/channel`-capable clients |
| Poker heartbeat | 600s (10 min) | Keeps idle sessions alive; not a delivery path |
| Kimi wire bridge | Configurable poll interval | Falls back if JSON-RPC push fails |

## Symptom Areas

### 1. Inbox watcher delay (5s default)
**Current behavior:** When the channel-capable inbox watcher detects new content, it sleeps `C2C_MCP_INBOX_WATCHER_DELAY` (default 5s) before draining and emitting `notifications/claude/channel`. The delay gives preferred paths (PostToolUse, promptAsync) time to drain first.

**Problem:** For truly idle agents with no preferred path, messages wait 5s before the watcher drains them. This is especially impactful for room broadcasts — idle agents see room messages 5s late.

**Fix:** Reduce default from 5s → 2s. The 5s was calibrated when the watcher was unconditionally draining; since commit 6946b07 the watcher gates on `channel_capable_ref`, so it only drains when no preferred path exists. 2s is short enough to keep idle agents responsive while still giving active agents' preferred paths time to win.

### 2. Poker interval (600s default)
**Current behavior:** `C2c_poker.start` fires every 600s to keep idle sessions alive via PTY injection (Claude Code only).

**Problem:** 10 minutes between pokes is very long. If a session goes idle between pokes, messages queue until the next heartbeat.

**Fix:** Reduce from 600s → 180s (3 min). Still infrequent enough not to be noisy, but 3x more responsive than 10 min. Poker is a no-op for OpenCode/Kimi/Codex — this only affects Claude Code idle sessions.

### 3. Room broadcast fan-out — all inboxes written sequentially
**Current behavior:** `send_room` writes to each member's inbox file sequentially, one at a time.

**Problem:** With N room members, the last member's inbox is written N times later than the first. For a 20-member room this could mean ~200ms of skew if each write takes 10ms.

**Fix (deferred):** This is architectural — would need async inbox writes or batch writes. Not a quick win. Filed as a future optimization.

### 4. Outer-loop restart window
**Current behavior:** When a managed client restarts, there's a gap where messages queue in the broker's inbox before the session re-registers.

**Problem:** Depends on the client's startup time. OpenCode/Kimi are fast (~1s); Claude Code with cold start can be 10-30s.

**Fix:** On re-registration, the broker already re-delivers queued messages. The gap is unavoidable but minimized by fast startup. Not a code latency issue.

## Proposed Concrete Wins

### Win 1: Reduce `C2C_MCP_INBOX_WATCHER_DELAY` default 5s → 2s

**File:** `ocaml/server/c2c_mcp_server.ml` line 66
**Change:** `| None -> 5.0` → `| None -> 2.0`

**Impact:** -3s for every idle channel-capable recipient (room broadcasts, DMs to idle OpenCode/Kimi). No downside — the delay only matters if preferred paths exist, and if they drain first, the watcher sees unchanged inbox and skips drain anyway.

**Verification:** `c2c doctor` shows current value; set `C2C_MCP_INBOX_WATCHER_DELAY=2` to override.

### Win 2: Reduce poker interval 600s → 180s

**File:** `ocaml/c2c_poker.ml` line 14
**Change:** `?(interval : float = 600.0)` → `?(interval : float = 180.0)`

**Impact:** Idle Claude Code sessions get wake pokes 3x more often. Messages to idle Claude Code peers arrive within 180s instead of up to 600s.

**Note:** Poker is Claude Code only (PTY injection). OpenCode/Kimi/Codex don't use it.

### Win 3: Add per-client channel_capability detection logging

**File:** `ocaml/server/c2c_mcp_server.ml`
**Change:** Log when a client connects with/without Claude_channel capability. Currently no visibility into which clients are using the watcher vs preferred paths.

**Impact:** No direct latency improvement, but enables operators to see delivery path assignments and tune delays per-client. Reduces debug friction for delivery issues.

**Example log output:**
```
[c2c mcp] client connected with channel_capable=true — using fast path
[c2c mcp] client connected with channel_capable=false — using watcher fallback (delay=2.0s)
```

## Out of Scope (Post-M1)
- Room fan-out async writes
- inotifywait-based immediate wake (Monitor tool is the right shape; this is already how idle agents get woken)
- Remote relay latency (broker-to-broker)
- Cross-datacenter optimization

## Verification Plan
After implementing wins 1+2:
1. Send a DM to an idle OpenCode peer → verify arrival via timestamp in `c2c history`
2. Send a room broadcast → verify all members receive within 5s (new watcher delay)
3. Check `c2c doctor` shows updated defaults
4. Dogfood: observe idle-agent responsiveness over 24h

## Open Questions
1. Is 2s watcher delay low enough, or should it be 1s? 1s is aggressive for large rooms (might cause preferred-path races).
2. Should Kimi wire bridge poll interval also be reduced? Currently unknown — needs investigation.
3. Should we add a delivery-latency metric to `c2c doctor`? (e.g., "last message delivered Ns ago")
