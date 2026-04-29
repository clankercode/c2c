# Relay-crypto CRIT-1 Slice B-min-version (per-peer min-observed-version pin)

**Authors**: stanza-coder (drafted as subagent of slate-coder)
**Date**: 2026-04-29
**Status**: design (doc-only; impl deferred to Slice B-min-version-impl)
**Depends on**: Slice B (envelope `from_ed25519` field + TOFU on first-contact)
**Cross-ref**:
- Plan-doc: `.collab/design/2026-04-29-relay-crypto-crit-fix-plan-cairn.md`
  ("Addendum / Downgrade-attack mitigation").
- Plan-doc peer-PASS artifact: `.c2c/peer-passes/0e15522f-slate-coder.json`
  (slate's review note (a): "downgrade-attack risk — verifier dispatch
  uses on-wire envelope_version; once a peer is observed at v2,
  downgrading to v1 should be rejected, recommend per-peer min-version
  pin").
- Slice A landed at `1e414fdc`
  (`feat(crit-1): cover from_x25519 in relay_e2e canonical_json behind
  envelope_version`).

---

## TL;DR

Defense-in-depth add-on to Slice B. Once we have observed a peer
sending an `envelope_version >= 2` envelope, refuse subsequent
`envelope_version < min_observed` envelopes from that same peer.
Persists alongside the Slice B TOFU pin in `relay_pins.json`. ~30 OCaml
+ ~80 test = ~110 LOC. One slice, bounded.

---

## 1. Threat model

### Attack shape

After Slice A and Slice B land, a v2 envelope's signed canonical blob
covers `from_x25519` and `from_ed25519`. The `verify_envelope_sig`
path dispatches canonical-blob shape on the **on-wire**
`envelope_version` field. For `envelope_version=2` envelopes from a
peer carrying `from_x25519=Some _`, downgrading 2→1 breaks the sig
because the v1 canonical bytes differ (omit `from_x25519`).

That covers the case where the legitimate sender always populates
`from_x25519`. It does **not** cover the case where the legitimate
sender is **already known to populate v2** but emits some envelopes
without `from_x25519` (legitimate plaintext-routed paths) — in that
mixed corpus, an attacker with MITM capability can:

1. Strip `from_x25519` (and `from_ed25519` once Slice B lands) from a
   captured/forged envelope.
2. Spoof `envelope_version=1` on the wire.
3. Forge a fresh ciphertext under the v1-canonical Ed25519 sig.
   The v1 canonical blob does NOT bind `from_x25519`, so the attacker
   does not need the legitimate peer's X25519 key — they swap in their
   own and ride the same Ed25519 sig if they ever capture it; or, more
   subtly, they can mint envelopes that the v1 verifier accepts as
   long as they hold the legitimate Ed25519 key (which Slice B's TOFU
   pins, but only for v2 envelopes).

### Why Slice B alone does not close this

Slice B pins `from_ed25519` only when the envelope carries it (i.e.
v2). A v1 envelope from the same alias is verified through the v1
path, which has no `from_ed25519`, hence no TOFU check, hence no
mismatch detection. **The v1 verifier still accepts envelopes from a
peer the recipient has already met at v2** — the attacker
impersonates a v2-peer-as-v1-peer.

The broader CRIT-1 fix wording "v2-canonical signs from_x25519" is
correct but does not by itself prevent the verifier from accepting v1
envelopes claiming to be from the same alias. That gap is the
downgrade-attack window this slice closes.

### Severity

CRIT-class follow-on. Without this pin, the CRIT-1+B fix is
incomplete against an active MITM that can rewrite `envelope_version`
on the wire.

---

## 2. Mechanism

### Storage

Extend the per-alias pin record in `relay_pins.json` (the TOFU pin
store from #432 Slice E, extended by Slice B to carry `from_ed25519`).
Add one field:

```
min_observed_envelope_version : int   (default 1; monotonic-increase)
```

The record after Slice B + Slice B-min-version:

```
{
  "<alias>": {
    "from_ed25519_b64": "<...>",
    "min_observed_envelope_version": 2,
    "first_seen_ts": <int>,
    "last_seen_ts": <int>
    // (other Slice B / #432 Slice E fields elided)
  }
}
```

### Write path (on every successful verify)

After `verify_envelope_sig` returns `Ok` and the Slice B TOFU check
passes, update the pin in-place:

```
pin.min_observed_envelope_version <-
  max(pin.min_observed_envelope_version, observed_envelope_version)
```

Persist via the existing `relay_pins.json` flush path (atomic write +
fsync + rename, same pattern as `c2c_registry`).

### Read path (before verify dispatch)

Before `verify_envelope_sig` dispatches on `envelope_version`, look up
the pin by `from` alias:

- If pin exists AND `envelope_version < pin.min_observed_envelope_version`
  → reject with audit-log line tagged `version-downgrade-rejected`,
  return `Error \`Version_downgrade`.
- Else → continue normal verify dispatch.

The check happens **before** sig verify so the audit-log line clearly
attributes the reject to downgrade-policy, not sig-mismatch.

---

## 3. Sequencing

Strict dependency on Slice B (envelope `from_ed25519` + TOFU
first-contact). Slice B writes the pin record on first contact, and
its initial `min_observed_envelope_version` is set to whatever
`envelope_version` was observed at first contact. Slice B-min-version
adds the read-side enforcement against subsequent envelopes.

Order:

1. Slice B lands (envelope field + TOFU first-contact). Slice B
   already needs to write `min_observed_envelope_version` on the
   first-contact pin write — this slice's spec asks Slice B to set it
   to the observed value at first-contact (small additive change to
   Slice B; ~3 LOC).
2. Slice B-min-version lands the read-side enforcement + the
   max-update-on-verify path + the operator escape hatch.

If Slice B has already shipped without the field, Slice B-min-version
must include a one-shot migration: on load of a legacy `relay_pins.json`
with no `min_observed_envelope_version`, default to `1` (open) — same
semantic as a fresh first-contact at v1.

---

## 4. Test plan

Test file: `ocaml/test/test_relay_e2e.ml` (extend) and possibly
`ocaml/test/test_relay_pins.ml` (Slice E pin-store tests, if extended
similarly).

### Cases

- **(a) first-contact at v2 sets min=2** — empty pin store, deliver
  a v2 envelope, verify success, assert
  `pin.min_observed_envelope_version = 2` after persist.
- **(b) subsequent v1 envelope from same peer rejected** — pin exists
  with `min_observed_envelope_version = 2`, deliver a v1 envelope from
  the same alias, assert `Error \`Version_downgrade` AND audit-log
  contains `version-downgrade-rejected` with the alias + observed-version
  + min-pinned-version.
- **(c) first-contact at v1 sets min=1, subsequent v2 accepted and
  bumps min to 2** — empty pin, deliver v1, verify, assert `min=1`.
  Then deliver v2 from same peer, verify, assert pin updates to
  `min=2`. Then deliver v1 again, assert reject (re-uses case (b)
  assertion).
- **(d) audit-log line on rejection cites `version-downgrade-rejected`** —
  asserted in (b); explicit case here so the audit-log contract is
  pinned in tests, not just incidentally observed.

### Test fixture additions

Reuse the Slice A / Slice B envelope-builder helpers in
`test_relay_e2e.ml`. Add a small helper to construct a v1 envelope
masquerading as a known-v2 peer (synthetic — produces a v1-canonical
sig over the v1 fields with the legit Ed25519 key, simulating an
attacker that captured the key; even if the test setup uses the
legit key directly, the rejection happens on the version-pin check
before sig verify, so the test does not need a real key compromise).

---

## 5. Operator escape hatch

Legitimate rollback (e.g. emergency revert of a v2 binary back to
v1) must not lock peers out forever. The escape hatch:

- **`pin_rotate` resets `min_observed_envelope_version` to 0** on
  operator action. Existing `pin_rotate` interface from #432 TOFU
  4/5 already handles operator-attested key rotation; this slice
  extends its semantic to also reset the min-version pin.
- Defer the **impl shape** of the escape hatch (CLI flag, MCP tool
  surface, audit-log format) to a Slice B-min-version-impl follow-on.
  This design slice records the **policy** (reset on rotate;
  automatic vs flag-gated TBD) but does not lock the surface.

Alternative considered and deferred: deleting `relay_pins.json`
wholesale resets ALL pins (consistent with #432 Slice E semantic of
operator-wipe → TOFU first-seen on next message). That works as a
nuclear option but is too coarse for routine rollback; per-alias
`pin_rotate` is the right granularity.

---

## 6. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Legitimate rollback v2→v1 locks peer out | medium | high (peer can't send) | Operator `pin_rotate` resets min-version pin |
| Clock skew or version-field mishandling causes spurious rejects | very low | low | No clock-dependent logic. `envelope_version` is integer-monotonic; max() update is commutative. |
| Pin race on concurrent verify (two envelopes arriving simultaneously, both update `min_observed`) | low | low | The same atomic-write pattern Slice B uses for pin persist; max() is commutative so worst case is one redundant write |
| Migration path on legacy `relay_pins.json` (no field) | low | low | One-shot default-on-load (field absent → default 1, behave as fresh first-contact at v1) |

---

## 7. LOC budget

- OCaml (`relay_e2e.ml` verify path + `relay_pins.ml` pin record
  field + max-update + reject branch + audit-log line): ~30.
- Tests (`test_relay_e2e.ml` extend, four cases above): ~80.
- Total: ~110. Comfortably under the 200 target. One slice.

---

## 8. Open questions

These two questions surface for Cairn / Max sign-off before
Slice B-min-version-impl dispatches:

1. **Should `min_observed_envelope_version` be persisted to
   `relay_pins.json`?** **Recommend YES.** Otherwise, restart resets
   the defense, and the attack window reopens every time the broker
   restarts. The marginal cost is one int field per pin record.
2. **Should `pin_rotate` ALSO accept a `--reset-min-version` flag,
   or is automatic reset on rotate sufficient?** Stake-position:
   **automatic reset on rotate is sufficient for v1.** Operator
   intent at rotate-time is "this peer's identity has legitimately
   changed; trust the new state" — version pin should follow. A
   `--keep-min-version` flag could be added later as paranoia opt-in
   if a credible scenario emerges, but no concrete need today.

---

## Receipts

- Slice A (CRIT-1) landing commit: `1e414fdc`
  (`feat(crit-1): cover from_x25519 in relay_e2e canonical_json
  behind envelope_version`).
- Plan-doc with full Slice A/B/C plan + downgrade-attack addendum:
  `.collab/design/2026-04-29-relay-crypto-crit-fix-plan-cairn.md`.
- Slate's plan-doc PASS artifact (the source of the recommendation
  this slice formalizes): `.c2c/peer-passes/0e15522f-slate-coder.json`,
  notes field "(a) downgrade-attack risk".
- TOFU pin store extended by Slice B: `relay_pins.json` (#432 Slice E
  + TOFU 4/5 lineage).

---

— stanza-coder (subagent of slate-coder)
