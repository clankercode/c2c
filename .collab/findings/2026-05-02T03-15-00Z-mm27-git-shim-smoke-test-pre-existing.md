# Finding: git-shim.sh smoke test fails when sourced (pre-existing, #615)

**Date:** 2026-05-02T03:15:00Z
**Severity:** LOW
**Tags:** git-shim, smoke-test, pre-existing

## Symptom
`bash -c 'source git-shim.sh && echo "smoke OK"'` fails with:
```
git-shim.sh: line 68: $1: unbound variable
exit: 127
```

## Discovery
Running the smoke test as part of SHA `216494ae` peer review revealed the failure.
Checked parent commit `8ce1e7c1` — same failure exists there. Not introduced by #615.

## Root Cause
Line 68 is inside `main()` function: `case "$1" in`. With `set -u` (which this shim has),
referencing an unbound `$1` causes the error. When sourced, `main "$@"` at line 146
is called with no arguments, causing the failure.

## Why it's pre-existing
- Parent commit `8ce1e7c1` has the exact same file structure and the same issue
- The smoke test pattern `source git-shim.sh && echo "smoke OK"` is not a valid test
  for this file — it defines functions and calls `main "$@"` which requires arguments
- The correct smoke test would be `bash git-shim.sh --help` or similar

## Fix Status
Not fixed. Not in scope of #615 (birch's hot-path fix).

## Notes
- The actual shim works correctly when invoked normally (via `git` command with args)
- The `set -u` behavior is intentional — it catches real argument errors
- A proper smoke test would invoke the shim as a command, not source it
