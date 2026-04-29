# Finding: #379 handle_send silent-drop on cross-host rejection

**Date:** 2026-04-29T~05:00 UTC+10
**Severity:** C (spec mismatch — observable via dead_letter inspection)
**Status:** Fixed

## Symptom
jungle-coder's peer-PASS review of #379 S3 e2e test (SHA c152e3fd) found:
- **Positive AC** (`b@hostA` → delivered): ✅ PASS
- **Negative AC** (`b@hostZ` → dead-letter with `cross_host_not_implemented`): FAIL — dead_letter was empty

The test assertion `List.length dl <> 0` failed; dead_letter had 0 entries.

## Root Cause
`handle_send` (relay.ml HTTP handler) returned `respond_not_found` **before** calling `R.send` when `host_acceptable` rejected the target host. Since `R.send` was never called, no dead_letter write occurred.

```ocaml
if not (host_acceptable ~self_host host_opt) then
  respond_not_found  (* ← returned here, R.send never called *)
    (json_error_str "cross_host_not_implemented" ...)
else
  match R.send ...  (* this path never taken on rejection *)
```

Other rejection paths (unknown_alias, recipient_dead) **do** write to dead_letter via `R.send` internally. Cross-host was the only rejection that skipped the relay's `send` function entirely.

## Fix
Added `R.add_dead_letter` to RELAY interface + both relay implementations (InMemoryRelay, SqliteRelay). `handle_send` now writes to dead_letter before returning `respond_not_found`:

```ocaml
if not (host_acceptable ~self_host host_opt) then
  let dl = `Assoc [("ts", ...); ("reason", "cross_host_not_implemented"); ...] in
  R.add_dead_letter relay dl;  (* ← NEW: make rejection observable *)
  respond_not_found (json_error_str "cross_host_not_implemented" ...)
```

## SHAs
- **Relay fix:** `c2414359` on `slice/379-cross-host-fix` (379-cross-host-fix worktree)
- **Test fix:** `39d5c9ca` on `379-s3-e2e` (379-s3-e2e worktree)

## Verification
- 9/9 relay unit tests pass (host_acceptable + split_alias_host)
- 2/2 e2e tests pass (positive: b@hostA delivers; negative: b@hostZ → dead_letter with cross_host_not_implemented)
