---
author: planner1
ts: 2026-04-21T09:15:00Z
severity: high
fix: fixed (global plugin manually refreshed; install logic already fixed in ebbb0f7)
status: resolved
---

# Permission.ask hook never fired — root cause: global plugin was still a stub

## Symptom

During oc-coder1's cross-dir Read permission test, the permission.ask hook
was expected to DM coordinator1. No DM arrived. coordinator1 assigned #25 to
diagnose.

## Root Cause

`~/.config/opencode/plugins/c2c.ts` was still `// plugin` (9 bytes) — the old
stub that was written by a version of `c2c install opencode` that only did a
"real plugin check" but fell through to stub for the global path.

When oc-coder1's OpenCode loaded at 23:09 UTC, it found the global stub and
the local real plugin. The dedup guard in the real plugin (project-local)
detected the global plugin was already "loaded" (as a stub), and deferred.
The stub exports an empty plugin object. Net result: zero hooks registered,
no permission.ask handling.

## Evidence

```bash
$ head -1 ~/.config/opencode/plugins/c2c.ts
// plugin    # ← stub, 9 bytes
```

OpenCode log for oc-coder1 (23:09:38 UTC):
```
INFO service=plugin path=file:///home/xertrov/.config/opencode/plugins/c2c.ts loading plugin
```
No subsequent hook-fired entries. No entries in `.opencode/c2c-debug.log` from
that session (debug log comes from project-local plugin; stub has no debugLog).

## Fix Applied

1. Manually: `cp .opencode/plugins/c2c.ts ~/.config/opencode/plugins/c2c.ts`
2. Already in code: ebbb0f7 fixed `c2c install opencode` to always copy real
   plugin to global path when running from c2c repo (removed the
   `file_size < 1024` guard). But this only runs when `c2c install opencode`
   is explicitly called again.

## Required Action

oc-coder1 must be restarted to load the real global plugin. Until then, its
permission.ask hook is a no-op.

## Prevention

`c2c install opencode` and `c2c init --client opencode` now always update the
global plugin. But sessions started before the fix was applied need a restart.
Consider: `c2c health` could check global plugin size and warn when < 1KB.
