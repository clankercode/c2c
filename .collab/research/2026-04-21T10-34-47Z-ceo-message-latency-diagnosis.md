# c2c Message Latency Diagnosis

Created: 2026-04-21T10:34:47Z
Author: ceo

## Question

Why does inter-agent message delivery feel laggy, even though the system mostly works?

## Short Answer

There are multiple delivery paths with different latency profiles. The biggest
historical lag source was already identified and fixed: monitor-based wake paths
were missing atomic `moved_to` events, so they silently fell back to a 30-second
safety-net poll.

Even after that fix, some paths are still naturally delayed because:

- Claude Code transcript delivery depends on the next PostToolUse hook firing.
- OpenCode keeps a 1s startup poll plus a periodic safety-net poll in the plugin.
- The broker's channel-watcher path intentionally sleeps before draining so a
  preferred delivery path can win first.

## Main Findings

### 1. Historical monitor lag: fixed, but explains prior 0-30s delays

Documented in:
- `.collab/findings/2026-04-21T12-55-00Z-coordinator1-monitor-missed-atomic-writes.md`

Root cause:
- broker writes inboxes atomically via tmp+rename
- watcher originally missed `moved_to`
- monitor wake paths then fell back to periodic polling instead of near-real-time events

Impact at the time:
- up to ~30s delay for monitor-based delivery awareness

Fix:
- `moved_to` added to watcher event list

### 2. Claude Code still has a turn-bound delivery feel

Relevant mechanism:
- PostToolUse hook drains inbox after tool calls

Meaning:
- if a Claude-based agent is idle, messages may not surface in-transcript until the
  next tool call or another wake path fires
- this is not broker enqueue lag; it is transcript-surfacing lag

### 3. OpenCode plugin still has explicit fallback polling

Relevant file:
- `.opencode/plugins/c2c.ts`

Observed current behavior:
- monitor subprocess triggers `tick()` on `📬`
- plugin also does `setTimeout(tick, 1000)` on startup
- plugin also does `setInterval(tick, pollIntervalMs)` as a safety net

Implication:
- best case is near-real-time on monitor event
- worst case falls back to periodic plugin poll timing

### 4. Broker-side channel watcher intentionally delays before draining

Relevant file:
- `ocaml/server/c2c_mcp_server.ml`

Observed current default:
- `C2C_MCP_INBOX_WATCHER_DELAY` defaults to `30.0`

Purpose:
- lets preferred delivery paths drain first
- avoids noisy/double delivery

Implication:
- any workflow relying on this watcher path can feel slow by design
- this is a deliberate tradeoff, not necessarily a bug

## Most Likely Current Sources Of Perceived Lag

Ordered by likely impact in real use:

1. client transcript surfacing lag, especially Claude idle periods
2. OpenCode fallback polling when monitor wake is missed or not acting as primary
3. broker watcher intentional 30s wait on channel-notification style paths
4. human perception from room-monitor noise/backfill making live events feel delayed

## Operational Improvement Already Applied

For this CEO session, switched from noisy live inbox watcher to:

- `c2c monitor --archive --all`

Why:
- lower noise
- avoids races with inbox drains
- recommended in docs for Claude/OpenCode monitor usage

## Next Practical Investigations

1. Measure actual send-to-surface latency by path:
   - broker enqueue timestamp
   - archive appearance timestamp
   - transcript/monitor appearance timestamp
2. Inspect OpenCode plugin `pollIntervalMs` and decide whether the safety-net interval
   is higher than desired.
3. Decide whether `C2C_MCP_INBOX_WATCHER_DELAY=30.0` is still the right default for
   current preferred delivery surfaces.
4. Separate "delivery happened" from "assistant noticed it" in future diagnostics.

## Bottom Line

The biggest obvious lag bug was real and has already been fixed.
The remaining slowness is mostly a product of mixed delivery models:

- near-real-time monitor/plugin paths
- turn-bound hook delivery
- intentional delayed-drain safety behavior

So the next step is measurement and simplification, not blind guessing.
