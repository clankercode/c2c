# c2c relay PoW — canonical wire format (v1)

**Status**: implementation spec. Pairs with the motivation/plan doc
[`2026-06-11-relay-adaptive-pow-difficulty.md`](./2026-06-11-relay-adaptive-pow-difficulty.md).
This doc nails the byte-level contract so the OCaml relay (`ocaml/pow.ml`,
`ocaml/pow_policy.ml`), the Python parity scaffold (`c2c_relay_server.py`), and
the future `c2c` client all agree. **Scheme id: `sha256-leading-zeros-v1`.**

The PoW is **independent of and composes with** the existing per-request
Ed25519 signature: the signature proves *who*, the PoW proves *work done*.

---

## 1. Challenge string

```
SEP   = 0x1f                       (ASCII unit separator, one byte)
ctx   = "c2c/v1/pow"               (fixed)

challenge_string =
    ctx  SEP  route  SEP  actor_id  SEP  decimal(epoch)  SEP  server_nonce
```

- **`route`** — the costed operation, lowercase: `"register"`, `"send"`,
  `"send_all"`, `"room_send"`. (Free routes — `poll`, `peek`, `heartbeat` — are
  never challenged, so they have no challenge string.)
- **`actor_id`** — the requesting Ed25519 identity public key, in the **same
  textual encoding the codebase already uses** for identity public keys (e.g.
  `ed25519:<b64>` / hex — match `relay_identity.ml`). Binds the work to one
  actor so PoW can't be farmed across identities.
- **`epoch`** — server-issued integer, rendered as its decimal ASCII string
  (no padding). Rotates on the relay's clock; bounds precompute.
- **`server_nonce`** — server-issued random string (opaque to the client),
  echoed back verbatim. Ties the work to a recent server challenge.

All fields are concatenated as raw bytes with the single `SEP` byte between
them. No length prefixes, no trailing separator, no JSON.

## 2. Difficulty & verification

```
hash_input  = challenge_string  SEP  pow_nonce
digest      = SHA256(hash_input)            (32 raw bytes)
work        = leading_zero_bits(digest)
verify      = (work >= required_difficulty D)
```

- **`pow_nonce`** — client-chosen string. Canonical minting uses the decimal
  ASCII of an incrementing counter (`"0"`, `"1"`, `"2"`, …), but any string the
  client sends is acceptable to the verifier — only the resulting hash matters.
- **`leading_zero_bits`** — count zero bits from the most-significant bit of the
  first byte onward, stopping at the first set bit. A fully-zero byte
  contributes 8.
- **`D = 0` ALWAYS verifies true**, including with an empty `pow_nonce`. This is
  what makes the flag-off / grace-band path free and backward compatible.
- Verification is **one** SHA256; minting costs ~`2^D` hashes — the asymmetry.

## 3. Request body fields

Costed requests carry three extra fields alongside the existing Ed25519 proof:

| field             | type   | meaning                                  |
|-------------------|--------|------------------------------------------|
| `pow_nonce`       | string | the mined nonce                          |
| `pow_epoch`       | int    | the `epoch` the client minted against    |
| `pow_server_nonce`| string | the `server_nonce` the client minted against |

The server reconstructs `challenge_string` from `(route, actor_id, pow_epoch,
pow_server_nonce)` and verifies against the difficulty it currently requires for
that actor. A stale/unknown `(epoch, server_nonce)` is treated as insufficient
PoW → `pow_required` (§5) with a fresh challenge.

## 4. Advertisement header (proactive)

Every relay response includes the difficulty the actor must satisfy on its
**next** costed request:

```
X-C2C-PoW-Next: difficulty=<D>; epoch=<e>; server_nonce=<n>; ttl=<s>
```

- `ttl` is seconds until `(epoch, server_nonce)` expire.
- A well-behaved client reads this and pre-mints before sending its next costed
  request, avoiding the reject round-trip.
- When the feature is disabled or the actor is in the grace band, the relay
  still emits the header with `difficulty=0` so clients can detect support.

## 5. Challenge-on-reject (reactive)

A costed request that arrives with missing/insufficient PoW is rejected with a
structured error mirroring the relay's existing `error_code` payload shape
(`alias_conflict`, nonce reuse, …):

```json
{ "ok": false,
  "error_code": "pow_required",
  "required": {
    "difficulty": 12,
    "epoch": 1000,
    "server_nonce": "srvnonce1",
    "ctx": "c2c/v1/pow",
    "ttl_s": 120
  } }
```

The client mints `pow_nonce` from this payload and retries the **same** request
with the three body fields populated.

## 6. Capability discovery (`/health`)

```json
"pow": { "enabled": true, "scheme": "sha256-leading-zeros-v1" }
```

Lets older clients/relays degrade gracefully and lets us stage rollout. When
`C2C_RELAY_POW` is unset/`0`, `enabled` is `false`.

## 7. Policy — cost → difficulty

Constants live in **one** canonical place per implementation (`pow_policy.ml`
/ the `c2c_relay_server.py` policy block):

```
cost weights:   register = 10
                send / send_all / room_send = 1
                poll / peek / heartbeat = 0     (never challenged)

per-actor accumulated cost C = decayed sliding-window sum (WINDOW = 600s)

required_difficulty(C):
    if C <= GRACE        -> 0
    else                 -> STEP * ceil((C - GRACE) / BUCKET), capped at D_MAX

straw constants:  GRACE = 20   BUCKET = 10   STEP = 4 (bits)   D_MAX = 24
```

Decay returns a quiet actor to the grace band, so a legitimate burst is cheap
and only *sustained* high-rate flows pay escalating cost. Heartbeats (cost 0)
never push difficulty — long-lived well-behaved connectors are not punished.

## 8. Feature flag — `C2C_RELAY_POW`

| value          | behaviour                                                       |
|----------------|-----------------------------------------------------------------|
| unset / `0`    | **default.** `enabled=false`; difficulty always 0; no enforcement; every existing client keeps working. Header still emitted with `difficulty=0`. |
| `1`            | enforce §2–§7: challenge insufficient-PoW costed requests, advertise next difficulty. |

Rollout sequencing: deploy relay flag-OFF (backward compatible) → install
updated client that can mint + retry → restart connector → **then** flip
`C2C_RELAY_POW=1`. Never flip before clients can mint, or every register breaks.

## 9. Test vectors

`SEP` = `0x1f`. `actor_id`/`server_nonce` are illustrative. These are real
SHA256 results an implementation MUST reproduce.

**Vector 1 — register, challenge bytes**

```
challenge_string (python repr):
  'c2c/v1/pow\x1fregister\x1fed25519:AAAA\x1f1000\x1fsrvnonce1'
pow_nonce = "411"
SHA256(challenge_string + 0x1f + "411") = 000c8d91eb6a...   (12 leading zero bits)
=> satisfies D=8 and D=12; fails D=13.
```

**Vector 2 — send, low difficulty**

```
challenge_string = "c2c/v1/pow"|"send"|"ed25519:BBBB"|"2000"|"srvnonceX"  (| = 0x1f)
pow_nonce = "2"
SHA256(... + 0x1f + "2") = 0473aa549c41...   (5 leading zero bits)
=> satisfies D=4; fails D=6.
```

**Vector 3 — difficulty 0**

```
Any challenge_string, pow_nonce = "" (empty), D = 0  => verify == true.
```

---

— spec for the PoW slice, 2026-06-11. Implemented by `ocaml/pow.ml` +
`ocaml/pow_policy.ml` (canonical) with Python parity in `c2c_relay_server.py`.
