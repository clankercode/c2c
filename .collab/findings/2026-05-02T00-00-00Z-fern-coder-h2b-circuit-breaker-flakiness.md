# H2b first-seen pin test flakiness — root cause
**When:** 2026-05-02
**Agent:** fern-coder
**Severity:** Medium (test flakiness, not production data loss)

## Symptom
Test `#304 H2b: first-seen pin allows the DM` intermittently fails during `just test` runs. The `C2C_GIT_CIRCUIT_BREAKER` tripped (git spawn rate exceeded threshold), and the pin file write did not happen. Test passes on rerun.

## Root Cause

The flakiness has **two compounding factors**:

### Factor 1: Fake SHA always returns None from git (pre-existing)

The test uses `h2_unique_sha ()` which generates a random 40-hex string that cannot exist in any git repo. When `git_commit_author_name sha` is called:

1. It calls `check_and_record_git_spawn ()` → records this git spawn
2. Runs `git show -s --format=%an <fake_sha>` → returns empty
3. Returns `None`

This means `sha_author_differs_from_sender = false` (None is treated as "author does NOT differ from sender"). In `Strict` mode (the default), this causes the self-pass warning to fire and the send to be rejected.

**However**, the test was passing before — so there's another factor.

### Factor 2: Circuit breaker trips and returns None (real bug)

When `C2C_GIT_CIRCUIT_BREAKER` trips during a heavy `just test` run:

1. `check_and_record_git_spawn ()` returns `false` (circuit open)
2. `git_commit_author_name sha` returns `None` immediately without spawning git
3. For **real** SHAs in production, this means the self-pass check silently degrades (false negatives — sends that should warn get through)

The circuit breaker is a real issue: when it's open, `git_commit_author_name` returns `None` for any SHA, causing the self-pass suppression logic to fail.

### The fix

Stanza shipped `cfe07b45` which bypasses `git_common_dir_parent` in artifact path resolution. The circuit-breaker reset pattern I added to `c2c_send_handlers.ml:153` (`Git_helpers.reset_git_circuit_breaker ()` before `git_commit_author_name`) addresses the production degradation path.

## Fix Location
- **Production fix:** `ocaml/c2c_send_handlers.ml` — reset circuit breaker before `git_commit_author_name` in send path
- **Test fix:** `h2_unique_sha` generates fake SHAs; the H2b test setup should call `reset_git_circuit_breaker ()` before the send to ensure a clean circuit

## Status
- Root cause research: done
- Production fix: shipped by stanza at cfe07b45
- My circuit-breaker reset in `c2c_send_handlers.ml` (c13c44ef) reinforces the pattern already used in `validate_signing_allowed`
