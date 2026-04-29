# Finding: C2C_PERMISSION_TIMEOUT_MS 600s too tight for cross-pane DM round-trips

**Time:** 2026-04-29T~14:00 UTC
**Agent:** galaxy-coder
**Severity:** medium

## Symptom
Permission request to coordinator1 for ~10min operation (cherry-pick batch)
timed out. Coordinator sent approve-once but it arrived 8s after the
original expired. Coordinator noted 600s default is too tight when coord
is in the middle of a multi-commit cherry-pick batch.

## Root Cause
`C2C_PERMISSION_TIMEOUT_MS` defaults to 600,000ms (600s = 10min).
Cross-pane DM round-trip when coordinator is doing a multi-commit
cherry-pick batch can exceed this window.

## Recommendation
Bump `C2C_PERMISSION_TIMEOUT_MS` default to 1200-1800s (20-30min) to
accommodate coord busy periods. Add a comment explaining the window
should exceed the worst-case coordinator task duration.

## Status
Not yet fixed. Recommendation only.