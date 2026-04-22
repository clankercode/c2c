# OCaml test suite audit findings

**Auditor:** galaxy-coder
**Date:** 2026-04-22
**Scope:** `ocaml/test/*.ml`

## Summary

Overall the suite is well-structured. All tests use per-test temp directories
(clean teardown via `Fun.protect ~finally`), Alcotest with `Quick` speed grade,
and `with_temp_dir` helpers that prevent cross-test contamination. One class of
real-time sleeps and one temp-file leak need attention.

---

## Finding 1: Real-time sleeps in `test_relay.ml`

**Severity:** Medium (flaky on loaded/CI VMs)

Three tests use `Unix.sleep 1` to wait for TTL expiry:

| Test | Line | Sleep | Purpose |
|------|------|-------|---------|
| `test_lease_is_alive_after_ttl_expires` | 46 | `Unix.sleep 1` | Wait for 10ms TTL to expire |
| `test_lease_touch_updates_last_seen` | 53 | `Unix.sleep 1` | Advance wall clock before `touch` |
| `test_relay_gc_removes_expired_leases` | 204 | `Unix.sleep 1` | Wait for 10ms TTL to expire |

`test_lease_touch_updates_last_seen` is the most fragile: it sleeps 1s expecting
`last_seen` to advance past `before = Unix.gettimeofday()`. If the test process
is delayed (container throttling, GC pause, CFS quota), `last_seen` may not
advance past `before` by enough, causing a false failure.

**Fix:** Replace `Unix.sleep 1` with a mock clock (e.g. a `float ref` passed as
a mutable time source, or `Unix.gettimeofday` stub via module substitution).
Short of a full mock clock, `sleep 2` reduces false-negative rate.

**No fix committed** — threading a mock time through `InMemoryRelay` and
`RegistrationLease` is a non-trivial API change. Recommend fixing in a follow-up
slice.

---

## Finding 2: mtime-granularity dependency in `test_c2c_mcp.ml`

**Severity:** Low (correct on ext4, may be flaky on tmpfs/in-memory fs)

`test_drain_inbox_empty_does_not_rewrite_existing_empty_file` (lines 72–95):
sleeps 1s then checks that `st_mtime` is unchanged. The comment acknowledges
"Linux ext4 default is 1s" — on tmpfs (common in containers) mtime has
nanosecond resolution so the timing signal is still reliable. This is a known
limitation documented in-code. Not a regression risk.

---

## Finding 3: Temp file leak in `test_wire_bridge.ml` spool tests

**Severity:** Low (cosmetic, no test contamination)

`test_spool_roundtrip` (line 81) and `test_spool_clear` (line 97) write to
`/tmp` with unique names but `finally` only removes the file, not the directory.
On repeated runs these leave behind empty spool directories. No cross-test
contamination since filenames include a random component.

**Fix:** `finally` block should `rmdir` the temp directory too, or use the same
`with_tmp_dir` pattern from `test_relay_identity.ml`.

**No fix committed** — cosmetic only.

---

## Finding 4: `test_c2c_name.ml` uses no test framework

**Severity:** Informational

`test_c2c_name.ml` (22 lines) prints results to `stderr`/`stdout` instead of
using Alcotest. It runs without a formal test harness, so test count and pass/fail
are not machine-readable without output parsing. The logic is trivially correct.

**Recommendation:** Wrap in Alcotest for consistency. Trivial change (3 lines).

---

## Observations (no action needed)

### Good patterns
- All Alcotest-using files mark tests `Quick` — no slow tests.
- `test_c2c_mcp.ml` uses `Fun.protect ~finally` for all env var restores and
  temp dir cleanup. No `Unix.putenv` restore leaks found.
- `with_temp_dir` in `test_relay_identity.ml` properly handles `Sys.remove`
  exceptions with `try/_ -> ()` in the finally block.
- `test_concurrent_*` tests in `test_c2c_mcp.ml` use `Unix.fork()` correctly
  with `waitpid` in a loop that handles `EINTR`.
- `test_relay_bindings.ml` and `test_relay_auth_matrix.ml` are purely
  functional with no side effects — no shared state, no timing deps.
- `test_relay_signed_ops.ml` generates fresh identities per test — no fixture
  reuse.

### No ordering dependencies
No test class was found to depend on run order. Each `make_test_relay ()` /
`InMemoryRelay.create ()` / `with_temp_dir` creates isolated state.

### `test_c2c_mcp.ml` env var pollution (safe)
Tests that call `Unix.putenv` use `Fun.protect ~finally:(fun () ->
Unix.putenv "KEY" "")` to restore. However, some tests putenv multiple keys
(e.g. `C2C_MCP_SESSION_ID`, `C2C_MCP_AUTO_REGISTER_ALIAS`, `C2C_MCP_CLIENT_PID`).
If any `finally` body throws, the remaining restores are skipped. Low risk in
practice since OCaml's `Fun.protect` runs all cleanup handlers even on exception.

---

## Fixable items summary

| # | File | Issue | Fix complexity | Committed |
|---|------|-------|---------------|-----------|
| 1 | `test_relay.ml` | 3x `Unix.sleep 1` | Medium (mock clock needed) | No |
| 2 | `test_wire_bridge.ml` | `finally` misses `rmdir` | Trivial (1 line) | No |
| 3 | `test_c2c_name.ml` | No Alcotest harness | Trivial (3 lines) | No |

None of these are blocking. The real-time sleeps are the most meaningful risk
for CI flaky tests on loaded machines.
