# Relay-crypto CRIT-2: Ed25519 TOFU + key-rotation policy (architectural)

**Authors**: stanza-coder (drafted as subagent of slate-coder) +
slate-coder (dispatching parent)
**Date**: 2026-04-29
**Status**: design (doc-only; impl flowing through Slice B + follow-ons)
**Cross-ref**:
- Audit: `.collab/research/2026-04-29T04-22-52Z-slate-coder-relay-crypto-audit.md` §4 (CRIT-2).
- CRIT-1+2 plan-doc: `.collab/design/2026-04-29-relay-crypto-crit-fix-plan-cairn.md`
  (PASSed at `.c2c/peer-passes/0e15522f-slate-coder.json`).
- Slice B-min-version: `.collab/design/2026-04-29T17-00-00Z-stanza-slate-relay-crypto-slice-b-min-version.md`
  (cherry-picked at `6d59329f`).
- Slice A landed at `1e414fdc`.

---

## Resolved 2026-04-29T19-08-00Z — CRIT-2 mechanism shipped, design corrections noted

CRIT-2 mechanism is **~85% landed via Slice A + Slice B (`05fd2987`+`d1e27074`) + B-min-version + #432 Slice E**. Impl-audit by slate (subagent dispatch, NO-OP outcome): `.collab/research/2026-04-29T19-00-00Z-crit-2-impl-audit.md`. Three corrections to this design doc surfaced by the audit:

1. **No separate "relay-side TOFU".** This doc's framing of "relay-side mirror" was a misread. `relay.ml` / `relay_forwarder.ml` treat envelope content as opaque transport (zero references to `Relay_e2e.*` / `from_ed25519` / `verify_envelope_sig`). Crypto boundary: sender-broker → wire → receiver-broker, with TOFU at the receiver-broker (`c2c_mcp.ml decrypt_envelope`). The "verifier" in §2 is the receive-side broker (singular), not a relay-side mirror.

2. **Two pin stores exist; do not conflate.**
   - `Trust_pin` (`peer_review.ml`) — peer-pass artifact identity. Has `pin_rotate` with operator attestation + structured audit log.
   - `Broker.known_keys_ed25519` (`c2c_mcp.ml`) — relay-e2e envelope TOFU. No rotate, no attestation, only mismatch audit.
   §5.2's claim "`pin_rotate` already exists from #432 TOFU 4/5" applies to `Trust_pin`, **NOT** to the relay-pin store. If §5.2 is calling for parity (bringing Trust_pin's rotate semantics over to `relay_pins.json`), that's net-new (~50 LoC), tracked as Slice D follow-on.

3. **Storage shape diff (cosmetic, non-security).** §2.1 shows nested per-alias records `{from_ed25519_b64, first_seen_ts, last_seen_ts, min_observed_envelope_version}`. Reality is flat top-level sections: `{x25519: {alias: pk}, ed25519: {alias: pk}, min_observed_envelope_versions: {alias: int}}`. No `first_seen_ts` / `last_seen_ts` are stored. Documentation drift, not security defect.

### Mapping shipped → SHAs

| Design § | Component | SHA / file:line / test |
|---|---|---|
| §2.2 | First-contact pin write | `5dc0ad6b`, `c2c_mcp.ml:4620-4623` |
| §2.3 | Subsequent verify match → accept | landed (no `last_seen_ts` tracked) |
| §2.3 | Mismatch reject + audit log | `e5537bd4`, `c2c_mcp.ml:4567-4592` |
| §6 test 1 | First-contact pins | `test_slice_b_tofu_first_contact_pins` |
| §6 test 2 | Subsequent match accepts | `test_slice_b_tofu_already_pinned_accepts` |
| §6 test 3 | Mismatch rejects + audit log | `test_slice_b_tofu_mismatch_rejects` + `_followup_pin_mismatch_audit_log` |
| §7.2 | Pin persists across restart | `test_relay_pin_ed25519_persists_across_broker_recreate` |

### Follow-on slices (independent, none block CRIT-2 closure)

1. `relay_e2e_pin_first_seen` audit log (~25 LoC) — observability symmetry with `_pin_mismatch`
2. Slice D operator surfaces — `c2c relay-pins list / delete / [rotate]` (~80-110 LoC)
3. §7.1 parse-time reject of v2-without-`from_ed25519` (~10 LoC) — defense-in-depth
4. Cross-host divergence test (~50 LoC, optional per §7.3)
5. Slice C strict-v2 flip — deferred per §7.3 ops sign-off

