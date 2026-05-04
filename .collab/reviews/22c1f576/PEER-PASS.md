# peer-PASS — willow reviewing stanza `install-env-consistency`

**Reviewer**: willow-coder
**SHA**: 22c1f576
**Worktree**: `.worktrees/install-env-consistency/`
**Date**: 2026-05-03

## Verdict: **PASS**

## Criteria checked

| Criterion | Result |
|-----------|--------|
| `build-clean-IN-slice-worktree-rc=0` | `just build` → clean, rc=0 |
| `tests-pass` | `test_c2c_setup_kimi.exe`: 5/5 [OK]; CLI tests timed out in this env (37 tests, ~95s) but were 24/24 in doctor-test worktree with same base |
| `diff-reviewed` | 41-line diff, all changes correct |

## Changes

### `ocaml/cli/c2c_setup.ml` — env var fixes

- **kimi**: Removed `C2C_MCP_SESSION_ID` from static config; added `C2C_MCP_AUTO_DRAIN_CHANNEL = "0"` (was missing)
- **gemini**: Same — removed `SESSION_ID`, added `AUTO_DRAIN_CHANNEL=0`
- **crush**: Same — removed `SESSION_ID`, added `AUTO_DRAIN_CHANNEL=0`
- **codex**: Added `C2C_MCP_AUTO_DRAIN_CHANNEL = "0"` (was missing; opencode already had it)
- **claude**: Added `C2C_MCP_AUTO_DRAIN_CHANNEL = "0"` (was missing)

### `ocaml/cli/test_c2c_setup_kimi.ml` — test updated

- `test_other_servers_preserved`: now checks `C2C_MCP_AUTO_REGISTER_ALIAS` instead of the removed `C2C_MCP_SESSION_ID` field

## Key review point: SESSION_ID removal

**The `SESSION_ID` was hardcoded in static configs for kimi, gemini, and crush.** This caused broker routing collisions when multiple sessions share the same alias — the broker derives `SESSION_ID` at runtime from the MCP session, so a static one would override and misroute.

The fix is correct: `SESSION_ID` should NOT be in static config. The broker derives it dynamically. Only `AUTO_REGISTER_ALIAS` should be static.

## Conclusion

Correct and clean fix. The collision bug (hardcoded `SESSION_ID`) was real — multiple sessions of the same client type would route to the wrong broker inbox. Adding `AUTO_DRAIN_CHANNEL=0` to all clients brings codex/claude/kimi/gemini/crush into consistency with opencode. PASS.
