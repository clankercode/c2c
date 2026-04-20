# c2c relay — peer identity spec (Ed25519)

**Author:** planner1 · **Created:** 2026-04-21 · **Status:** draft for review
**Scope:** Layer 3 of `docs/c2c-research/relay-internet-build-plan.md`
**Related:** `docs/c2c-research/e2e-encrypted-relay-architecture.md` §3
(Identity key pair choice), §5.4 (bootstrapping)

This spec defines the concrete wire format, storage format, and
registration / authentication flow for Ed25519 peer identity in c2c.
Layer 1 (transport abstraction) and Layer 2 (TLS + operator token)
are assumed complete — this layer is what replaces the shared bearer
token for *peer* endpoints. Admin endpoints keep the operator token.

Scope is v1 (online-mediated registry). Referral chains and fully
decentralized identity are v2 — see §10.

**Implementation direction (2026-04-21 steering from Max via
coordinator1):** Python is deprecated long-term. This spec therefore
lands in OCaml first. Python is only referenced as a test harness
and a back-compat target during the transition — any new relay
feature ships in OCaml before it ships in Python, and the Python
relay implementation is eventually deleted.

---

## 1. Primitives and library choices

OCaml is the primary target. Python columns are only for the transitional
test harness / legacy relay; new callers should not add Python deps.

| Purpose             | Algorithm             | OCaml lib (primary)                  | Python lib (test-only) |
|---------------------|-----------------------|--------------------------------------|------------------------|
| Signing             | Ed25519 (RFC 8032)    | `mirage-crypto-ec` (recommended)     | `PyNaCl` ≥ 1.5         |
| Hashing             | SHA-256               | `digestif`                           | `hashlib` stdlib       |
| Random              | CSPRNG                | `mirage-crypto-rng`                  | `secrets` stdlib       |
| Encoding            | base64url-nopad       | `base64` opam pkg (`uri_safe`)       | `base64.urlsafe`       |

**OCaml crypto lib recommendation:** lead with `mirage-crypto-ec` over
`hacl-star`. Rationale: `mirage-crypto-*` is already used in the
ocaml-tls / cohttp-lwt-unix.tls stack we're adopting for Layer 2, so
Layer 3 inherits the dep for free. `hacl-star` is formally verified
but has heavier transitive deps and we'd be adding it only for
Ed25519. Revisit if a build / link issue emerges during spike.

Why Ed25519: deterministic, 32-byte public keys, fast verify, tiny
signatures (64 B), library-available everywhere we care about.

No third-party CA chain at this layer — identity is self-asserted,
with relay acting as the trusted binder (v1) and X3DH-style prekey
server (v2).

---

## 2. On-disk identity format

Location: `~/.config/c2c/identity.json`

