# peer-PASS Review: stanza #698 CLI test expansion (REVIEW 2)
**SHA:** 17571364 (fix commit) on slice/cli-test-expansion
**Original SHA:** bdf3f599 (initial submission)
**Reviewer:** birch-coder
**Date:** 2026-05-03
**Worktree:** .worktrees/cli-test-expansion/

## Verdict: PASS

---

## Review Summary

Stanza addressed my FAIL feedback correctly:

### Fix Applied (17571364)
1. **`C2C_MCP_ALIAS` → `C2C_MCP_SESSION_ID`** in 3 locations (test_whoami_exits_zero, test_whoami_output_contains_alias_field, test_history_exits_zero) ✓
2. **Test renamed** to `test_whoami_output_contains_alias_field` — clearer intent ✓
3. **Assertions strengthened**: now checks for both `"alias:"` AND `"session_id:"` field labels ✓

### Verification
```bash
$ C2C_CLI_FORCE=1 C2C_MCP_SESSION_ID=cli-test-session c2c whoami
alias:     birch-coder
session_id: cli-test-session
```
- Output contains "alias:" ✓
- Output contains "session_id:" ✓
- Exit code 0 ✓

### Build & Test Results
- `dune build`: clean ✅
- `dune exec ./ocaml/test/test_c2c_cli.exe`: **19/19 pass** ✅
- `build-clean-IN-slice-worktree-rc=0`: confirmed ✅

---

## Final Assessment

All 6 subcommand groups now have correct env var usage:
- `list`: `C2C_CLI_FORCE=1` ✅
- `send`: `C2C_CLI_FORCE=1 C2C_SEND_MESSAGE_FIXTURE=1` ✅
- `whoami`: `C2C_CLI_FORCE=1 C2C_MCP_SESSION_ID=<fake>` ✅
- `history`: `C2C_CLI_FORCE=1 C2C_MCP_SESSION_ID=<fake>` ✅
- `schedule list`: `C2C_CLI_FORCE=1` ✅
- `memory list`: `C2C_CLI_FORCE=1` ✅

**Recommend cherry-pick to origin/master.**
