# #444 Cross-Host TOFU Key Divergence — Research Findings
**Filed:** 2026-05-02 by galaxy-coder
**Status:** No gap found; existing test coverage is adequate

## Symptom
TOFU pin store (in-memory Hashtbls `known_keys_ed25519` / `known_keys_x25519` in `c2c_broker.ml:646-647`, persisted to `relay_pins.json`) — concern that same alias re-registering with different key across two hosts might diverge.

## Code Analysis

### Pin store write-through
`pin_x25519_sync` and `pin_ed25519_sync` (c2c_broker.ml:925-945):
- `Some existing when existing <> pk → `Mismatch` (pin NOT replaced)
- On `Mismatch`, caller is responsible for rejection

### Registration handler (`c2c_identity_handlers.ml:210-266`)
When `ed25519_mismatch` or `x25519_mismatch` fires:
1. Emits `relay_e2e_register_pin_mismatch` audit log line (CRIT-2)
2. Returns `tool_result ~is_error:true` with descriptive message
3. **Does NOT overwrite the pin**
4. **Does NOT create the registration**

### decrypt_envelope path (`relay_e2e.ml:418`)
On mismatch: returns `Key_changed` enc_status; caller surfaces `enc_status:"key-changed"` and drops the message. Pin is NOT overwritten.

## Existing Test Coverage

### 1. `test_register_rejects_ed25519_mismatch` (test_c2c_mcp.ml:3192)
- Pre-pins key for "mismatch-ed"
- Attempts register with different ed25519 key
- Verifies: error response, no registration, pin unchanged, CRIT-2 audit log emitted

### 2. `test_cross_host_divergence_full_pin_flow` (test_c2c_mcp.ml:9633)
- Labeled "CRIT-2 cross-host divergence"
- Three-phase test:
  - Phase 1: TOFU pin on first contact with `alice@hostA`
  - Phase 2: rotated key from same alias → `key-changed` reject, pin NOT overwritten
  - Phase 3: version downgrade rejected
- Confirms pins are per-literal-alias-string (so `alice@hostA` ≠ `alice@hostB`)

## Conclusion
No gap. The pin store correctly:
1. Rejects mismatched keys on register (returns error, no overwrite)
2. Rejects mismatched keys on decrypt (Key_changed, no overwrite)
3. Audit logs both paths with `relay_e2e_pin_mismatch` and `relay_e2e_register_pin_mismatch`
4. Per-alias-string pins mean cross-host same-alias registrations are correctly rejected

**Fix status:** No fix needed; test coverage adequate.