Permissions: `0600` on the file, `0700` on the parent directory.
`c2c relay identity init` enforces both on creation and rejects
loading a world- or group-readable file (refuse-to-start, not
downgrade-to-warn — mirror ssh's behavior on `~/.ssh/id_ed25519`).

Schema:

```json
{
  "version": 1,
  "alg": "ed25519",
  "public_key":  "<base64url-nopad 32 bytes>",
  "private_key": "<base64url-nopad 32 bytes of seed>",
  "fingerprint": "SHA256:<base64url-nopad truncated-to-43 chars>",
  "created_at":  "2026-04-21T00:00:00Z",
  "alias_hint":  "planner1"
}
```

Notes:
- `private_key` stores the 32-byte *seed* (PyNaCl `SigningKey.encode()`),
  not the 64-byte expanded secret. Seed is enough to rederive both
  halves on load. Saves 32 bytes and matches the OpenSSH format.
- `fingerprint` is SHA-256 over the raw 32-byte public key,
  base64url-nopad, truncated to 43 chars (mimics ssh fingerprints
  so users can eyeball). Computed once and cached; never load-time
  recomputed.
- `alias_hint` is informational. Binding happens at the relay, not
  here — a compromised host can lie about `alias_hint` but not about
  the key it controls.
- No passphrase in v1. v1.5 can add KDF-wrapping (scrypt or argon2id)
  under `private_key_enc` with a new version=2 marker.

---

## 3. Wire formats

### 3.1 Base64 convention

All binary fields on the wire are **base64url-nopad** (RFC 4648 §5).
Never standard base64; never padded. This avoids `+` / `/` clashing
with URL + header delimiters and keeps signatures short.

### 3.2 Public key

32 bytes → 43 chars base64url-nopad.

### 3.3 Signature

64 bytes → 86 chars base64url-nopad.

### 3.4 Canonical message to sign

Every signed message is a **single byte string** built by joining
fields with `\x1f` (ASCII unit separator, 0x1F) — never JSON
(serialization ambiguity) and never newline-separated (escaping
headaches).

```
SIGN_CTX || "\x1f" || FIELD_1 || "\x1f" || FIELD_2 || ...
```

`SIGN_CTX` is a per-purpose literal constant starting with `c2c/v1/`
so the same key can safely sign different contexts without
cross-protocol replays. Contexts defined in this spec:

| Context                    | Purpose                                    |
|----------------------------|--------------------------------------------|
| `c2c/v1/register`          | First-time registration with the relay     |
| `c2c/v1/request`           | Per-request auth on peer endpoints         |
| `c2c/v1/rotate`            | Identity rotation (new key signs old key)  |
| `c2c/v1/room-invite`       | Signed room invite envelope (Layer 4)      |

---

## 4. Registration handshake

One-shot HTTPS POST to `/register` on the relay. Replaces the current
relay registration path.

### 4.1 Request body

```json
{
  "alias":        "planner1",
  "identity_pk":  "<base64url-nopad 32 bytes>",
  "timestamp":    "2026-04-21T00:05:30Z",
  "nonce":        "<base64url-nopad 16 random bytes>",
  "signature":    "<base64url-nopad 64 bytes>"
}
```

### 4.2 Signed bytes

```
"c2c/v1/register" \x1f
alias             \x1f
relay_url         \x1f   (client's configured relay URL, lowercased)
identity_pk_b64   \x1f
timestamp         \x1f
nonce_b64
```

`relay_url` in the signed blob binds the handshake to the exact
relay a client thought it was talking to — prevents a hostile relay
from replaying a registration to another relay.

### 4.3 Relay-side verification

Relay must:

1. Reject if `timestamp` is more than **120 s** in the past or **30 s**
   in the future (tolerate mild clock skew, reject obvious replay).
2. Reject if `nonce` has been seen in the last 10 minutes (small
   in-memory Bloom / LRU; TTL generous enough to dwarf timestamp
   window).
3. Verify Ed25519 signature against `identity_pk`.
4. Enforce **first-bind-wins** on `(alias, identity_pk)`:
   - Unknown alias → insert.
   - Known alias, matching pk → idempotent success (refresh PID/ts).
   - Known alias, different pk → **reject with 409 Conflict**, unless
     a valid rotation proof is presented (§7). Never silently
     overwrite.
5. On success, persist `(alias, identity_pk, first_seen_at,
   last_seen_at)` in registry.

### 4.4 Response

```json
{
  "ok": true,
  "alias": "planner1",
  "session_token": "<opaque short-lived token, 32 B, base64url>",
  "fingerprint": "SHA256:...",
  "relay_time":   "2026-04-21T00:05:30Z"
}
```

`session_token` is optional and purely an optimization: if present,
subsequent requests can carry `Authorization: Bearer <session_token>`
instead of Ed25519-signing every request. Tokens expire after 1 hour
and are always refreshable via a fresh signed request. v1 may skip
tokens entirely and sign every request — spec leaves the choice to
the implementer.

---

## 5. Per-request authentication

Every peer-facing relay endpoint requires authentication. Two
accepted forms:

### 5.1 Ed25519-per-request (mandatory baseline)

Header:

```
Authorization: Ed25519 alias=<alias>,ts=<unix-seconds>,nonce=<b64>,sig=<b64>
```

Signed bytes:

```
"c2c/v1/request" \x1f
method            \x1f   (uppercase HTTP verb)
path              \x1f   (starts with /, no query string)
query             \x1f   (raw query string or "" if none; sorted)
body_sha256_b64   \x1f   (base64url-nopad of sha256(body), "" for no body)
ts                \x1f
nonce
```

Replay protection: same window and nonce rules as §4.3 with smaller
tolerances — **30 s past / 5 s future, 2 min nonce TTL**.

### 5.2 Session token (optional shortcut)

```
Authorization: Bearer <session_token>
```

Relay checks token → maps to `(alias, identity_pk)` → proceeds as if
authenticated. No signature required.

Tradeoff: tokens are bearer credentials — an MITM who breaks TLS can
replay them. Spec keeps §5.1 mandatory so security-conscious
deployments can disable tokens outright (`C2C_RELAY_DISABLE_TOKENS=1`).

---

## 6. Registry schema change

Current registry (pre-Layer-3) binds `alias → (session_id, pid,
registered_at)`. Layer 3 adds:

```
alias
├── identity_pk       (base64url-nopad string, required post-L3)
├── fingerprint       (derived, cached)
├── first_seen_at     (ISO8601)
├── last_seen_at      (ISO8601)
├── pid / session_id  (unchanged)
└── identity_history  (optional, see §7)
```

**Migration:** on the first upgraded relay start, any alias without
`identity_pk` is flagged as **legacy** and only accepts registration
from a key claiming it during a grace period (default 7 days,
configurable). After the grace period, legacy entries are purged.
Clients upgrading to the new binary auto-generate a key and
re-register on startup, so the grace period is rarely exercised in
practice.

---

## 7. Key rotation

A user who still holds their old key but wants to rotate can POST to
`/rotate` with:

```json
{
  "alias": "planner1",
  "old_pk": "<b64>",
  "new_pk": "<b64>",
  "timestamp": "...",
  "nonce": "<b64>",
  "sig_by_old": "<b64>",
  "sig_by_new": "<b64>"
}
```

Both signatures cover the same canonical blob with context
`c2c/v1/rotate` — this proves continuous ownership.

Relay updates the binding atomically, appends a row to
`identity_history`, and invalidates any outstanding session tokens.

If the old key is lost, rotation is an out-of-band operator action
(see §10) — we do **not** accept a "new key, no old signature"
request over the public API.

---

## 8. `c2c relay identity` subcommand

New verb added directly to the OCaml CLI (`ocaml/cli/c2c.ml`), using
the OCaml crypto stack above. No Python shell-out — this is a new
feature and per the OCaml-first steering it lands in OCaml natively.

```
c2c relay identity init         # generate keypair, write identity.json
c2c relay identity show         # print alias, fingerprint, created_at
c2c relay identity fingerprint  # one-line fingerprint output
c2c relay identity rotate       # generate new key, prove with old
c2c relay identity import <file>   # adopt an existing keypair (dev/test)
c2c relay identity export        # print public key in SSH-ish format
```

All subcommands must be safe to run without a relay configured.
`init` is idempotent — running it when a key exists is a no-op +
informational print, never an overwrite (use `--force` to regenerate,
and even then print a warning that existing relay bindings will need
rotation).

---

## 9. Security properties & non-properties

**Properties:**
- An attacker who controls the TLS tunnel but not `identity_sk` cannot
  impersonate a sender. Verified by contract test: re-signing a
  captured request with a different key → `401 unauthorized`.
- First-bind-wins on alias means an attacker cannot squat a live
  alias, only an unclaimed one (and only if the real owner hasn't
  registered yet). Mitigated further by alias-reservation in the
  allowlist (§10).
- Compromise of the relay DB does NOT let the attacker forge
  messages from existing peers (signatures are checked against
  stored `identity_pk`; attacker would need to also publish a
  rotation or convince a client to accept a new key).
- Nonce + timestamp windows bound replay to a narrow interval.

**Non-properties (by design, v1):**
- No forward secrecy on the transport-auth layer itself. Relay can
  correlate all signed requests from the same alias. Fixed in v2
  when content is E2E-encrypted — relay sees ciphertext only.
- No MITM protection against a compromised operator. A malicious
  relay operator can replace `identity_pk` entries in their own
  registry and impersonate peers to other peers. Fixed in v2 when
  peers verify each other's `identity_pk` out-of-band (TOFU +
  fingerprint display).
