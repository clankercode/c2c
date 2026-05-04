# peer-PASS: c14f2f26 + 29c2728f — #719 simultaneous-registration fix

**Reviewer:** test-agent
**Date:** 2026-05-03
**Worktree:** `.worktrees/fix-simultaneous-reg/`
**Branch:** `slice/fix-simultaneous-reg`

## Summary

Two commits fixing the docker-test "recipient is not alive" failure:
1. `c14f2f26` — `current_client_pid()` treats `"0"` as a sentinel meaning "use `Unix.getpid()`"
2. `29c2728f` — regression test for concurrent `session_id == alias` cross-contamination

## Build + Test Results

- `dune build @install` — exit 0
- `dune runtest` — **71 tests run, all pass** ✅

### Key tests verified
- `send concurrent session_id==alias no cross-contamination` ✅ (new test, 29c2728f)
- `send self-send rejected` ✅
- `send happy path` ✅

## Code Review

### c14f2f26 — `C2C_MCP_CLIENT_PID="0"` sentinel

**File:** `ocaml/c2c_mcp_helpers_post_broker.ml`

**Change:** Added `else if trimmed = "0"` branch in `current_client_pid()` that returns `Some (Unix.getpid ())`.

**Root cause:** Docker test harness sets `C2C_MCP_CLIENT_PID="0"` before the subprocess PID is captured, causing the subprocess to register with PID=0 (invalid/no lease file), producing "recipient is not alive".

**Fix correctness:**
- `"0"` is a safe sentinel — it's never a valid PID on Linux (PIDs start at 1)
- When the sentinel is detected, `Unix.getpid()` returns the real subprocess PID
- Registration gets a valid lease file, fixing the "not alive" failure
- The rest of the `current_client_pid` logic is unchanged for non-zero PIDs

**Scope:** `current_client_pid` is used at line 880 (same file) and from `c2c_identity_handlers.ml:53` — both can access the function correctly (it's a module-level binding).

### 29c2728f — regression test

**File:** `ocaml/test/test_c2c_send_handlers.ml`

**Coverage:** 50-line test covering:
- Two concurrent sessions both with `session_id == alias` (e.g. "session-a")
- Cross-direction sends (A→B, B→A) succeed ✅
- Self-sends (A→A, B→B) fail with "yourself" message ✅
- No cross-contamination between the two sessions

Test is deterministic, uses `with_temp_dir` for isolation, and follows the existing test file's patterns.

## Criteria Checked
- `build-clean-IN-slice-worktree-rc=0` ✅
- `dune runtest IN-slice-worktree` ✅ (71/71 pass)
- `current_client_pid "0"→getpid() logic reviewed` ✅
- `regression test reviewed` ✅
- `new test included in test_set` ✅

## Verdict

**PASS** — both SHAs ready for coord-PASS.