— resolved by slate-coder via subagent audit dispatch (NO-OP, ~85% already shipped)

---

## TL;DR

The relay-e2e envelope today carries no `from_ed25519` field; receivers
have no continuity-of-identity guarantee across messages from a claimed
alias. This doc frames the **architectural shape** of the fix: TOFU
(trust-on-first-use) pinning of the sender's Ed25519 key on first
contact, mismatch-rejects on subsequent contact, **explicit operator
rotation only** (no auto-rotation, no multi-key history). Slice B
(stanza-coder, in flight) implements the immediate envelope-field +
first-contact pin; this doc captures the longer-term policy decisions
— scope cuts (single-key-per-alias for v1; per-host pin store), operator
surfaces, and the open questions Slice B's impl will touch but not
fully resolve.

**In scope**: the policy and architectural shape of relay-e2e Ed25519
TOFU.
**Deferred**: multi-key/key-history support, cross-host pin sync,
strict-v2 enforcement (Slice C in plan-doc), operator-surface UX details.

---

## 1. Threat model

### 1.1 Per-message identity swap (CRIT-2 baseline)

A peer claims alias `bob`, signs envelope 1 with Ed25519 key `K1`,
signs envelope 2 with Ed25519 key `K2`. Without TOFU, the verifier
checks each sig in isolation against whatever pubkey the envelope
carries (or implicitly trusts whoever holds *some* valid key for
`bob`). There is no continuity check tying envelopes to one identity.
Combined with CRIT-1 (already fixed at `1e414fdc`), an attacker who
holds *any* valid Ed25519 key and can claim any alias can completely
impersonate that alias mid-conversation.

### 1.2 Downgrade attack

Covered by Slice B-min-version (designed at 6d59329f). An MITM
rewrites `envelope_version: 2` → `envelope_version: 1` on the wire;
v1 canonical_json doesn't bind `from_ed25519`, so TOFU has no
material to check against. The min-observed-version pin closes this:
once a peer has been seen at v2, v1 envelopes from them are rejected
as version-downgrade.

### 1.3 Key compromise (mid-conversation pivot)

If an attacker compromises the legitimate peer's Ed25519 private key,
TOFU does not detect it — the attacker's envelopes verify with the
pinned key. This is the standard TOFU limitation; the mitigation is
out-of-band — operator notices anomaly, runs `pin_rotate` to invalidate
the compromised pin, peer is re-paired through a fresh first-contact
TOFU. **TOFU is not a key-compromise defense.** It is a continuity
defense — "I'm talking to the same identity I started talking to." We
document this explicitly so operators don't expect more.

### 1.4 Sybil / multi-key attempts

Two failure modes to consider:
- **Multiple aliases under same Ed25519 key.** An attacker registers
  aliases `bob` and `eve`, both signing with key `K`. TOFU pins `K`
  to `bob` on bob's first contact, AND `K` to `eve` on eve's first
  contact. This is allowed — TOFU pins are per-alias, not per-key.
  The threat of "key reuse signals collusion / compromised registrar"
  is out of scope for TOFU and lives at the broker registration layer.
- **Per-session key rotation by attacker.** An attacker holding alias
  `bob` rotates their Ed25519 key every session, hoping recipients
  re-pin. With our **mismatch-rejects** policy this fails: after the
  first session, `bob`'s pin is set; subsequent sessions with a
  different key get rejected. The attacker would need to convince an
  operator to run `pin_rotate` to recover, which (per #432 TOFU 4/5)
  is operator-attested with audit logging. Auto-rotation would defeat
  this; explicitly REJECTED below.

### 1.5 Cross-host considerations

The relay forwards an envelope between two hosts (#330 forwarder
lineage). Question: whose pin store is authoritative?

**Answer (this design): per-receiver-host, no global sync.** Each
receiving host has its own `relay_pins.json`. The same envelope
forwarded from host A to host B will pin the sender's Ed25519 key
*twice* (once at A, once at B), independently. The inner Ed25519
sig is end-to-end (signed before relay forwarding, verified after),
so each host sees the original `from_ed25519` and pins correctly.

We considered global pin sync (broker propagates pins to every
host on first-contact). **Rejected**: pin sync requires trusting
the sync transport, which exactly defeats TOFU's purpose ("trust
on first use, with the local host as the root of trust"). Cross-
host TOFU divergence is acceptable — a peer reaching two hosts
gets pinned at each independently. If the operator wants to pre-
populate pins (e.g. enterprise deployment), that's a separate
provisioning story handled outside the TOFU mechanism.

---

## 2. Mechanism

### 2.1 Storage shape

Per-alias record in `relay_pins.json` after Slice B + B-min-version:

```
{
  "<alias>": {
    "from_ed25519_b64": "<base64url Ed25519 pubkey>",
    "first_seen_ts": <int unix>,
    "last_seen_ts":  <int unix>,
    "min_observed_envelope_version": <int, default 1>
    // (other #432 Slice E fields, e.g. peer_pass record, retained)
  }
}
```

Atomic write semantics inherit from #432 Slice E (temp-file + fsync
+ rename, flock on `relay_pins.json.lock`).

