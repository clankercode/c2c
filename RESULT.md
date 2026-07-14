# RESULT — B178 relay monitor peek terminal timestamp_out_of_window

**Branch**: `fix/bl-b178`  
**Worktree**: `/home/xertrov/src/c2c/.worktrees/bl-b178`  
**Bug**: `.backlog/bugs/B178-relay-monitor-peek-terminal-ti.todo`  
**Status**: fix committed on branch only (no merge, no `bl done`)

## Summary

After rename + relay re-register, `c2c monitor` relay peek hit TERMINAL
`timestamp_out_of_window` with a constant ~-30.5s skew after `nonce_replay`
backoff, even when host NTP matched relay HTTP Date.

**Root cause**: the monitor signed Authorization for `/peek_inbox` **once** at
watcher setup and reused the same `ts`+`nonce` on every subsequent peek.

| Step | Cached-auth behaviour |
|------|------------------------|
| Peek 1 | Fresh header at setup → OK (nonce consumed) |
| Peek 2+ (age ≤ 30s) | Same header → `nonce_replay` (transient, backoff) |
| Peek after age > 30s | Same header → `timestamp_out_of_window` skew ≈ −age (~−30.5s) TERMINAL |

`request_ts_past_window = 30.0` (`ocaml/relay_common.ml`) explains the
constant −30.5s: it is the **age of the cached signature**, not wall-clock
skew. Host NTP can be perfect.

## Fix

Re-sign inside `peek_once` on every cycle via
`C2c_monitor_logic.auth_header_for_peek` (injected `sign_once` for tests;
live path uses `Relay_signed_ops.sign_request` with meth=POST,
path=`/peek_inbox`, exact body bytes).

## Changes

1. **`ocaml/cli/c2c_monitor_cmd.ml`** — move signing into `peek_once`; never
   cache Authorization across peeks (B178).
2. **`ocaml/cli/c2c_monitor_logic.ml`**
   - `auth_header_for_peek` — pure helper, one sign per call
   - `classify_reused_auth_peek` — fixture model of the poison sequence
3. **`ocaml/cli/test_c2c_monitor_logic.ml`** — suite `b178-fresh-peek-auth`:
   - reused auth → nonce_replay then −30.5s TERMINAL
   - N peeks ⇒ N distinct sign calls
   - no identity → unsigned
   - `nonce_replay` stays Peek_transient

## Validation

```text
just build-cli                                          # rc=0
scripts/dune-build-locked.sh exec -- \
  ./ocaml/cli/test_c2c_monitor_logic.exe
  # Test Successful. 47 tests run (incl. 4 b178-fresh-peek-auth)
```

## Process notes

- **PIRFL**: plan from bug notes (constant −30.5s + nonce_replay path) →
  locate one-shot sign at setup → implement re-sign-per-peek + fixtures →
  build/test green.
- **review-and-fix (gpt-5.5 via `codex exec -m gpt-5.5 review`)**:
  PASS — “signs a fresh relay peek Authorization header on each monitor
  cycle… tests cover the nonce-reuse failure sequence… no correctness
  issue introduced by the patch.”
- **Not done** (per instructions): merge to master, `bl done`.

## Commit SHAs

| Ref | SHA |
|-----|-----|
| Fix commit | `799a8e6e760718cc157027ce61892fc2b535a82e` (`799a8e6e`) |
| Branch tip (pre-RESULT) | `799a8e6e760718cc157027ce61892fc2b535a82e` |
| Claim / worktree base | `0e2559d7` (branch started from local tip; B178 claim already in bug file) |
