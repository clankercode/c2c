# Relay-crypto CRIT-1 + CRIT-2 fix plan

**Authors**: stanza-coder (lead) + slate-coder (review/anchors)
**Date**: 2026-04-29
**Status**: design (slate to peer-PASS, then dispatch impl)
**Cairn-routed**: yes — Max wants OCaml fix shipped first, TS GUI second, Python deprecated.
**Cross-ref**: slate's audit at
`.collab/research/2026-04-29T04-22-52Z-slate-coder-relay-crypto-audit.md`
(CRIT-1 = §3, CRIT-2 = §4).

---

## TL;DR

Two CRIT-class findings on the relay-e2e crypto layer. Both block
cross-host trust until fixed. Plan: fix in OCaml first behind a
canonical-blob version bump (mirroring stickers v1/v2), keep verify
back-compat for one transition window, coordinate TS GUI cutover,
deprecate Python (no port).

---

## Findings receipts

### CRIT-1: `from_x25519` not covered by Ed25519 sig in `canonical_json`

The relay-e2e envelope (`ocaml/relay_e2e.ml`) carries `from_x25519`
as an optional record field (line 28), serializes it to wire JSON
(line 207), and parses it back (line 221). But the
`canonical_json` function at `relay_e2e.ml:79-102` — the source of
truth for the bytes the Ed25519 signature covers — does **not**
include `from_x25519`. The signed blob today is exactly:

```
"enc"        : <string>
"from"       : <alias string>
"recipients" : <list of {alias, nonce|null, ciphertext}>
"room"       : <alias string | null>
"to"         : <alias string | null>
"ts"         : <intlit>
```

(in sorted-key order, as a single canonicalized JSON object).

**Exploit shape**: an attacker who can replay a valid envelope
swap the `from_x25519` field for their own X25519 pubkey — the
Ed25519 signature still verifies because `from_x25519` was never
in the signed blob. Recipients then encrypt their reply against
the attacker's X25519 pubkey, which the attacker decrypts. Or
they may treat `from_x25519` as authoritative for the alias, pin
the attacker's key as the alias's E2E identity, and corrupt
future TOFU.

**Severity**: CRIT (silent confidentiality breach + identity
spoofing on the encrypt-back path).

### CRIT-2: NO Ed25519 TOFU on first-contact for relay-e2e layer

The relay-e2e envelope today has no `from_ed25519` field at all.
There is no way for a recipient to pin the sender's Ed25519 key
on first contact — i.e. nothing prevents a per-message identity
swap. The Ed25519-pubkey-binding store at #432 Slice E
(`relay_pins.json`) is for the broker-host trust layer, not the
relay-e2e per-envelope layer; the two layers don't share their
TOFU set.

**Exploit shape**: a peer claiming alias `bob` can sign envelope
1 with one Ed25519 key, envelope 2 with a different one. Without
TOFU, the recipient has no continuity check between messages —
each envelope is verified in isolation. Combined with CRIT-1, an
attacker can completely impersonate a peer mid-conversation.

**Severity**: CRIT (no continuity-of-identity guarantee at the
relay-e2e layer).

---

## OCaml-first sequence

### Slice A — `canonical_json` extended to cover `from_x25519` (CRIT-1)

**Touch**: `ocaml/relay_e2e.ml`, `ocaml/test/test_relay_e2e.ml`.

1. Add `from_x25519` (when `Some _`) to the canonical-blob
   field-list at `relay_e2e.ml:79`. Field name `"from_x25519"`,
   value `(`String b64url) when present, omit-key when `None`.
   Sorted-key order is already enforced via `sort_assoc`.
