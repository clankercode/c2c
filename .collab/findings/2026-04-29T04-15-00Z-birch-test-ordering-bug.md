# Test bug masked by alphabetical ordering — #407 S5

**Timestamp:** 2026-04-29T04:15:00+10:00
**Agent:** birch-coder
**Topic:** test ordering hid init_identity() bugs

## Symptom
`test_s5_signing_e2e.py` had 4 tests that all read the identity in agent-a1:
- `test_identity_show_returns_valid_ed25519`
- `test_fingerprint_is_sha256_format`
- `test_pubkey_is_returned`
- `test_peer_pass_sign_and_verify_cross_broker`

Only the last test (`test_peer_pass_...`) called `init_identity()` first.
The first 3 tests directly called `get_identity_show()`, `get_fingerprint()`,
`get_pubkey()` without initializing the identity first.

**Why it passed before:** Python's unittest/pytest collects and runs tests
**alphabetically**. `test_peer_pass_...` (p > f, i) ran **LAST**, so when it
called `init_identity()` the identity was provisioned before the first 3
tests ran in the **next** pytest invocation (the 5th run — when I was
expecting `cdb4fbae` to have "fixed everything").

## Root Cause
Test authors assume tests are isolated and self-contained. The test file
had a hidden ordering dependency: `test_peer_pass_...` had to run first
to initialize the identity, or the other 3 tests would fail.

## Fix
Added `init_identity(agent_a1, ALIAS_A1, relay_url=RELAY_URL)` to each of
the first 3 tests before reading the identity.

Also: `init_identity()` has no `force` kwarg, but
`test_s5_signing_e2e.py:170` passed `force=True`. Removed that too.

## Severity
Medium — the test passed spuriously due to ordering. Real cold-cache
smoke (which destroys all containers + volumes between runs) would have
caught it. The cold-cache rebuild I ran after slate's FAIL exposed it.

## Lesson
Run e2e tests with a **fresh compose up/down cycle** between runs to
catch ordering-dependent state. Also: consider marking the identity
fixture as `autouse=True` so every test starts with a clean slate.
