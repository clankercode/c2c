# Design: End-to-End Encryption for c2c Messages

**Author**: Cairn (cairn-vigil / coordinator1)
**Date**: 2026-04-29
**Status**: design — synthesizes existing M1 crypto work + gap analysis
**Related**:
- `ocaml/relay_enc.ml` — X25519 keypair persistence (LANDED)
- `ocaml/relay_e2e.ml` — NaCl box + signed envelope primitives (LANDED)
- `ocaml/relay_identity.ml` — Ed25519 identity (LANDED #133, #427b)
- `.projects/c2c-mobile-app/M1-breakdown.md` §S1-S3 (canonical wire spec)
- `.collab/design/2026-04-24-per-agent-git-signing.md` (peer-PASS signing)

## TL;DR

**Most of the crypto already exists.** `relay_e2e.ml` ships NaCl box,
canonical-JSON Ed25519 envelope signing, multi-recipient recipient
arrays, downgrade-state tracking, and TOFU helpers. `relay_enc.ml`
manages per-session X25519 keypairs on disk. The wire format
(`enc:"box-x25519-v1" | "plain"`) is locked.

**The gap is integration into the live c2c message path.** Today
`Broker.enqueue_message` writes cleartext envelopes (`<c2c
event="message">…</c2c>`) to inbox JSON files. Sender → broker →
relay → recipient broker → recipient is ALL cleartext. The relay
operator can read every DM and every room broadcast. The crypto
primitives sit unused alongside the cleartext path.

**v1 scope (recommended)**: opportunistic 1:1 DM encryption using
existing `relay_e2e` primitives, gated by per-alias X25519 pubkey
publication in the registry. Rooms stay cleartext for v1 (group
crypto is a separate slice). No forward secrecy; static long-term
X25519 keys per alias.

---

## 1. Threat Model

### Protects against
- **Passive relay snooping**. Relay sees `enc="box-x25519-v1"` +
  ciphertext + recipient alias list; cannot read message body.
- **Body MITM**. Envelope is Ed25519-signed by sender over canonical
  JSON of `{from, to, room, ts, enc, recipients}`. Tampering with
  ciphertext, recipients, or `enc` field invalidates sig. Receiver
  drops on sig-fail.
- **Replay** (best-effort). `ts` is in canonical-JSON sig payload;
  receiver can dedupe by `(from, ts, sig)`. v1 does not require an
  explicit nonce-cache for replay defense — the broker's existing
  message-id dedup is acceptable.
- **Silent key swap by relay**. TOFU pin store rejects key changes
  unless operator runs `c2c trust --repin <alias>`.

### Does NOT protect against
- **Host compromise**. Private keys at `<broker>/keys/<alias>.x25519`
  mode 0600 are readable by any same-user process (M1 §S1 I1 — OS
  keyring deferred to M3).
- **Metadata leak via routing**. `from`, `to`, `room`, `ts` are
  cleartext on the envelope (relay must route on them). Sealed
  Sender = v2+.
- **Swarm-wide identity consensus**. TOFU is pairwise, not transitive.
  Real PKI / multi-host key-gossip is out of v1 scope.
- **Past-key compromise** (no forward secrecy v1). Rotation is the
  mitigation.
- **Ed25519 signing key compromise**. Same key signs peer-PASSes /
  git commits = identity theft.

---

## 2. Key Infrastructure

### Reuse decision
**Two keypairs per alias**, stored together under
`<broker_root>/keys/<alias>.{ed25519,x25519}`:

- **Ed25519 (signing)**: already exists per #133. Used for envelope
  sig, peer-PASS, git commit signing. Don't reuse for encryption —
  Ed25519→X25519 conversion is possible but conflates audiences,
  forces both keys to rotate together, and reduces ability to revoke
  a compromised encryption key without invalidating signing history.
- **X25519 (encryption)**: already exists per `relay_enc.ml`. Today
  it is keyed by `session_id` not `alias`; v1 migration repaths it
  to `<broker_root>/keys/<alias>.x25519` matching the Ed25519
  convention. Lazy-create on first sign / first send.

### Static long-term vs ratchet
**v1: static long-term X25519 per alias.** Signal-style
double-ratchet is the correct end-state but requires:
- Per-pair session state on both ends.
- Ordered, reliable transport for ratchet steps (we have this via
  the broker, but it's currently best-effort).
- Out-of-band key bundle exchange (prekey upload).

For local-broker swarm + opportunistic E2E, static keys give 95% of
the value at 5% of the complexity. Ratchet is a v3 slice.

### Key generation
- On `c2c register`: lazy-create `<broker>/keys/<alias>.x25519`
  alongside the existing `.ed25519` lazy-create.
- Publish `x25519_pubkey` + `ed25519_pubkey` into the registry
  entry for the alias (broker `registrations.yaml`).
- On rotation: `c2c keys rotate --enc` regenerates X25519 only;
  signs an explicit "rotation" envelope to peers carrying old +
  new pubkeys (verifiable transition).

---

## 3. Envelope Format

**Locked per `relay_e2e.envelope` + M1 §S3.** Wire format is JSON,
not the legacy `<c2c event="message">` XML wrapper. The XML wrapper
is the **transcript-injection** form (what the receiving agent sees
in its prompt); the JSON envelope is the **on-wire** form between
brokers/relays.

```json
{
  "from":  "<canonical_alias>",
  "from_x25519": "<b64 x25519 pubkey>" | absent (legacy),
  "to":    "<canonical_alias>" | null,
  "room":  "<room_id>" | null,
  "ts":    <epoch_ms>,
  "enc":   "box-x25519-v1" | "plain",
  "recipients": [
    { "alias": "<canon>", "nonce": "<b64 24B>" | null,
      "ciphertext": "<b64>" }
  ],
  "sig":   "<b64 Ed25519 sig over canonical JSON>"
}
```

**Plaintext fallback**: `enc:"plain"` keeps shape uniform — `nonce`
is `null`, `ciphertext` holds the b64 plaintext body. Sig still
required. This is the rollout path: pre-rollout senders emit
`enc:"plain"`, post-rollout senders emit `enc:"box-x25519-v1"` when
recipient pubkey is known.

**XML wrapper unchanged for the agent transcript.** When the broker
delivers a decrypted message into the agent's transcript, it
re-emits the legacy `<c2c event="message" from="…" alias="…">body</c2c>`
form. No agent prompts change. The encryption is invisible to the
LLM session — it's a broker-broker concern.

**Backward compat**: brokers without E2E support write `enc:"plain"`
and consume any `enc` value as cleartext (extracting `ciphertext`
b64-decoded). New brokers detect `enc="box-x25519-v1"` and decrypt;
on missing recipient pubkey, they emit a downgrade-warning.

---

## 4. Group Messages (Rooms)

**v1 scope: rooms remain cleartext.** Rooms are a 4D problem:
- Membership snapshot at send time (M1 §S3 has the rationale —
  late-joiners can't decrypt past messages, leavers still can).
- Sender Keys / group ratchet for forward secrecy on join/leave.
- Re-key ceremony triggered by membership change.
- Archive replay for new joiners (`room_history`).

**v2 path (sketched)**: per-room sender-key. Each room member
maintains their own symmetric "sender key" + chain key; broadcasts a
fresh sender-key-encrypted-to-each-current-member on join/leave. New
joiners receive the current sender key from any existing member;
they cannot read pre-join messages (acceptable). This is Signal
Sender Keys with our membership semantics.

**v1 stopgap**: `room.private = true` flag — encrypts to a static
pre-shared room key distributed out-of-band by the room creator.
Loses forward secrecy on member departure; user accepts that
tradeoff explicitly. Useful for `swarm-private` / coordinator-only
rooms today; not the long-term answer.

For group N:N: don't naively encrypt-N-times — a 50-member room
with 1 KB body produces a 50 KB envelope. Sender-key amortizes:
encrypt body ONCE under symmetric sender key, then encrypt the
sender key once per member (32-byte payload each).

---

## 5. Forward Secrecy

**v1: no FS.** Static long-term X25519 keys mean past-key compromise
decrypts intercepted ciphertexts retroactively. Acceptable for the
threat model:
- Local swarm: physical access to the host = game over anyway.
- Relay-snooping defense: the relay isn't archiving ciphertexts in
  practice (broker-relay is a transit hop, not a store). Even a
  malicious archive only compromises until next rotation.
- Cost: rotation is cheap (`c2c keys rotate --enc`); operators can
  rotate weekly without much friction once tooling exists.

**v3 path**: X3DH + Double Ratchet (Signal). Requires prekey bundle
upload to the relay or out-of-band, per-pair ratchet state, and
ordered delivery. Big slice; do AFTER v1 is dogfooded.

**Sealed Sender / metadata privacy**: separate from FS; also v2+.
Both share the property that they need a richer relay protocol than
the current "route by from/to" — relay needs to route by an
ephemeral routing token while body+identity are sealed.

---

## 6. Migration & Key Distribution

### How peers learn each other's pubkey

**Primary path: broker registry.** `registrations.yaml` already
holds `{alias, session_id, ts}`. Extend with `{ed25519_pubkey,
x25519_pubkey, pubkey_signed_at, pubkey_sig}`. Brokers gossip the
registry via the relay (existing path). Senders look up by alias.

**TOFU pin on first contact.** Receiver pins
`(alias, ed25519_pk, x25519_pk)` in
`<broker_root>/known_keys/<alias>.json` on first verified envelope.
Subsequent envelopes that resolve to a different pk → drop +
`enc_status:"key-changed"` + require operator `c2c trust --repin`.

**Out-of-band fallback (paranoid path)**: `c2c keys export <alias>`
emits a printable fingerprint card; operator confirms over voice or
QR. Re-pin via `c2c trust --pin <alias> --pubkey <fp>`. Useful for
the very-first-pair handshake before TOFU has anything to pin
against.

### Mixed-version swarm during rollout

- Old broker → new broker: old emits `enc:"plain"`, new accepts.
  Recipient sees `enc_status:"plain"` (no warning — first contact).
- New broker → old broker: new emits `enc:"plain"` (pubkey-absent
  fallback), old reads it. Or: new emits `enc:"box-x25519-v1"`, old
  cannot parse — drops or surfaces unknown-enc error. Decision:
  **fall back to plain when recipient pubkey unknown.** Once both
  ends are upgraded, both have published pubkeys, and both upgrade
  to encrypted automatically.
- Downgrade detection per-sender (existing): once a peer has been
  observed sending `box-x25519-v1`, any subsequent `plain` from them
  is `enc_status:"downgrade-warning"`.

---

## 7. Performance

- **Per-message cost**: Ed25519 sign ~50 µs; X25519 ECDH +
  XSalsa20-Poly1305 ~100 µs per recipient for 1 KB body. Multi-recipient
  amortizes via `box_beforenm` (precompute shared key ~80 µs) +
  `box_afternm` per recipient (~30 µs). Total: ~200 µs DM, ~300 µs
  5-recipient room. Negligible vs broker round-trip (~5 ms).
- **Archive decryption**: archive stored as decrypted plaintext today.
  v1 keeps that — decrypt on receive, archive plaintext. Encrypting
  at rest is a separate concern (FS-level / OS keyring layer, not
  message-level).
- **Rotation**: default never; recommended monthly via `c2c keys
  rotate --enc`; compromise = immediate + signed rotation envelope.

---

## 8. Open Questions (for Max + crypto sanity check)

1. **Signing key reuse risk?** Same Ed25519 key signs envelopes,
   peer-PASSes, and git commits. Cross-protocol confusion attacks
   are mitigated by domain-separation in canonical-JSON (each
   surface has distinct serialized shape). Worth a separate
   per-purpose Ed25519 subkey via HKDF? Or accept conflation for
   v1?
2. **Relay-side advisory verify**: M1 §S3 specifies relay
   SHOULD verify envelope sig (defense-in-depth) before forwarding.
   Is the perf cost (one Ed25519 verify per message) acceptable
   at relay-mesh scale? Today: yes, absolutely. Document as a
   relay knob (`C2C_RELAY_VERIFY_ENVELOPE_SIG`).
3. **Pubkey-rotation UX**: today TOFU mismatch = drop. Operators
   under-react to "drop + re-pin" prompts (see #29 H2B TOFU work).
   Should the first cleartext-on-mismatch envelope be queued and
   redelivered post-repin, or hard-dropped? v1 recommendation:
   hard-drop with a clear `c2c doctor` surface.
4. **TOFU pin sharing across worktrees**: peer-PASS already pins
   under `<broker_root>/peer-pass-trust.json` (one per repo).
   Encryption pins should share the same broker root. Confirm:
   `<broker_root>/known_keys/` is the right layer.
5. **Plain-by-policy senders**: should there be a per-recipient
   opt-out (`c2c send <alias> --no-encrypt <body>`)? Operationally
   useful for debugging; security-wise it weakens the
   downgrade-warning signal. Recommendation: NO — if you want
   plaintext, use `c2c log` not `c2c send`.

---

## 9. Implementation Slices

Total v1: ~5-7 slices, each PR-sized.

### Slice 1 — Per-alias X25519 keypair generation
- Migrate `relay_enc.ml` from `session_id`-keyed to `alias`-keyed,
  parallel to `relay_identity.ml`'s `<broker>/keys/<alias>.ed25519`.
- Extend `Relay_enc.load_or_create_at ~path ~alias_hint`.
- On `c2c register`: lazy-create both `.ed25519` and `.x25519`.
- Tests: roundtrip, persistence, key matches.

### Slice 2 — Pubkey publication via registry
- Extend `c2c_registry.ml` registration record with
  `ed25519_pubkey`, `x25519_pubkey`, `pubkey_signed_at`,
  `pubkey_sig` (Ed25519 sig over `alias || ed25519_pk || x25519_pk
  || ts` by Ed25519 key).
- `c2c whoami --show-keys`: print fingerprints.
- Tests: registry roundtrip, signed pubkey verifies.

### Slice 3 — Outbound: opportunistic 1:1 DM encryption
- In `Broker.enqueue_message`: on send, look up recipient's
  x25519_pubkey in registry. Present → encrypt + sign envelope via
  `relay_e2e.encrypt_for_recipient`. Absent → emit `enc:"plain"`
  with sig.
- TOFU pin check on outbound (M1 C3).
- Tests: roundtrip with two test brokers; pubkey-absent → plain;
  pubkey-mismatch → abort + `enc_status:"key-changed"`.

### Slice 4 — Inbound: decrypt + downgrade-state
- On `poll_inbox` / archive write: parse envelope, verify sig,
  decrypt own recipients[] entry.
- TOFU first-pin + mismatch handling.
- Surface `enc_status` in delivered message metadata (NOT in body).
- Maintain per-sender `seen_encrypted` bit for downgrade detection.
- Tests: cover all 6 `enc_status` variants from `relay_e2e.ml`.

### Slice 5 — TOFU CLI + doctor surface
- `c2c trust list | pin <alias> --pubkey <fp> | repin <alias> |
  forget <alias>`.
- `c2c doctor encryption`: scans local `known_keys/` vs registry,
  reports drift; lists peers without pubkeys (plain-only).
- Tests: pin lifecycle; doctor reports drift correctly.

### Slice 6 — Migration tooling + rollout flag
- `C2C_E2E_REQUIRED=1` env var: refuses to send `enc:"plain"`
  even if recipient pubkey absent (returns explicit error).
- `c2c keys rotate --enc` + signed-rotation envelope.
- Doctor: warns if any peer is on cleartext-only.
- Tests: rotation envelope verifies + updates pin atomically.

### Slice 7 (deferred but scoped) — Room encryption (v2)
- Sender-key per room. Re-key on join/leave.
- Pre-shared static-key mode (Slice 7a) as immediate v1 stopgap
  for `swarm-private`-style rooms.
- Tests: 3-member rotate-on-leave roundtrip.

---

## 10. NOT in Scope

- **Forward secrecy / Double Ratchet** — v3 slice. Static keys
  with cheap rotation is v1.
- **Sealed Sender / metadata privacy** — v2+ slice. Routing-layer
  identity remains cleartext.
- **Anonymity / unlinkability** — out of scope at the c2c protocol
  layer entirely. Use Tor or a mixnet underneath if needed.
- **Post-quantum** — out of scope. Reassess in 2027+.
- **OS-level key storage (keyring/Secure Enclave)** — M3 slice.
  v1 lives at `~/.c2c/keys/` mode 0600.
- **Swarm-wide PKI / transitive trust** — TOFU is pairwise. A real
  cross-host alias-to-pubkey consensus is a future research project
  (could be CT-log style or gossip-based).
- **Multi-device same-alias** — today `<alias>` is `(name) +
  (host)`-scoped via canonical alias. Same human on two machines =
  two aliases. Intentional for v1.

---

## Recommended v1 Scope

Slices 1-5 (everything except rotation tooling and room crypto).
~2-3 weeks of focused work given the primitives already exist. The
hardest part is wiring `relay_e2e` into `Broker.enqueue_message`
and the inbox-archive path without breaking existing fixtures.

Coordinator sign-off blockers:
1. Confirm signing-key reuse decision (Open Q1).
2. Confirm TOFU pin path (Open Q4) — share with peer-PASS or
   independent.
3. Confirm rollout: gradual opportunistic (recommended) vs hard
   cutover (`C2C_E2E_REQUIRED=1` from day 1).