- No deniability. Signed messages are non-repudiable. Not
  addressable at this layer; would require XEdDSA or a deniable
  auth construction, deferred.

---

## 10. Identity bootstrapping

Per §5.4 of the crypto architecture doc. v1 supports:

1. **First-message proof**: the registration handshake is self-
   asserting. Alias collision is a hard error, so the first mover
   wins a given (relay, alias) pair. Fine for small private swarms.
2. **Operator allowlist**: relay operator can pre-populate
   `(alias, identity_pk)` pairs in `relay_config.json` under
   `allowed_identities`. A registration matching a pre-populated
   pair is auto-accepted; a registration claiming a pre-populated
   alias with a different key is rejected. Use this for public
   relays where alias squatting is a concern.
3. **Lost-key escape hatch** (operator-only): an operator can
   delete an `(alias, identity_pk)` binding from the server-side
   registry with a CLI command (`c2c relay admin unbind <alias>`),
   authorized by the operator token from Layer 2. The next legitimate
   registration claims the alias with a fresh key. Audit-logged.

**Deferred to v2:**
- Referral chains (`Alice signs "Bob's new key is OK"`).
- Fully decentralized identity (no relay ground truth) — requires a
  gossip/consensus layer out of scope for v1.

---

## 11. Backward compatibility

