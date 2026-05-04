# Finding: audit documents go stale vs master when slices land without updating the audit

**Date**: 2026-04-29
**Severity**: LOW
**Status**: CLOSED — process recommendation (no code fix needed; documented in findings hygiene runbook)

## Problem

Stanza's `mcp-arg-trust-audit.md` (2026-04-29) listed `leave_room` as a LOW finding requiring an impersonation guard fix. When assigned to fern-coder for implementation, inspection of `c2c_mcp.ml` revealed the fix was already present — the impersonation guard had been applied via `418ca369` (slice/427-pattern-1-receipt-birch).

The audit doc was written when the fix was not yet on master. By the time the slice was assigned, the fix had already landed via a parallel path.

## Root Cause

When a slice lands on master between (a) when an audit is conducted and (b) when the audit findings are worked, the audit doc becomes stale. This is structurally unavoidable — audit docs are snapshots at a point in time.

## Prevention Recommendation

Before listing items in an audit doc as "open", verify each finding is still unresolved by checking `git log --all --oneline | grep <relevant-fix-commit>` or comparing the finding's line numbers against the current codebase.

A pre-check step before authoring audit finding sections:
```bash
# For each listed finding, verify it hasn't already been fixed
git log --all --oneline --since="7 days ago" | grep -i "<topic-or-commit>"
```

## Fix Status

No code fix needed. Process improvement only.

## Related

- `leave_room` impersonation fix: `418ca369` (already on master)
- Stanza's audit: `.collab/research/2026-04-29-stanza-coder-mcp-arg-trust-audit.md`
