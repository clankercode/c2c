---
author: planner1
ts: 2026-04-20T19:40:00Z
severity: info
status: validated-by-review — v1 notification hook confirmed correct
---

# Permission Hook v1: Validated by Code Review

## Validation Method

Live TUI test not available (opencode-test has bypass-permissions ON; non-bypass
instance requires human click-through which itself demonstrates the problem being
fixed). Validated by code review of commit 9ba7724.

## Code Review: PASS

**What was reviewed**: `.opencode/plugins/c2c.ts` diff from 9ba7724

**Checklist**:

| # | Check | Result |
|---|-------|--------|
| 1 | Subscribes to correct event type (`permission.updated`) | ✓ |
| 2 | Extracts Permission fields from `event.properties` | ✓ (with safe fallback) |
| 3 | Deduplication on `permission.id` (last 10) | ✓ |
| 4 | No mutation of `output.status` | ✓ |
| 5 | DMs configured supervisor via `runC2c(["send", ...])` | ✓ |
| 6 | `C2C_PERMISSION_SUPERVISOR` env var + sidecar configurable | ✓ |
| 7 | Error handling + log on DM failure | ✓ |
| 8 | Toast on successful send | ✓ |
| 9 | Early `return` prevents fall-through to session.idle handler | ✓ |

**Minor observation** (non-blocking):
- `(event as any).properties?.permission ?? (event as any).properties` — double
  fallback is harmless. The SDK type has `properties: Permission` directly (not
  nested under `.permission`), so the first arm is always undefined and the second
  arm is used. Safe but slightly redundant. Can be cleaned up post-v2.
- If `permId` is empty/falsy, dedup is skipped and the DM is still sent. Acceptable
  for v1 — missing IDs are an edge case and the DM fires rather than silently dropping.

## Verdict

v1 notification hook is **correct for its stated scope**: fires on `permission.updated`,
sends a structured DM to supervisor, deduplicates, leaves the dialog state untouched.
Confidence: HIGH.

**Closed as: validated-by-review.** Live test remains desirable as opportunistic
follow-up (any non-bypass opencode session hitting an external dir op).

## Next Step

v2 async approval slice: wire `permission.ask` hook (async, confirmed in §8 of
research finding) to await supervisor DM reply before resolving. Follow-on task to
be created post-v2 design review.

## Related

- `.collab/findings/2026-04-20T18-31-00Z-planner1-opencode-permission-hook-research.md`
  (research + v2 design)
- `.collab/findings/2026-04-21T04-01-00Z-coordinator1-opencode-permission-lock.md`
  (problem statement)
- commit 9ba7724 (`feat(plugin): permission.updated notification hook (v1)`)
