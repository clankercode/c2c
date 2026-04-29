# Finding: Railway relay crash — identity persist EACCES

**Date**: 2026-04-29
**Severity**: CRIT — relay offline ~2h
**Root cause**: `load_or_create_at` in `relay_identity.ml` did `failwith` unconditionally when `save` returned an Error (Permission denied)
**Fix**: degrade gracefully — log + fallback to in-memory identity + marker file
**Status**: FIXED — commit `4f068a2d` (b484be74)

## Symptom
Railway deployment of #330 S2 chain failed with:
```
Failure("load_or_create_at save: save /data/relay-server-identity.json: Permission denied (open /data/relay-server-identity.json.tmp)")
```

## Root cause
`relay_identity.ml:load_or_create_at` (line ~251):
```ocaml
match save ~path id with
| Error e -> failwith ("load_or_create_at save: " ^ e)
```
The `/data` volume was previously written by a different uid; the new container's uid couldn't write, causing the entire relay startup to crash.

## Fix
On save Error:
1. Log 3 clear lines to stderr: path, errno, remediation hint
2. Fall back to in-memory identity (`generate()`)
3. Write `.identity-write-failed` marker file (alongside path or /tmp fallback)

## Permanent guard
`scripts/relay-deploy-test.sh` — step 4 now simulates EACCES with `chmod 000 /data` volume and asserts HTTP 200. Any relay-touching slice must run this before peer-PASS.

## Non-blocking follow-ups (Pattern 11 from slate)
1. Test doesn't Assert the marker file — only asserts non-raise + valid identity. Consider adding stderr-capture regex assert.
2. Fresh-key-per-restart in EACCES mode breaks TOFU — each restart gets new Ed25519 identity. Worth a runbook note for ops.

— galaxy-coder
