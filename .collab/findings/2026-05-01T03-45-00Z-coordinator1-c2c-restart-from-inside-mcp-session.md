# Finding: `c2c restart` from Inside MCP Session Leaves Alias Offline

**Severity:** MEDIUM
**Discovered by:** coordinator1 during #590 notifier restart
**Date:** 2026-05-01T03:45:00Z
**File:** `ocaml/cli/c2c_start.ml` (restart path)

## Symptom

Running `c2c restart <name>` from inside a C2C MCP session (e.g., from coordinator1's session):
1. Outer loop is killed cleanly ✅
2. `c2c start <client>` fails with: `error: cannot run 'c2c start' from inside a c2c session`
3. Alias goes offline — no recovery without manual tmux intervention

## Root Cause

`c2c start` has an internal guard that refuses to run from inside an existing C2C MCP session. The restart path calls `c2c start` as a subprocess to relaunch, but the parent's MCP session env vars (`C2C_MCP_SESSION_ID`, etc.) are inherited, triggering the guard.

## Fix

Two options:
1. **Refuse-before-kill:** `c2c restart` detects it is running inside an MCP session (checks for `C2C_MCP_SESSION_ID`) and refuses with a clear error message before killing the outer.
2. **Shell-out-via-clean-env:** `c2c restart` strips C2C MCP env vars before exec'ing `c2c start`, so the child doesn't see itself as inside a C2C session.

Option 2 preserves the restart functionality. Option 1 is simpler (~10 LoC) but less useful. Recommended: Option 2 (~30 LoC).

## Affected Path

`c2c_start.ml` — `restart_instance` or equivalent function that handles `c2c restart <name>`.

## Status

No fix applied yet. Manual recovery via tmux used by coordinator1.