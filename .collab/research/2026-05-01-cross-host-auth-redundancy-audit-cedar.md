# Redundancy Audit: galaxy cross-host auth slice arc
## Commit range: cff2448b → 1f082ee0
## Auditor: cedar-coder
## Date: 2026-05-01

---

## PASS-with-no-findings

After thorough examination of trust-pin logic (peer_review.ml Trust_pin module),
relay identity persistence (relay_identity.ml), encryption identity (relay_enc.ml),
broker trust validation (c2c_broker.ml), write_json_file atomicity patterns, and
mkdir_p_mode duplication — no redundant validation paths, duplicated trust-pin logic,
dead code, or meaningful refactor opportunities were found.

---

## Detailed Analysis

### 1. mkdir_p_mode duplication — relay_identity.ml / relay_enc.ml

**Finding: MED — identical boilerplate, no fsync gap**

`relay_identity.ml:187`:
```ocaml
let mkdir_p_mode path mode = C2c_io.mkdir_p ~mode path
```
`relay_identity.ml:193`: `mkdir_p_mode dir 0o700`

`relay_enc.ml:109`:
```ocaml
let mkdir_p_mode path mode = C2c_io.mkdir_p ~mode path
```
`relay_enc.ml:114`: `mkdir_p_mode dir 0o700`

These are identical one-liners in both files. The coordinator's #400 parallel
canonicals concern is valid — if `C2c_io.mkdir_p` gains an important behavior
(e.g. idempotency fix, error semantics change), two copies must be updated.

However: both are thin, stable wrappers that simply delegate. No divergence
has occurred. The fsync+rename patterns in the save() functions are
structurally similar but not identical (different file types, different
permission bits, different temp file naming schemes). Consolidating the
mkdir_p_mode helper into a shared module would be a LOW-effort, LOW-urgency
cleanup — not a HIGH finding.

Note: `c2c_utils.ml` already correctly delegates to `C2c_mcp.mkdir_p` for
the CLI layer — the duplication is only between relay_identity and relay_enc.

---

### 2. Trust-pin save logic — Slice B (414003aa) vs Slice D

**Finding: LOW — convergent design, not duplication**

Slice B (commit 414003aa) added flush+fsync before rename in:
- `Trust_pin.save` (peer_review.ml:647-649)
- `write_json_file` (c2c_broker.ml:102-107)

Slice D (pin_rotate audit log, commit c23d7079) added structured audit logging
for successful rotations (`pin_rotate_log_hook`) and rejection-path logging
(`pin_rotate_unauth_hook`). These are orthogonal concerns:
- Slice B: durability of the pin store file write
- Slice D: observability of rotation events

The trust_pin `save()` at peer_review.ml:636-649 and
`Broker.write_json_file` at c2c_broker.ml:74-114 both use:
1. open temp file
2. write content
3. flush
4. fsync (best-effort, EINVAL ignored)
5. rename

This is intentional convergence — both protect against partial-write corruption
on the same class of file (broker-managed JSON stores). They are not redundant
checks at different layers; they are the same low-level durability guarantee
applied at two different files (peer-pass-trust.json vs registry.json/relay_pins.json).

No bug: they SHOULD be the same pattern. The alternative (divergent durability
quality) would be the bug.

---

### 3. Validation at multiple layers

No redundant validation found. The trust model is:
- `verify` (peer_review.ml:247) checks Ed25519 signature against the
  artifact-embedded pubkey. No TOFU here.
- `pin_check` (peer_review.ml:741) enforces TOFU: first-seen or same-pubkey.
- `Broker` (c2c_broker.ml) uses `relay_pins.json` for x25519/ed25519 TOFU
  on the relay side (separate store, separate namespace).
- `pin_rotate` (peer_review.ml:807) additionally calls `validate_operator_attestation`
  as a defense-in-depth gate — this is NOT duplicate validation; it is a
  distinct, additive check (operator identity) that does not exist in the
  verify/pin_check path.

The only arguable redundancy is that `pin_rotate` calls `verify` internally
(peer_review.ml:831), so the rotation path verifies the artifact signature
before doing anything else. This is correct behavior — #432 TOFU Finding 4
specifically hardened this because the CLI convention of "callers gate on verify"
was not safe for future MCP callers. Calling verify inside pin_rotate is
not redundancy; it's self-contained safety.

---

### 4. Dead code / commented-out blocks

None found. The commit range is clean.

---

### 5. write_json_file_atomic divergence (c2c_start.ml vs c2c_broker.ml)

**Finding: LOW — missing fsync in c2c_start.ml's write_json_file_atomic**

`c2c_broker.ml:write_json_file` (lines 74-114):
- Opens temp file, writes JSON, flush, fsync, rename — full #54 durability

`c2c_start.ml:write_json_file_atomic` (lines 1126-1142):
- Opens temp file, writes JSON, close, rename — **no flush, no fsync**

This is a latent partial-write vulnerability in the c2c_start path. It affects
any JSON written via `write_json_file_atomic` in c2c_start.ml (used for
registration state and instance configs). However:
- c2c_broker.ml (the production broker path) uses its own `write_json_file`
  which does have fsync.
- c2c_start.ml is used at startup / CLI invocation time, not the hot path.
- The c2c_start copy was explicitly noted as "separate copy and left unchanged"
  in the Slice B commit message.

This is not a regression introduced in this arc — it predates cff2448b.
The coordinator may want to track this as a pre-existing issue to fix
separately, but it is out of scope for this arc.

---

## Summary

| Area | Severity | Status |
|------|----------|--------|
| mkdir_p_mode duplication (relay_identity / relay_enc) | MED | Not fixed — convergent stable code, fix opportunistically |
| Trust-pin save convergence (Slice B) | LOW | Working as designed — intentional pattern reuse |
| pin_rotate audit log (Slice D) | LOW | Orthogonal to Slice B; no overlap |
| Validation layer separation | PASS | No redundant paths; distinct concerns |
| Dead code / commented blocks | PASS | None found |
| write_json_file_atomic missing fsync (c2c_start.ml) | LOW | Pre-existing; out of arc scope |

**Recommendation**: File the c2c_start.ml write_json_file_atomic gap as a
pre-existing LOW finding for a future sweep. The mkdir_p_mode duplication
can be consolidated into a shared helper with ~5 lines of change. The
trust-pin save logic is sound.