**Note on `key_history`**: deliberately absent. See §4.

### 2.2 First-contact behavior

On receipt of an envelope where:
- `from_ed25519` is present (i.e. envelope_version >= 2),
- Ed25519 sig over canonical_json verifies against `from_ed25519`,
- AND no pin exists for `from` alias,

the verifier:
1. Writes a new pin record: `from_ed25519_b64 = <observed key>`,
   `first_seen_ts = now`, `last_seen_ts = now`,
   `min_observed_envelope_version = <observed version>`.
2. Emits audit-log line `event=relay_e2e_pin_first_seen alias=<alias>
   key_b64=<pubkey>`.
3. Accepts the envelope.

### 2.3 Subsequent verify

On receipt of an envelope where a pin already exists for `from`:
1. Look up `pin.from_ed25519_b64`.
2. Compare against envelope's `from_ed25519`.
3. **Match** → accept (after sig-verify), update `last_seen_ts` and
   max-update `min_observed_envelope_version`.
4. **Mismatch** → reject envelope, emit audit-log
   `event=relay_e2e_pin_mismatch alias=<alias> pinned_key_b64=<...>
   observed_key_b64=<...>`. Do NOT auto-rotate.

### 2.4 Key rotation policy

**Auto-rotation is REJECTED.** A pin mismatch is *always* an
operator-attended event. Justification:

- Auto-rotation defeats the per-session-key-rotation Sybil defense
  (§1.4): an attacker who can claim alias `bob` could rotate every
  session, and auto-rotation would silently follow.
- Auto-rotation with grace windows (e.g. "accept if mismatch but old
  key is still recent") leaks complexity and adds attack surface
  (timing games, race conditions across cross-host pin stores).
- Operator-attested rotation (existing `pin_rotate` from #432 TOFU
  4/5) is the right granularity. Audit log + explicit human action
  is the trust boundary.

If this turns out to be too friction-heavy in practice (operators
swamped by `pin_rotate` calls), revisit *after* observing real-world
mismatch rate. Don't pre-build the auto-rotation infra.

---

## 3. Multi-key support — design decision

**Recommendation**: **single-key-per-alias for v1.** No `key_history`
array. No grace-window for old keys. No "accept any key in the
last N pinned keys."

### Why

A multi-key history opens questions we don't have answers to:
- How long do old keys stay in history?
- What audit-log granularity is correct?
- What's the operator surface for trimming history?
- How does cross-host pin divergence interact with multi-key?

Each of these is a separate design slice. **The clean v1 shape is:
one pin per alias, mismatch is hard-reject, operator runs
`pin_rotate` to transition.** Operator wipes the pin (or rotates it
to the new key); next message from the peer triggers fresh
first-contact TOFU, audit-logged.

### Cost of this scope cut

Legitimate key rotations require operator action. In practice:
- Peer's session restart on the same Ed25519 key is fine (same key
  → same pin → no action).
- Peer regenerating their Ed25519 keypair (e.g. after machine wipe)
  triggers mismatch on next message; operator runs `pin_rotate
  <alias>` and that peer is re-pinned to the new key.

For a swarm where Ed25519 keys are stable across restarts (the
common case via `Relay_identity.load_or_create_at`), this friction
is rare. **Multi-key with grace-window is a follow-on, not a v1
requirement.**

### Future extension shape (sketch, not in scope)

If we later determine multi-key is needed: extend the per-alias
record with `key_history: [{key_b64, retired_ts}, ...]`, accept any
non-retired key, retire keys via `pin_rotate`. Storage shape is
forward-compatible — adding `key_history` later does not require
re-pinning.

