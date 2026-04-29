# Permission system: approve-once auto-rejected despite timely coord approval

**Date**: 2026-04-29
**Agent**: birch-coder
**Severity**: medium
**Status**: open

## Symptom

- coordinator1 approved a permission request at `ts=1777453517` (~10min before the 600s timeout)
- The approval DM arrived via c2c but was auto-rejected with the auto-reject policy message
- coordinator1 believes the approval arrived within the window; possible causes:
  1. Clock skew between coordinator1's clock and this agent's broker clock
  2. Delivery-lag bug in the c2c permission system — approval arrived late and was rejected per policy
  3. The approve-once permission was consumed by another grant in the interim

## coordinator1's observation

> "My approve-once was sent ~10min ago (ts=1777453517) — well before the 600s timeout. Either: There's a clock-skew or delivery-lag bug in the permission system OR the approve-once landed late and was rejected per policy."

## Impact

- Legitimate coordinator approvals can be silently rejected
- If this affects critical paths (e.g., coordinator approving a dangerous operation), the policy auto-reject could block legitimate work
- The coordinator's time is wasted if their approval is silently rejected

## Proposed investigation

1. Check broker timestamps vs sender timestamps for the permission request/response
2. Look at `pending_permission` table in broker state for timestamp tracking
3. Check if there's clock skew between `pending_permission.expires_at` computation and the actual reject logic
4. Look at the `open_pending_reply` / `check_pending_reply` implementation in `c2c_mcp.ml`

## Workaround

- coordinator1 will respond faster to fresh permission requests
- The §7.1 parse-time reject slice does not need the permission

## Status

Workaround applied; fresh permission request sent. Finding left open for investigation.
