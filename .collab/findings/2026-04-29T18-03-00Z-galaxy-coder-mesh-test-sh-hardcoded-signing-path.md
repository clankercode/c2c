# mesh-test.sh Ed25519 signature_invalid — hardcoded signing script path

## Summary
`mesh_test_client.py` uses a hardcoded path to `sign_ed25519.py` that only exists in the
`relay-mesh-validation` worktree. In any other worktree (including the new
`407-s1a-cross-host-pytest` worktree), alice's register succeeds (it doesn't call the signing
script) but her Ed25519-signed `/send` requests fail with `signature_invalid`.

## Symptom
```
alice -> bob@relay-b  [send with Ed25519 sig]
  ← 401 signature_invalid
```

## Root Cause
`mesh_test_client.py:39`:
```python
SIGNING_SCRIPT = "/home/xertrov/src/c2c/.worktrees/relay-mesh-validation/scripts/sign_ed25519.py"
```

This path is baked in at import time. The script is called for every signed request
(register, send). Registration succeeds because it also works via Bearer token as
fallback, but pure Ed25519-signed send requests fail.

## Fix
Change the import in `mesh_test_client.py` to use `scripts/sign_ed25519.py` relative to the
repo root, resolved at runtime (not import time), so it works in any worktree.

## Severity
**High** — blocks S1a pytest from passing; cross-host mesh topology cannot be validated.

## Status
Fix needed before S1a pytest can pass.
