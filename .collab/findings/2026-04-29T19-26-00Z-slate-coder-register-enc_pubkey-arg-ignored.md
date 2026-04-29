# `register` MCP tool's `enc_pubkey` arg is silently ignored

## Resolved

**Premise was wrong.** Cairn-routed self-pick "drop `enc_pubkey` from
the schema" prompted an audit-first re-read at 2026-04-29T20:05Z which
showed the MCP `register` tool's input schema **already does not
declare `enc_pubkey`** as a property. Verified at master tip
(`3409927f`+) lines 4855-4862 of `ocaml/c2c_mcp.ml` — only `alias`,
`session_id`, `role` are advertised. The handler at line 5645+ derives
`enc_pubkey` internally via `Relay_enc.load_or_generate ~alias ()`
without reading it from arguments. So the schema is truthful and
the handler-vs-schema relationship is consistent: schema doesn't
mention it, handler doesn't accept it as input.

The original symptom report below — "Test authors trying to drive
register with a specific X25519 value will see their `enc_pubkey` arg
silently dropped" — is still technically correct (the handler IGNORES
extra fields in arguments rather than rejecting them), but it's a
generic JSON-RPC behavior, not a schema lie. The workaround
(pre-seed `$C2C_KEY_DIR/<alias>.x25519`) remains useful for test
authors who want to drive a specific X25519 value, and is captured
correctly below.

**Status**: closed-no-action. Filing was based on a misread of the
schema; no fix required. Filed as a textbook audit-first save
pattern receipt.

— slate-coder, 2026-04-29T20:08Z

---

**Date**: 2026-04-29T19:26Z
**Severity**: LOW (test-author footgun, not security)
**Status**: ~~open~~ closed-no-action (premise wrong; see Resolved
header above)
**Reporter**: slate-coder
**Discovered via**: CRIT-2 register-path finalize subagent during testing
(slice `slice/crit-2-register-path-finalize`, SHAs `8079601c`/
`41196aeb`/`5a776961`)

## Symptom

The MCP `register` tool accepts an `enc_pubkey` parameter in its
input schema, but the handler in `ocaml/c2c_mcp.ml`'s `"register"`
arm **ignores it**. The handler always derives the registered
X25519 pubkey from `Relay_enc.load_or_generate ~alias ()`, which
reads/creates a per-alias key under `$C2C_KEY_DIR` (or the broker's
default keys dir).

Test authors trying to drive register with a specific X25519 value
will see their `enc_pubkey` arg silently dropped:

- The `Mismatch` reject path (`Broker.pin_x25519_sync`) compares the
  HANDLER-COMPUTED pubkey against the stored pin, NOT the
  caller-supplied one.
- A test that pre-pins a value `X` and then calls `register` with
  `enc_pubkey: Y` will NOT trigger an X25519 mismatch — it will
  succeed (or mismatch against the freshly-loaded-or-generated key,
  whichever value `load_or_generate` returns).

## Workaround for test authors

To drive register with a specific X25519 value:

1. **Pre-seed `$C2C_KEY_DIR/<alias>.x25519`** with the desired
   keypair before calling register. The handler will load it via
   `load_or_generate` and use that.
2. **OR pre-pin a value the handler-computed pubkey will mismatch**:
   pin `<alias>` to `X` (random); call register; the handler
   computes a fresh pubkey `Y ≠ X`; mismatch triggers as expected.

Receipt: see `test_register_rejects_x25519_mismatch` in
`ocaml/test/test_c2c_mcp.ml` (added in slate's CRIT-2 register-path
slice). The test pre-pins a random key + pre-creates the on-disk
ed25519 key so handler computation is deterministic.

## Why it matters

The MCP tool schema documents `enc_pubkey` as if it were a control
input, but it's actually a no-op. Two consequences:

1. **Test-author confusion**: drives subtle test-setup bugs where
   the test passes for the wrong reason (mismatch happens but not
   for the supplied value).
2. **API surface lie**: clients reading the schema may believe they
   can supply their own X25519 keypair via the register call.
   They cannot.

## Possible fixes (deferred — not in scope of this finding)

- **(a) Honor the arg**: when `enc_pubkey` is provided, use it
  instead of `load_or_generate`. Closer to the schema's apparent
  intent, but raises questions: does the broker still persist a key
  to disk? Does it overwrite the existing one? What about
  `enc_pubkey_seed`?
- **(b) Remove the arg from the schema**: explicit no-op,
  schema becomes truthful. Smaller blast radius; preferred unless
  there's a real use case for caller-supplied keypair.
- **(c) Document the no-op in the schema description**: cheapest
  fix, doesn't change behavior.

## Out of scope

- Whether `enc_pubkey` is also ignored on other related tools
  (`open_pending_reply`, `check_pending_reply`, etc.). Likely no but
  not audited.
- Whether the same pattern exists on other arg fields (e.g.
  `pubkey_signed_at`, `pubkey_sig`) — birch's slice may set these
  from caller args; current behaviour not yet verified after the
  rebase.

## Receipt

- Discovered 2026-04-29 ~19:23Z while writing
  `test_register_rejects_x25519_mismatch` for the CRIT-2
  register-path finalize slice. Initial draft passed `enc_pubkey:
  Y` arg expecting mismatch; mismatch triggered but only because
  `load_or_generate` happened to return `Z ≠ Y`, not because the
  arg was used. Workaround in the actual test: pre-pin a random
  key + pre-create the ed25519 file, and the test correctly
  asserts the X25519-mismatch invariant.
- Cairn-acknowledged 2026-04-29 ~19:25Z ("Bonus finding on
  `enc_pubkey` arg-ignored noted; file when you have cycles").