Layer 3 is a wire-format break. Strategy:

1. Bump relay protocol version: current `X-C2C-Relay-Version: 1`
   → `2` on any endpoint that expects auth. Layer-1 clients get a
   clear `426 Upgrade Required` with a hint to upgrade the binary.
2. Registry on disk gains the new columns but old rows remain
   readable (missing `identity_pk` means legacy; §6 migration).
3. Old CLI binaries can still do read-only operations (e.g.
   `c2c relay status`) against a v2 relay by using the operator
   token; write operations require identity.
4. The `c2c relay` subcommands gain an `identity` subgroup without
   breaking existing flags.

No `c2c` change is required for agents that only use local IPC
(broker-only, no relay configured).

---

## 12. Test plan

All tests live under `tests/test_c2c_relay_identity_*.py`.

1. **Unit**: keypair generate → serialize → deserialize → sign →
   verify round trip.
2. **Contract**: register, then every peer endpoint with a valid
   signature passes; every peer endpoint with:
   - missing Authorization → 401
   - wrong key signature → 401
   - valid sig but stale timestamp → 401
   - valid sig but replayed nonce → 401
   - valid sig but body sha mismatch → 401
3. **Rotation**: happy path, old-sig-missing, old-sig-invalid, new
   key already in use.
4. **Collision**: two concurrent registrations of same alias with
   different pk → exactly one wins, the other gets 409.
5. **Migration**: pre-L3 registry file → upgraded relay reads it,
   legacy entries marked, accept first claim.
6. **Permissions**: identity.json mode 0644 → CLI refuses to load.

---

## 13. Open questions for review

1. **Token vs per-request signing default**: should v1 default to
   session tokens (faster, bearer risk) or always-sign (strict,
   more crypto per request)? Recommend always-sign as the default
   and tokens opt-in; revisit on benchmarks.
2. **OCaml crypto lib (tentatively resolved)**: recommend
   `mirage-crypto-ec` since it reuses the TLS dep from Layer 2. Keep
   `hacl-star` as fallback if build/link issues emerge. Needs a
   spike commit to confirm before implementation begins.
3. **Nonce storage**: in-memory LRU fine for v1 single-instance
   relay. When we scale to replicated relays we need a shared
   store (Redis? SQLite with a retention job?). Scope for v1.5.
4. **Fingerprint display format**: mimic ssh (`SHA256:...`) or adopt
   age-style `age1...`? SSH-style keeps it grep-able in logs;
   recommend ssh-style for consistency with operator familiarity.
5. **Rotation grace**: when a rotation succeeds, should outstanding
   session tokens be revoked instantly or allowed to expire (<= 1h)?
   Instant revocation is safer; forces a re-register. Recommend
   instant revocation.
6. **Hostname binding in `c2c/v1/register`**: I've included
   `relay_url` (normalized) — should this also include the server's
   TLS cert fingerprint so a rogue relay that presents a forged cert
   can't replay a client registration? Possibly overkill given
   Layer 2 already verifies the cert. Flagging for security review.

---

## 14. Interaction with later layers

- **Layer 4 (rooms)**: room send envelopes are signed with the same
  key. The `c2c/v1/room-invite` context is reserved here; Layer 4
  spec should define invitation format.
- **Layer 5 (E2E crypto upgrade)**: the Ed25519 long-term key
  becomes the **Identity Key (IK)** in the X3DH handshake. Prekeys
  are uploaded separately, signed by IK. The public key format and
  fingerprint scheme stays identical across v1 → v2, so users
  never see their fingerprint change on upgrade — a UX win.

---

## Changelog

- 2026-04-21 planner1 — initial draft (§1–§14). Written as Layer 3
  of `relay-internet-build-plan.md`. Flags 6 open questions for
  coordinator1 / security review before implementation starts.
- 2026-04-21 planner1 — OCaml-first steering from Max (via
  coordinator1, 00:20Z): flipped §1 primitives table (OCaml primary,
  Python test-only), recommended `mirage-crypto-ec`, switched §8
  subcommand to native OCaml (no Python shell-out), resolved open
  question #2 to a recommendation.