---

## 4. Cross-host scope

Recap of §1.5 with the architectural framing:

- **Pin store is per-receiver-host.** Each host's `relay_pins.json`
  is independent.
- **Relay forwarding preserves the inner sig.** A → relay → B sees
  the same `from_ed25519` at A and at B. Each host's verifier
  performs TOFU pin against its own store.
- **No global pin sync.** Pin sync would require trusting the sync
  transport, defeating TOFU. Each host is its own root of trust.
- **Provisioning is separate.** If an operator wants to pre-populate
  pins across hosts (e.g. enterprise rollout), that's a configuration
  story outside the TOFU mechanism — out of scope here.

The corollary: a peer reaching two hosts goes through TOFU first-
contact at each. This is **intended** — each host independently
validates "this is the same identity I started talking to."

---

## 5. Operator surfaces

Three CLI commands form the operator interface to the TOFU pin
store. `pin_rotate` already exists from #432 TOFU 4/5; the `list`
and `delete` shapes are the new surfaces this design surfaces (Slice
D, below).

### 5.1 `c2c relay-pins list`

Prints current pins, one per line, with alias, pinned-key (truncated
b64), first-seen, last-seen, and min-observed-version. Read-only;
safe to run anytime.

### 5.2 `c2c relay-pins rotate <alias>`

Existing infra. Operator-attested: requires confirmation (TUI prompt
or `--yes`), records audit log, replaces pin's `from_ed25519_b64`
with the new key. Per Slice B-min-version §5, also resets
`min_observed_envelope_version` to 0.

### 5.3 `c2c relay-pins delete <alias>`

Wipes the pin record entirely. Next message from `<alias>` triggers
fresh TOFU first-contact (re-pins to whatever key the next message
carries). Audit-logged as `event=relay_e2e_pin_deleted alias=<...>
by_operator=<...>`.

Use cases: peer is permanently retired, alias is being recycled,
operator wants to test TOFU first-contact path.

### 5.4 Audit-log channels

All from #432 TOFU 4/5 lineage:
- `relay_e2e_pin_first_seen` — first contact, new pin written.
- `relay_e2e_pin_mismatch` — envelope rejected on key mismatch.
- `relay_e2e_pin_rotate_unauth` — attempted automated rotate (if
  any path tries to auto-rotate, this fires + the rotate is blocked).
- `relay_e2e_pin_deleted` — operator-wipe.
- `relay_e2e_downgrade_reject` — Slice B-min-version's check.

Operators tail these via existing `c2c tail-log` infrastructure;
nothing new at the audit surface beyond the channel names.

---

## 6. Slice decomposition

### Slice A (landed `1e414fdc`)
CRIT-1 fix. `from_x25519` covered by canonical_json v2 + `envelope_version` field.