2. Bump canonical-blob version. Mirror the
   `c2c_stickers.ml v1/v2` pattern (slate's anchor): explicit
   `envelope_canonical_version` integer, OR implicit-by-shape
   detection (sender includes `from_x25519` ⇒ v2; sender omits ⇒
   v1). **Recommend explicit version** — the implicit-by-shape
   detection in stickers worked for adding ONE optional field;
   we already have one in flight here, and Slice B adds a second
   (`from_ed25519`) — best to centralize.
3. Verifier accepts v1 OR v2:
   - `verify_envelope_sig` peeks the on-wire envelope's claimed
     version (a new `envelope_version : int` field, default 1
     for back-compat parsing).
   - Tries v2-shape canonical_json first if `envelope_version >=
     2`; else v1-shape.
   - On sig-verify success at either shape, return Ok.
   - On sig-verify fail, return Err with version-attempted
     telemetry for ops debug.
4. Producer (`sign_envelope` / `seal_envelope`) bumps
   `envelope_version = 2` and includes `from_x25519` in the
   signed blob.
5. **Test plan**:
   - `test_canonical_v2_includes_from_x25519` — produce, sign,
     verify a v2 envelope; assert sig holds AND `from_x25519`
     bytes are required for verify (mutate them, assert verify
     fails).
   - `test_v1_back_compat_verify` — pre-recorded v1 fixture,
     v2 verifier accepts.
   - `test_v2_envelope_rejects_v1_verify` — v2 sender emits
     `from_x25519`, v1 verifier (simulated) ignores it; v1
     verify FAILS because the signed blob differs. Documents
     the cutover-window contract.
   - `test_omit_from_x25519_v2_canonicalize` — sender chooses to
     omit `from_x25519` (e.g. plaintext-routed message); v2
     canonical blob does NOT include the field; verify still
     works.
6. **LOC budget**: ~80 OCaml + ~80 test = ~160. Single slice.

### Slice B — `from_ed25519` field + TOFU on first-contact (CRIT-2)

**Touch**: `ocaml/relay_e2e.ml`, `ocaml/c2c_mcp.ml` (TOFU pin
store), `ocaml/test/test_relay_e2e.ml`,
`ocaml/test/test_c2c_mcp.ml`.

1. Add `from_ed25519: string option` to the `envelope` record.
   Wire-format: `"from_ed25519": <b64url-Ed25519-pubkey>` when
   `Some _`, omitted when `None` (back-compat).
2. Include in `canonical_json` v2 alongside CRIT-1's
   `from_x25519`. Both signed.
3. Producer side: when sealing, emit the local Ed25519 pubkey
   into the field. Source: same `Relay_identity.load_or_create_at`
   used elsewhere; reuse the broker's keys-dir convention.
4. Verifier side: on receive, after sig-verify succeeds, run
   TOFU pin against the in-memory `known_keys_ed25519` Hashtbl
   (the existing #432 Slice E store).
   - First contact: `Pin_first_seen` (call existing
     `Broker.pin_ed25519_if_unknown ~alias ~pk`).
   - Subsequent: `Already_pinned` (no-op) OR `Mismatch`
     (reject the envelope; emit `peer_pass_pin_rotate_unauth`-
     style audit-log line; do NOT auto-rotate — explicit operator
     action via `pin_rotate` is required, per #432 TOFU 4/5).
5. **Sequencing note**: this depends on Slice A being merged so
   `from_ed25519` lands in canonical_json. Land Slice A → wait
   for one cherry-pick cycle → land Slice B.
6. **Test plan**:
   - `test_envelope_carries_from_ed25519` — produce, parse,
     verify round-trip with the field populated.
   - `test_tofu_first_contact_pins` — empty pin store, deliver
     envelope, assert `relay_pins.json` now contains
     `<alias> -> <ed25519_b64>`.
   - `test_tofu_already_pinned_accepts` — pre-pin, deliver
     same-key envelope, accept.
   - `test_tofu_mismatch_rejects` — pre-pin alias-A → key-X,
     deliver envelope with key-Y, assert reject + audit log.
   - `test_envelope_no_ed25519_field_legacy_accept` — v1
     envelope (no `from_ed25519`), accept WITHOUT TOFU update —
     legacy senders pre-cutover are still tolerated within
     transition window. Document the compromise: legacy senders
     get no TOFU, only v2 senders get it.
7. **LOC budget**: ~120 OCaml + ~100 test = ~220. Slightly above
   the 200 target — split if needed: Slice B1 (envelope field +
   canonical_json) ~80; Slice B2 (TOFU integration) ~140. B2
   waits on B1.

### Optional Slice C — Strict-mode flip (post-transition)

After TS GUI is updated and a soak window has passed, flip the
verifier from "accept v1 OR v2" to "v2 only." Runs as one tiny
slice with a single CLI/env flag (`C2C_RELAY_E2E_STRICT_V2=1`)
that gates the v1-acceptance branch. Default `0` until ops sign-
off.

---

## Cross-client coordination

### TS GUI integration points

The Tauri+Vite+shadcn GUI lives at `gui/`. The TS-side relay-e2e
verifier owner is **TBD pending galaxy/Cairn confirm** —
galaxy has been on TS-adjacent work (#330 forwarder + cross-host)
and is the reasonable first ask. We will not block this design
on identifying the exact TS owner; the dependency will be filled
in during peer-PASS or by direct DM after design lands.

The TS verifier needs to:
1. Recognize the new `envelope_version: 2` field (default 1).
2. Reject envelopes claiming v2 but missing `from_x25519` in
   the canonical-blob fields.
3. Add `from_ed25519` to the canonical-blob field list when
   verifying v2.
4. Implement the same TOFU pin behavior (first-contact pin,
   mismatch reject), backed by an equivalent pin store in the
   GUI's local state directory.

If the TS-side verifier is currently a thin wrapper around a
shared crypto library (e.g. `tweetnacl-ts` or similar), the
canonical-blob field-list extension is the only TS change.

### Version-bump strategy

**Recommend**: `envelope_version: int` field on the envelope,
default 1, OCaml producers bump to 2 immediately, OCaml verifiers
accept both during the transition window. TS GUI accepts both
during transition window. After ops confirms TS clients are all
on v2, flip strict-v2 (Slice C above).

**Reject**: piggybacking on `c2c_wire_bridge.ml protocol_version`
(`"1.9"`) or MCP's `supported_protocol_version` — those are
different layers and would couple unrelated concerns.

### Cutover plan

1. Land Slice A (OCaml v2 canonical_json) — relay-critical, push.
2. Land Slice B (OCaml `from_ed25519` + TOFU) — relay-critical,
   push.
3. Notify TS GUI owner (galaxy/Cairn route): "v2 envelopes are
   now produced by all OCaml clients; please verify TS verifier
   accepts."
4. Soak ~24-48h; watch for TS-receiver verify failures.
5. Once TS GUI is producing v2 + verifying v2, land Slice C
   (strict mode flip). Default-off env flag; ops flips when
   ready.

### Python deprecated

Per Max: Python relay-e2e clients are deprecated; no port. Any
remaining Python sender will be unable to produce v2 envelopes
and will hit the OCaml verifier's v1 acceptance window. Once
Slice C lands and strict-v2 is the default, Python senders are
hard-deprecated (their v1 envelopes fail verify). The Python
deprecation runbook (`.collab/runbooks/python-scripts-deprecated.md`)
should be updated to call this out at Slice C cutover time.

---

## Test plan summary (cross-client interop)

In addition to the per-slice tests above:

- **OCaml-sender → OCaml-receiver**: round-trip v2 envelope,
  v2 verifier, TOFU pins on first contact, mismatch rejected on
  key swap. Covered in test_relay_e2e.
- **OCaml-sender → TS-receiver**: end-to-end through the GUI's
  receive pipeline. Requires the TS verifier update; tested in
  `gui/` test suite (TBD location).
- **Legacy-v1-sender → v2-receiver**: v1 envelopes accepted,
  no TOFU update. Covered.
- **v2-sender → legacy-v1-receiver**: v1 verifier sees the
  extra fields, signature mismatch, reject. Documented as
  cutover-window-expected.

---

## Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| TS GUI not updated before strict-v2 flip | medium | high (TS receivers can't verify) | Default-off C2C_RELAY_E2E_STRICT_V2; ops flips after TS soak |
| Slice B impl pushes past 200 LOC | medium | medium (slice-discipline violation) | Pre-split as B1 + B2 above |
| Pin-mismatch reject DoS by attacker spamming key swaps | low | medium (legit traffic blocked if pin gets locked) | Existing rate-limit on pin-rotate path; mismatch logged but doesn't auto-reject the alias's identity (just THIS envelope) |
| Legacy-Python sender produces v1 envelopes mid-cutover | high | low (intentional — graceful degradation) | Document at Slice C cutover; remove Python sender refs |
| Cross-client interop test gap (no GUI test owner) | medium | medium (silent breakage) | Block Slice C on confirmed TS owner + soak signal |

---

## Open questions for Cairn / Max

1. **TS GUI verifier owner** — confirm galaxy or route to TS
   owner.
2. **Soak window length** — 24h? 48h? 7d? After Slice B lands
   and before Slice C flips strict-v2.
3. **Pin-mismatch policy** — reject envelope only (current
   plan) vs reject + lock alias (more conservative)? Tied to
   how the operator-rotation interface from #432 Slice E + TOFU
   5 obs handles a legitimate key rotation.
4. **`envelope_version` field name** — `envelope_version` (my
   recommendation, explicit), `enc_v` (terser, fits the existing
   `enc` field naming), or piggyback on `enc` itself (`enc:
   "box-x25519-v1"` → `enc: "box-x25519-v2"`)? The third option
   couples canonical-blob version with encryption suite version,
   which may be desirable or undesirable depending on whether
   we plan to rev them independently.

---

## Receipts

- Slate's audit doc:
  `.collab/research/2026-04-29T04-22-52Z-slate-coder-relay-crypto-audit.md`
  §3 (CRIT-1), §4 (CRIT-2).
- Stickers v1/v2 precedent: `ocaml/cli/c2c_stickers.ml` (search
  for `canonical_blob` v1/v2 dispatch).
- TOFU pin store: `c2c_mcp.ml` `Broker.pin_ed25519_*` family
  (#432 Slice E + TOFU 4/5 + observability).
- Symmetry sweep on alias-eviction surfaces (related but
  separate threat model): #432 9a0cd880 + slate e3c6aba0 +
  stanza b8ca6cb0.
- Cairn routing brief: 2026-04-29 ~15:11 UTC DM to stanza-coder.

---

## Addendum (post-peer-PASS, slate's backstop notes)

### Downgrade-attack mitigation (defense-in-depth)

Slate flagged that the verifier dispatch picks canonical_json
shape from the envelope's self-claimed `envelope_version`. An
attacker MITM'ing a known-v2 peer could downgrade their envelope
to claim `envelope_version = 1` and revert to the v1 signed-
blob — which excludes `from_x25519`, the very field CRIT-1
fixes. Same risk for `from_ed25519` once Slice B lands.

**Mitigation**: per-peer min-observed-version pin, persisted in
the same TOFU store as Slice B's `from_ed25519` pin. Once a
peer has been observed sending an `envelope_version >= 2`,
refuse v1 envelopes from them. New CRIT-class slice (call it
**Slice B-min-version**, or fold into Slice B's TOFU step):

- Add `min_observed_version : int` field to the per-alias pin
  record (default 1, monotonic-increase).
- On every successful verify, update the pin's
  `min_observed_version = max(current, envelope_version)`.
- Before verify, if `envelope_version < pin.min_observed_version`,
  reject with audit-log line `event=relay_e2e_downgrade_reject`.
- Operator-rotation interface: deleting `relay_pins.json`
  resets the min-observed pin (consistent with #432 Slice E
  semantic — operator wipe = TOFU first-seen on next message).

**Risk-register update**:

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| MITM downgrade v2→v1 to bypass CRIT-1/2 | medium | high (silent identity spoof on known-v2 peer) | Slice B-min-version (above) |

### Stake-positions on the four open questions

Slate's recommendations (final answers awaiting Cairn/Max sign-
off, but these become the working assumptions for implementation
dispatch unless overridden):

1. **TS GUI verifier owner**: defer to Cairn/Max routing.
   Galaxy is the reasonable first-ask but no firm owner today.
2. **Soak window length**: **48h**. 24h misses cross-region
   weekend gaps; 7d delays the strict-v2 flip
   unnecessarily for what's a single-bit verifier toggle.
   Crypto-canary 48h is industry-typical.
3. **Pin-mismatch policy**: **envelope-only reject + audit
   log + explicit operator `pin_rotate`.** Alias-lock is too
   aggressive — legit key rotations would hard-lock peers and
   require manual unstick. Existing TOFU 4/5 + observability
   infra (#432) already routes that via the audit-log +
   operator-action pattern.
4. **`envelope_version` field name**: **explicit
   `envelope_version: int`**. Two reasons:
   (a) shape-detect is ambiguous when both new fields are
   optional — a v2 envelope omitting both is indistinguishable
   from v1 by shape;
   (b) coupling on `enc: "box-x25519-v2"` couples encryption
   suite with canonical-blob version, blocking independent
   evolution (e.g. swap to AES-GCM later without changing
   canonical_json shape).

---

🪨🧭 — stanza-coder + slate-coder

---

## Closure receipt 2026-04-29T19-08-00Z

- **CRIT-1**: closed by Slice A `1e414fdc` (`canonical_json_v2` covers `from_x25519`).
- **CRIT-2**: closed by Slice B `05fd2987`+`d1e27074` (envelope `from_ed25519` field + first-contact TOFU + mismatch reject), B-min-version (downgrade-attack defense designed at `6d59329f`, impl pending), and #432 Slice E (TOFU pin store foundation). Impl-audit confirms ~85% mechanism shipped: `.collab/research/2026-04-29T19-00-00Z-crit-2-impl-audit.md`.
- **5 follow-on slices** independently sized (relay_e2e_pin_first_seen audit log, Slice D operator surfaces, §7.1 parse-time reject, cross-host test, Slice C strict-v2 flip). None block closure.

— Cairn / slate / stanza

