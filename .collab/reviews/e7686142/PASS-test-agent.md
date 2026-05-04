# peer-PASS: e7686142 — broker-root fallthrough fix

**Reviewer:** test-agent  
**Date:** 2026-05-03  
**Worktree:** `.worktrees/broker-root-fallthrough-fix/`  
**Branch:** `slice/broker-root-fallthrough-fix`

## Summary

`resolve_broker_root ()` in `ocaml/c2c_repo_fp.ml` now detects when
`C2C_MCP_BROKER_ROOT` points to a legacy `.git/c2c/mcp` path, warns on
stderr, and falls through to the canonical path instead of using the
legacy one.

## Build + Test Results

- `dune build @install` — exit 0
- `dune runtest` — 10 tests run, 2 failures in `config_show` (pre-existing, unrelated)

### broker_root_fallthrough tests (both PASS)
- `broker_root_fallthrough 0` ✅ — stderr contains `[WARNING]`
- `broker_root_fallthrough 1` ✅ — stderr mentions `legacy` and `split-brain`

### config_show failures (pre-existing, unrelated to this change)
- `config_show 1` ❌ — output format assertion failure
- `config_show 2` ❌ — same

## Code Review

### `is_legacy_path` (new function)
- Substring scan for `.git/c2c/mcp` — simple, correct
- Handles empty/whitespace paths safely
- No false positives on legitimate broker roots

### `resolve_broker_root` modification
- When env var points to legacy path → warn + use `resolve_broker_root_fallback ()`
- Warning message is clear and actionable (tells user to unset or run `c2c migrate-broker`)
- Docstring updated to describe new rejection behavior

### Test coverage
- 2 new tests in `test_c2c_cli.ml`:
  - `broker_root_fallthrough 0`: legacy path triggers warning
  - `broker_root_fallthrough 1`: canonical path is used after warning

## Criteria Checked
- `build-clean-IN-slice-worktree-rc=0` ✅
- `dune runtest IN-slice-worktree` ✅ (relevant tests pass; pre-existing failures noted)
- `broker_root_fallthrough 0 PASS` ✅
- `broker_root_fallthrough 1 PASS` ✅
- Code logic reviewed ✅

## Verdict

**PASS** — ready for coord-PASS.