### Slice B (stanza, in flight)
- Add `from_ed25519: string option` to envelope record.
- Include in canonical_json v2 (alongside `from_x25519`).
- Producer emits local Ed25519 pubkey via existing `Relay_identity.load_or_create_at`.
- Verifier: on sig-verify success, run TOFU pin against the in-memory
  `known_keys_ed25519` Hashtbl (existing #432 Slice E store).
  - First contact → write pin, audit `relay_e2e_pin_first_seen`.
  - Already pinned, key matches → accept, update `last_seen_ts`.
  - Already pinned, key mismatch → reject, audit `relay_e2e_pin_mismatch`.
- Legacy v1 envelopes (no `from_ed25519`) → accept WITHOUT TOFU update.
  Documented compromise: legacy senders pre-cutover get no TOFU.
- ~220 LoC per CRIT-1 plan-doc estimate. Splittable as B1+B2 if
  scope-pressure surfaces.

### Slice B-min-version (designed at `6d59329f`)
Per-peer min-observed-version pin. Closes the downgrade-attack window.
~110 LOC.

### Slice C (CRIT-1 plan-doc, optional)
Strict-v2 verifier flip behind `C2C_RELAY_E2E_STRICT_V2=1`. Default off
until ops sign-off after a soak window. Single-bit verifier toggle.

### Slice D (this design, NEW)
Operator surfaces — `c2c relay-pins list` and `c2c relay-pins delete`.
`pin_rotate` already exists. ~80 LOC bounded:
- `list` = read pin store + format.
- `delete` = atomic pin removal + audit-log line.
- Minimal CLI subcommand wiring under the existing `c2c relay-pins`
  group.

Slice D is independent of Slice C; it can land any time after Slice B.

---

## 7. Open questions

### 7.1 Should `from_ed25519` be required for v2 envelopes?

**Recommend YES, required for v2.** TOFU has no value if an attacker
can simply omit the field on otherwise-v2 envelopes. Concretely:

- v1 envelopes (`envelope_version=1`): no `from_ed25519`, accept
  without TOFU (legacy window).
- v2 envelopes (`envelope_version=2`): MUST carry `from_ed25519`;
  v2 envelopes lacking the field are rejected as malformed.

Slice B impl should enforce this in the v2 parsing path. Any v2
envelope without `from_ed25519` is a bug or attack — either way,
reject is the right behavior.

### 7.2 Should TOFU pin propagate via `send_memory` so a session restart preserves the pin?

**Recommend YES, persist via `relay_pins.json`.** This is already the
plan in Slice B; calling it out explicitly so it doesn't get lost:
- The pin store is disk-backed (`relay_pins.json`).
- On restart, the broker re-reads the file → pins are preserved.
- No `send_memory` traffic involved — the pin is local-only state,
  and per §4 cross-host sync is explicitly out of scope.
- Memory subsystem (#163) handles agent-level continuity (notes,
  context); it's the wrong layer for crypto pin state.

### 7.3 Soak window for strict-v2 + strict-TOFU flip (Slice C dependency)

**Defer to ops.** Slate's plan-doc stake-position is 48h; that's a
defensible default but the right answer depends on:
- Cross-region weekend gap considerations.
- TS GUI cutover progress (does the GUI verifier accept v2 yet?).
- Mismatch-rate observed in `relay_e2e_pin_mismatch` audit logs
  during the soak (high rate ⇒ extend; low rate ⇒ flip sooner).

This design records the question; the answer happens at Slice C
landing time.

---

## 8. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Pin store corruption (disk failure mid-write) | low | high (peers fail TOFU until restored) | Atomic write + fsync + rename pattern (existing #432 Slice E); audit log retains first-seen events for forensic recovery |
| Operator missed audit log → silent mismatch reject | medium | medium (peer thinks they're sending; recipient silently rejects) | Audit-log channels documented in §5.4; operator runbook should call out `relay_e2e_pin_mismatch` as a watch-channel |
| Legitimate peer key rotation requires manual action | medium | low (one `pin_rotate` per legitimate rotation) | Documented as deliberate scope cut (§3); revisit if friction rate is high |
| Cross-host TOFU divergence confuses operators | low | low (each host pins independently; no global view) | Documented in §4; `c2c relay-pins list` per-host gives the local view |
| v2 envelopes lacking `from_ed25519` slip through | low | high (TOFU bypassed) | §7.1 — v2 parsing rejects missing-field envelopes as malformed |
| Multi-key need surfaces unexpectedly post-v1 | low | medium (peers with rotating keys hit friction) | Forward-compatible storage shape (§3); add `key_history` later without re-pinning |
| Operator wipes `relay_pins.json` and re-TOFUs against attacker | low | high (loss of identity continuity) | Audit-log records first-seen events; operator should compare key against prior records before wholesale wipe; `delete <alias>` is per-alias, more conservative |

---

## 9. Receipts

- Slate's audit doc: `.collab/research/2026-04-29T04-22-52Z-slate-coder-relay-crypto-audit.md` §4 (CRIT-2).
- CRIT-1+2 plan-doc: `.collab/design/2026-04-29-relay-crypto-crit-fix-plan-cairn.md`.
  - PASS artifact: `.c2c/peer-passes/0e15522f-slate-coder.json`.
- Slice B-min-version: `.collab/design/2026-04-29T17-00-00Z-stanza-slate-relay-crypto-slice-b-min-version.md`
  (cherry-picked at `6d59329f`).
- Slice A landing SHA: `1e414fdc` (`feat(crit-1): cover from_x25519
  in relay_e2e canonical_json behind envelope_version`).
- TOFU pin store + `pin_rotate` lineage: #432 Slice E + TOFU 4/5 +
  observability.
- Cross-host forwarder context: #330 (`relay_forwarder.ml`).

---

— stanza-coder (subagent of slate-coder) + slate-coder
