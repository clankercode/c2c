# Permission DM Auto-Reject-Despite-In-Window Approve

**Co-filers**: coordinator1 + birch-coder
**Date**: 2026-04-29
**Status**: OPEN — protocol gap identified (2026-05-04 triage). The supervisor's "approve" via `c2c send` is a DM — it does NOT interact with the `open_pending_reply` / `check_pending_reply` MCP pending-permission state. The pending entry's `expires_at` check in `find_pending_permission` (c2c_broker.ml:508) requires a supervisor to call `check_pending_reply` to mark the entry resolved (`mark_pending_resolved`). Sending a DM enqueues a message but leaves the pending entry untouched, so it expires on schedule regardless. This is a design gap between the DM-based approval workflow and the MCP pending-permission mechanism, not a timing bug. The #490 approval-side-channel (file-based approval-pending/verdict dirs) was built to address this class of issue with a separate mechanism. Needs design review to determine if `open_pending_reply`/`check_pending_reply` should be deprecated in favor of #490's approach, or if the pending_reply flow should be updated to consume approve DMs.

---

## Summary

Permission requests sent via `open_pending_reply` + `check_pending_reply` are being auto-rejected by the broker even when the supervisor's approve-once arrives WITHIN the TTL window. The supervisor's approve DMs DO enqueue successfully (`c2c send` returns `queued:true`), but the broker still treats the permission as timed out when the agent checks.

## Symptom

1. Agent A sends a permission request to coordinator1 via `open_pending_reply`
2. Coordinator1 approves within the TTL window (confirmed: `c2c send` returned `queued:true`)
3. Agent A's `check_pending_reply` returns rejection or times out
4. Broker auto-rejects despite coordinator1's approve being sent in-window

## Reproductions

| # | Perm ID | Supervisor | TTL | Approve send result |
|---|---------|------------|-----|---------------------|
| 1 | per_dd8b93102001JcxHqDs8n5iBxd | coordinator1 | 600s | `queued:true` |
| 2 | per_dd8bae8ae001NcXDK8XK71WqEj | coordinator1 | 600s | `queued:true` |
| 3 | per_dd8bb4d53001NZiheaMIO5zSmx | coordinator1 | 600s | `queued:true` |
| 4 | per_dd8c151bf001eCgw1JyCEG2WTl | coordinator1 | 600s | `queued:true` |
| 5 | per_dd8c15339001fAw0C6ZK4V9Am9 | coordinator1 | 600s | `queued:true` |

5/5 in-window approves auto-rejected. All approve-once (single-use) grants. All: `queued:true` confirms the approve DM was enqueued by the broker, yet the permission was still auto-rejected.

## Hypotheses

### H1: Clock skew
The broker stamps the approve-DM arrival time differently than the coordinator's send time. If the broker's clock is ahead, the 600s window may appear expired from the broker's perspective even though the coordinator sent within window.

### H2: DM-delivery lag
During kimi-storm (high message volume), DM delivery may have taken enough time that the approve arrived after the broker's internal deadline check, despite being sent within the window.

### H3: Approve-once consumption race
The approve-once grant is consumed/expired prematurely on the broker side before the `check_pending_reply` arrives. Race between receive-approve and check-approve.

## Severity

High — permission system is unreliable for any time-sensitive operations. Async design is compromised if supervisors cannot trust that in-window approves will be honored.

## Status

Open. Needs investigation:
- Broker permission grant TTL logic (where exactly does the deadline check happen?)
- Clock-sync between broker instances
- Approve-once consumption race condition
- Whether `drain_inbox` ordering vs `check_pending_reply` ordering matters

## Related

- `.collab/findings/2026-04-29T00-00-00Z-birch-coder-stale-tmp-broker-dirs-test-isolation.md` (different issue)
- kimi dual-process: `.collab/research/2026-04-29-kimi-dual-process-independent-verify-birch.md`
