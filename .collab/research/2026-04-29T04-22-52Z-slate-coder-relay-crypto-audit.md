# Relay-E2E cryptographic-layer audit (HEAD ~3fefd55c)

Read-only audit, scope: `ocaml/relay_enc.ml` (X25519 keypair + on-disk
`enc_identity.json`), `ocaml/relay_e2e.ml` (envelope encrypt/decrypt +
sig verify + downgrade tracking + pin-check helpers), and the
`c2c_mcp.ml` integration sites (`decrypt_message_for_push` ~line 4102,
the inline `poll_inbox` decrypt path ~line 5687, the `send` encrypt
path ~line 5258). Out of scope: `peer-pass-trust.json` pin layer
(stanza TOFU 4/5), `relay_pins.json` flock semantics (Slice E).

Severity tags: **CRIT / HIGH / MED / LOW / NIT / OK** (per
`.collab/research/2026-04-29-stanza-coder-tofu-pin-audit.md`).

---

## TL;DR — the three biggest wrinkles

1. **CRIT-1**: `from_x25519` (the sender's claimed X25519 pubkey, used
   by the receiver to decrypt) is **NOT covered by the Ed25519
   signature**. A relay-side attacker who knows the sender's Ed25519
   identity pin can rewrite `from_x25519` to a key they hold the
   secret for, and the receiver will: (a) decrypt successfully against
   the rewritten key, (b) sig-verify successfully because `from_x25519`
   isn't in `canonical_json`, (c) auto-pin the attacker's X25519 via
   `pin_x25519_sync` after a successful sig check. After that, every
   subsequent X25519 message from this sender is decrypted under
   attacker-chosen ECDH (or just dropped, depending on the attacker's
   goal). See §1.
2. **CRIT-2**: When `Broker.get_pinned_ed25519 env.from_` returns
   `None` (no pin yet — first contact), the receive paths classify the
   message as `Failed` / "no pin" and return ciphertext to the user.
   There is **no Ed25519 TOFU on first-seen** — meaning legitimate
   first-contact encrypted DMs are unreadable until somebody
   out-of-band pins the sender's Ed25519. Compounding: there is no
   surface today (no `pin_ed25519_first_seen` for relay-e2e) for the
   user to rectify this except by sending in the reverse direction
   first (which auto-pins the *recipient's* x25519 of the sender, but
   not the sender's Ed25519). The peer-PASS layer has TOFU; this layer
   does not. See §3.
3. **CRIT-3**: The outer `from_alias` (set by the broker's
   `enqueue_message` from the verified MCP-session sender) is never
   compared with `env.from_` (the inner envelope's claimed sender)
   before pin lookup or sig verify. A locally-registered peer A can
   send a message whose outer wrapper says `from_alias=A` (correct)
   but whose envelope says `from_=B` (spoofed). The receiver does
   `Broker.get_pinned_ed25519 env.from_` (= B's pin), `verify_envelope_sig`
   passes if the attacker holds B's signing key… but the attacker
   doesn't, so verify fails → recipient sees ciphertext, not a
   plaintext spoof. So this is **HIGH not CRIT**: the attacker cannot
   exfiltrate plaintext under B's identity, but can cause a spurious
   `enc_status:failed` and pin-state confusion (the downgrade-state
   table is keyed on `env.from_`, attacker-chosen). See §6.

---

## Findings

### 1. CRIT — `from_x25519` is outside the signed canonical-JSON

**File**: `ocaml/relay_e2e.ml:79-102` (`canonical_json`),
`ocaml/relay_e2e.ml:204-214` (`envelope_to_json`),
`ocaml/relay_e2e.ml:216-230` (`envelope_of_json`).

The `envelope` record carries `from_x25519 : string option` (the
sender's X25519 pubkey, b64url). It is serialized into and parsed
from the wire JSON, BUT the canonical JSON used as the signature
input does NOT include it:

```ocaml
(* relay_e2e.ml:92-101 *)
let fields =
  sort_assoc [
    "from",      `String e.from_;
    "to",        ...
    "room",      ...
    "ts",        `Intlit (Int64.to_string e.ts);
    "enc",       `String e.enc;
    "recipients", rncs;
  ]
```

The Ed25519 signature is over those six fields only. `from_x25519`
is not on the list.

**Why this matters in the receive path** (`c2c_mcp.ml:4130-4154`,
mirrored at `c2c_mcp.ml:5712-5740`):

```ocaml
let sender_x25519_pk = env.from_x25519 in
match Relay_e2e.decrypt_for_me
  ~ct_b64:recipient.ciphertext
  ~nonce_b64
  ~sender_pk_b64:(match sender_x25519_pk with Some pk -> pk | None -> "")
  ~our_sk_seed:x25519.private_key_seed with
| ...
| Some pt ->
  let sender_ed25519_pk_opt = Broker.get_pinned_ed25519 env.from_ in
  (match sender_ed25519_pk_opt with
   | None -> content
   | Some pk ->
     let sig_ok = Relay_e2e.verify_envelope_sig ~pk env in
     if not sig_ok then content
     else (
       (match sender_x25519_pk with
        | Some pk -> Broker.pin_x25519_sync ~alias:env.from_ ~pk |> ignore
        | None -> ());
       pt))
```

The X25519 pubkey used for ECDH is taken from the (unsigned)
envelope field. After successful verification (which only checks
the *six signed* fields), `pin_x25519_sync` auto-pins whatever
`env.from_x25519` was. An adversary who can intercept and rewrite
the envelope on the wire (any relay or man-in-the-middle who has
access to the broker dir before drain, OR who controls the relay)
can:

- Replace `env.from_x25519` with attacker's X25519 pubkey `K_attacker`.
- Replace `recipients[i].ciphertext` and `recipients[i].nonce`
  with a freshly-encrypted box using `K_attacker`'s ECDH with the
  recipient.
- Leave `from_`, `to_`, `room`, `ts`, `enc` alone.
- Sig still valid because the signature didn't cover the changed
  fields. (Wait — the recipients list IS in the canonical JSON, so
  changing ciphertext + nonce DOES invalidate the sig. Re-checking:)

Re-checking carefully — `recipients` IS in canonical_json (line 99).
So an attacker rewriting ciphertext invalidates the sig. **The
attack only works if recipients are unchanged.**

So the attack reduces to: "what can attacker do by rewriting only
`from_x25519` while leaving recipients (ciphertext + nonce + alias)
intact?" Answer: nothing on recipient #1's plaintext (they decrypt
with the original sender's X25519). But:

- `decrypt_for_me` uses `sender_pk_b64 = env.from_x25519`. If the
  attacker rewrites `from_x25519` to a wrong key, `decrypt_for_me`
  fails (NaCl box auth tag mismatch), the receive path returns
  `Failed`. Sig verify never runs because we early-out on decrypt
  None at line 4136.
- `pin_x25519_sync` is only called *after* a successful decrypt + sig
  check, and it pins what's currently in `env.from_x25519`. Since
  decrypt only succeeds when `from_x25519` matches the ECDH-secret
  used to encrypt, this pin is at-worst-defective only if the
  signed fields' integrity covers the binding. But again,
  `from_x25519` is not signed.

**Reduced attack**: at the moment of legitimate first contact
(no x25519 pin yet, sender sends correctly-encrypted box with their
correct from_x25519), an attacker who controls the broker dir can
**replace** the envelope JSON entirely with one signed by themselves
under a *fresh* key claiming `from_=<victim>`. Sig verify will fail
because the legitimate sender's Ed25519 pin doesn't match the attacker's
fresh signing key — UNLESS no Ed25519 pin exists yet (CRIT-2 below).

**Net of this finding alone (assuming Ed25519 already pinned)**:
`from_x25519` not being in the signature is a **layering defect**, not
an exploitable break. But it costs the system the property "the X25519
pubkey used for ECDH is sender-attested" — so any future wrinkle that
relaxes the Ed25519-must-be-pinned-first invariant immediately becomes
a key-substitution attack.

**Severity**: **CRIT** as documented invariant ("the binding between
sender alias and X25519 key is signed"); **HIGH** as currently exploited
threat (Ed25519-pin-precondition narrows the window). Either way, fix:
add `"from_x25519"` to the canonical-JSON field list, with `null`
sentinel for legacy envelopes (don't change the type).

**Compounding wrinkle**: `relay_e2e.ml:262-263` —
`make_test_envelope` initializes `from_x25519 = None`, so a test
envelope going through `set_sig` then `verify_envelope_sig` will
verify even if production code never sets `from_x25519` at all. If
canonical_json is later fixed to include `from_x25519`, all
make_test_envelope-based test fixtures continue to verify. This is
fine, but worth flagging: tests can pass with a broken sender-binding.

---

### 2. CRIT — No Ed25519 TOFU for relay-e2e first-contact

**File**: `c2c_mcp.ml:4144-4146` and `c2c_mcp.ml:5728-5731`.

```ocaml
let sender_ed25519_pk_opt = Broker.get_pinned_ed25519 env.from_ in
(match sender_ed25519_pk_opt with
 | None ->
   content, Some (Relay_e2e.enc_status_to_string Relay_e2e.Failed)
 | Some pk ->
   let sig_ok = Relay_e2e.verify_envelope_sig ~pk env in
   ...)
```

The pin lookup happens AFTER successful decrypt. If no pin exists
(first contact), the path returns ciphertext + `enc_status:failed`.
**The envelope contains no `from_ed25519` field**, so there's no
candidate Ed25519 pubkey to pin even on first-seen. Compare with the
X25519 leg, which auto-pins via `pin_x25519_sync` post-verify — that
works precisely because the X25519 pubkey is on the wire (in
`env.from_x25519`) and decryption proves the sender holds the
matching secret.

For Ed25519 there's no equivalent. The wire envelope has the
signature (`sig` field, b64) but not the public key. A receiver with
no pin can't verify, so messages drop to `Failed`.

**Effect**:
- First-contact encrypted DM from peer A to peer B: B's broker has
  no Ed25519 pin for A. Decrypt succeeds (X25519 ECDH against
  `env.from_x25519`), but sig verify is unreachable. User sees
  raw envelope JSON with `enc_status:failed`. **Message lost in
  practice.**
- Workaround: B sends to A first. The send path in
  `c2c_mcp.ml:5301-5303` calls `pin_ed25519_sync ~alias:from_alias
  ~pk:our_ed_pubkey_b64` — but that pins B's *own* Ed25519 (under
  alias B), not A's. So the workaround does NOT recover.
- Real workaround: requires out-of-band Ed25519 pin priming. There is
  no MCP/CLI surface for that today on the relay-e2e layer (peer-PASS
  has `c2c trust --repin <alias>` and the artifact-embeds-pubkey
  pattern, but neither feeds `Broker.set_pinned_ed25519`).

**Severity**: **CRIT** — first-contact encrypted DMs to relay-e2e
peers are unreadable without out-of-band intervention.

**Suggested fix family** (do NOT implement here; just naming options):
1. Add `from_ed25519 : string option` to the envelope, treat
   first-seen-wins (TOFU) on the broker's `known_keys_ed25519` —
   sign-it-into-the-canonical to bind alias↔pubkey, mirroring the
   X25519 fix in §1.
2. Or: require Ed25519 pin priming before any decrypt; emit a
   distinct `enc_status:no-sender-pin` so the user can see the
   failure mode and act.

Today's `Failed` enc_status does not distinguish "sig invalid"
from "no pin to verify against" — that's a usability defect on top
of the security one.

---

### 3. HIGH — `env.from_` is the trust anchor; outer `from_alias` is not cross-checked

**Files**: `c2c_mcp.ml:4113-4115`, `c2c_mcp.ml:5695-5697`, all
`Broker.get_pinned_*` calls, all `Broker.set_downgrade_state` calls.

The receive path keys *every* trust decision on `env.from_`:
- `Broker.get_downgrade_state env.from_` — keys downgrade-state hashtbl.
- `Broker.set_downgrade_state env.from_ ds` — writes to that hashtbl.
- `Broker.get_pinned_x25519 env.from_` — looks up X25519 pin.
- `Broker.get_pinned_ed25519 env.from_` — looks up Ed25519 pin.
- `Broker.pin_x25519_sync ~alias:env.from_` — auto-pins under env.from_.

Meanwhile the outer `to_alias` is the trusted recipient (broker
delivered to this inbox), and the outer `from_alias` (the
broker-verified sender of the queue entry, set by `enqueue_message`
at `c2c_mcp.ml:2054`) is **never compared** with `env.from_`.

**Effect**: a registered peer A can send an inner envelope claiming
`from_=B`. The outer wrapper truthfully says `from_alias=A`. The
receiver:
- Pulls `env.from_=B`.
- Looks up `pinned_ed25519` for B — finds B's real pin.
- A doesn't hold B's Ed25519 secret, so sig verify fails.
- Receiver sees `enc_status:failed`.

But:
- `set_downgrade_state env.from_=B` writes to slot keyed on B. So
  A can pollute B's downgrade-state table — set `seen_encrypted=true`
  for B even though A is the actual sender. Future genuine plain
  messages from B then get marked `downgrade-warning`. (DoS-flavored,
  not exfiltration.)
- The X25519 pin auto-pins on `env.from_=B`. If no pin exists for B
  yet AND A controls a valid (sig-verifying) envelope chain claiming
  `from_=B`… the only way to get a sig-verifying envelope claiming
  from_=B is to hold B's Ed25519 secret. So §3 isn't a key-substitution
  unless §1 or §2 weakens the precondition.

**Severity**: **HIGH** — the missing cross-check is a defense-in-depth
gap that becomes more important as soon as either §1 or §2 lands a
mitigation. The fix is small: assert `env.from_ = msg.from_alias` (or
both casefolded) before pin lookups; reject as `Failed` if mismatched.

**Caveat**: `from_alias` for relay-forwarded messages is set by the
relay outbox, not by a local `enqueue_message` — so a remote peer's
outer `from_alias` is broker-attested only as far as the relay attests
it. Across a relay hop the inner-envelope sig is the only ground
truth, so the cross-check has to happen at the relay boundary too.
This audit only sees the local broker; the relay-side codepath is
worth a follow-up audit.

---

### 4. MED — `decide_enc_status` is per-process and not flock-protected

**File**: `c2c_mcp.ml:972` (decl) + `c2c_mcp.ml:1097-1101` (accessors).

`downgrade_states` is a plain `Hashtbl.t`, mutated under no lock.
`get_downgrade_state` returns a fresh `make_downgrade_state` if the
key is absent. `set_downgrade_state` is bare `Hashtbl.replace`. There
is no flock and no lwt-mutex around it.

**Consequence**:
- Across concurrent `poll_inbox` and `decrypt_message_for_push`
  invocations on the same broker process, the table can race —
  Hashtbl is not concurrent-safe in OCaml. With Lwt this isn't fatal
  (single-threaded scheduler) but the moment something runs in a
  Domain or Lwt_preemptive worker, this is UB.
- Per-process means downgrade-state is reset on broker restart. An
  attacker who can trigger a broker restart (or wait for one — they
  happen on every `c2c restart <name>` and on every binary upgrade)
  re-opens the "first plain message after first encrypted" window.
  Effect: a single plain message inserted right after restart is
  classified as `Plain`, not `Downgrade_warning`. Successful
  attacker → user reads "plain" thinking it was always plain.
- In multi-broker (cross-process) scenarios — e.g. the `poll_inbox`
  inside the MCP server process AND a separate `c2c history` CLI
  reading the same archive — neither shares the in-memory table.

**Severity**: **MED**. Downgrade detection is a UX signal, not a
hard guarantee, but the docstring at `relay_e2e.ml:235-249` doesn't
flag the "transient, per-process, restart-clears" nature. Slice E
moved relay_pins to disk; the same case can be made for
downgrade-state, especially because §10 of the SPEC frames downgrade
detection as a *security* feature.

**Fix family**: persist downgrade-state to a sibling file under the
same flock as relay_pins.json, OR document loudly in the enc_status
comment that downgrade-detection is a best-effort signal that resets
on broker restart. Today's silence is the worst of both worlds.

---

### 5. MED — `Hacl_star.Hacl.NaCl.box` is XSalsa20-Poly1305; nonce reuse risk on RNG-failure

**File**: `relay_e2e.ml:51-53` (`random_nonce`), `relay_e2e.ml:165-173`
(`encrypt_for_recipient`).

The primitive is NaCl `crypto_box` (XSalsa20-Poly1305 with X25519 key
agreement; 24-byte nonce, large enough that random nonces are safe
under birthday bound for any realistic message volume). The OCaml
binding is via `hacl_star`, which is a maintained Hacl* binding —
formally verified for the underlying primitives.

Nonce generation: `Mirage_crypto_rng.generate 24`. RNG init via
`Mirage_crypto_rng_unix.use_default ()` happens lazily on first
encrypt/decrypt (`relay_e2e.ml:43-49`). Default uses Linux
`getrandom(2)` (or `/dev/urandom` fallback). Should be fine.

**Wrinkle**: `ensure_rng` is per-module (separate flag in
`relay_enc.ml:31-37` and `relay_e2e.ml:43-49`). Both call
`Mirage_crypto_rng_unix.use_default ()`. Mirage_crypto_rng uses a
global pool, so the duplication isn't a correctness bug, just dead
state. NIT.

**Real risk**: 24-byte nonces from `getrandom(2)` are safe. However,
the encrypt path generates a *fresh* nonce per recipient per message
(`encrypt_for_recipient` at line 166), so a multi-recipient
broadcast (when room broadcasts get e2e — currently they don't, see
§7) would have N nonces. No nonce reuse risk under correct RNG.

A per-key nonce-reuse failure (catastrophic for XSalsa20-Poly1305 —
gives the attacker a forged message under the same key) requires
either RNG failure or a code bug that reuses a nonce. Neither
present today. **OK** with the asterisk that the same NaCl primitive
in JS/TS clients (planned cross-client compat) needs the same RNG
discipline; an audit of TS-side once it lands will be needed.

---

### 6. MED — Envelope deserialization raises rather than returns Result

**File**: `relay_e2e.ml:216-230` (`envelope_of_json`).

```ocaml
let envelope_of_json (j : Yojson.Safe.t) : envelope =
  match j with
  | `Assoc _ ->
    let open Yojson.Safe.Util in
    let from_ = member "from" j |> to_string in
    ...
    let ts_str = member "ts" j |> to_string in
    let ts = Int64.of_string ts_str in
    ...
  | _ -> failwith "envelope_of_json: expected object"
```

Failure modes that raise (not return):
- `member "<missing>" j |> to_string` raises `Type_error` if absent or
  wrong type.
- `Int64.of_string ts_str` raises `Failure "int_of_string"` on garbage.
- `recipient_of_json` raises on malformed members.
- `Int64.of_string` doesn't validate range — only "is parseable".

The callers wrap with `match ... with | exception _ -> content, None`
(line 5693) or `| exception _ -> content` (line 4111), so production
doesn't crash on a malformed envelope — but every malformed envelope
takes the *plaintext* branch (returns content untouched + None
enc_status). That's actually correct fail-safe (no plaintext leak,
no crash), but it conflates "this was never an e2e envelope" with
"this was a malformed e2e envelope from a real attacker".

**Effect**:
- An attacker who can inject malformed envelopes into the broker can
  cause receivers to silently treat them as plaintext, with no
  enc_status to surface the parse failure. Receivers will see the raw
  JSON-looking content as their message body. Surface-level: ugly,
  not security-critical (no decryption oracle).
- One concrete pothole: `int_of_string` on the `ts` field accepts
  many representations OCaml does ("0x10", leading 0, etc.) that JSON
  doesn't normally produce. Good enough but slightly loose.

**Severity**: **MED** — recommend `envelope_of_json : Yojson.Safe.t
-> (envelope, string) result` to match `relay_enc.ml`'s
`of_json` shape. The exception-based path is a footgun for new
callers and the `exception _ ->` catch-all hides the distinction
between "not an envelope" and "malformed envelope".

**Field-shape validation**:
- No length check on `from_x25519` (should be 32 bytes after b64url).
  A 17-byte `from_x25519` decodes fine but `decrypt_for_me` will
  reject it inside Hacl. Surfaces as `Failed`. OK.
- No length check on `recipients[i].nonce` (should be 24 bytes after
  b64url). Same as above — Hacl rejects. OK.
- No length check on `recipients[i].ciphertext` (must be ≥16 bytes
  for the Poly1305 tag). Hacl rejects. OK.
- No length check on `sig_b64` (must be 64 bytes after b64url).
  `verify_ed25519` checks at line 110: `String.length sig_ = 64 …`
  before invoking the verify primitive. OK.
- No bound on number of `recipients`. A million-recipient envelope
  would allocate proportionally on the receiver. Unbounded — the
  inbox-write surface and broker should already be the choke point,
  but worth a NIT note.

---

### 7. LOW — `room` field accepted but no room-encryption codepath exists

**File**: `relay_e2e.ml:26-35` (envelope record), all room references
in canonical_json.

The envelope schema has `room : string option`. The send path at
`c2c_mcp.ml:5314-5325` always sets `room = None` for 1:1 sends. Room
broadcasts in `Broker.fan_out_room_message` (per CLAUDE.md grep:
hardcodes deferrable=false; no e2e wrap).

So `room` is in the spec but unused. A receiver who handles
`env.room = Some "X"` has no special branch — it's treated as 1:1.
Today this is benign; once room-e2e lands, ensure the recipient list
matches the room membership at the broker's view of the room (else a
peer can craft a "room broadcast" with curated recipients to mimic a
private DM as a room message in the recipient's UI).

**Severity**: **LOW** — flag for the slice that adds room-e2e.
Document explicitly that no room-e2e wire format is wired today.

---

### 8. LOW — Permissions check only on load, not on save

**File**: `relay_enc.ml:134-141` (`load`).

```ocaml
let st = Unix.stat path in
let perm = st.Unix.st_perm land 0o777 in
if perm land 0o077 <> 0 then
  Error "permissions too permissive on %s: %o (expected 0600)" ...
```

`save` at `relay_enc.ml:111-127` writes with `0o600` and chmods to
`0o600` after rename — correct. But `load` will refuse to read a key
file with permissions wider than 0o600 (mirrors ssh's behavior on
`id_ed25519`). Good.

**Wrinkle**: there is no equivalent permission guard on the parent
directory. The directory is created with `0o700` if missing, and a
chmod 0o700 is attempted on every save (`relay_enc.ml:114-115`). But
if the directory already exists with looser perms (e.g. 0o755), the
chmod is silent-best-effort (`with Unix.Unix_error _ -> ()`). A
preexisting permissive parent dir means another local user can list
files in `~/.config/c2c/keys/`, learning *which* aliases have keys
(privacy leak, not a key compromise — file 0o600 still applies).

**Severity**: **LOW**. Recommend: refuse to save if parent dir is
group/other-readable, parallel to the load-side check.

**Related**: `relay_identity.ml` (out of scope but adjacent) has a
similar pattern for `identity.json` — same comment applies.

---

### 9. LOW — `verify_envelope_sig` short-circuit semantics on b64 decode failure

**File**: `relay_e2e.ml:158-163`.

```ocaml
let verify_envelope_sig ~pk (e : envelope) : bool =
  match b64_decode e.sig_b64 with
  | Error _ -> false
  | Ok sig_bytes ->
    let canon = canonical_json e in
    verify_ed25519 ~pk ~msg:canon ~sig_:sig_bytes
```

Returns `false` on b64 decode failure of `sig_b64`. Good. The
`verify_ed25519` helper (line 109-114) also returns `false` on
malformed `pk` (≠ 32 bytes) or malformed `sig_` (≠ 64 bytes). Good.

**Wrinkle**: there's no logging on verify failure. The caller
classifies as `Failed` or `Key_changed` and silently moves on. This
is by-design fail-closed but means an under-attack receiver has no
local trace beyond the `enc_status:key-changed` field in the
returned message JSON. The peer-PASS layer added a broker.log audit
for `pin_rotate REJECT` (Slice E TOFU 5 obs); the relay-e2e layer
has no equivalent.

**Severity**: **LOW** — observability gap. Recommend adding
`broker.log` lines for `enc_status=failed` and `enc_status=key-changed`
events with `from_alias` (outer + inner), `to_alias`, and a sentinel
that says whether the cause was "no pin" vs "sig invalid" vs "decrypt
failed" vs "key mismatch". Today the user sees `Failed` with no way
to distinguish.

---

### 10. LOW — `String.equal` on 32-byte pin compare; not constant-time

**File**: `relay_e2e.ml:256-260`.

```ocaml
let check_pinned_ed25519_mismatch ~(pinned_pk : string) ~(claimed_pk : string) : bool =
  pinned_pk <> claimed_pk

let check_pinned_x25519_mismatch ~(pinned_pk : string) ~(claimed_pk : string) : bool =
  pinned_pk <> claimed_pk
```

OCaml structural inequality on strings. Not constant-time. For a
sanity-check on a public key, this is acceptable — the values aren't
secret; the timing leak would tell an attacker "first byte differs"
which is public information. Same logic stanza applied to
`Trust_pin` audit's pin-compare. **OK**, listed for completeness.

(The same applies in line 4140's `pinned <> Some pk`: `option`
inequality on strings, not constant-time. Public values. OK.)

---

### 11. LOW — `decrypt_message_for_push` discards `enc_status`

**File**: `c2c_mcp.ml:4102-4158`.

The push-path helper used by `c2c_mcp_server_inner.emit_notification`
(line 220 of inner) destructures the message:

```ocaml
let { from_alias; to_alias; content; deferrable; reply_via; enc_status = _ } = msg in
```

It computes a new `decrypted_content` but returns
`{ msg with content = decrypted_content }` — leaving `enc_status` at
whatever the original had (or None on a fresh queue entry). It also
does NOT compute and propagate an enc_status from the decrypt
result, even though the duplicate poll_inbox path at line 5687 *does*
compute it.

**Effect**: messages delivered via channel push have no enc_status
metadata even when decryption succeeded or failed. The recipient's
client only sees enc_status if they later poll via `poll_inbox` (and
the original queue entry then gets re-decrypted with a fresh status).
A user on a channel-capable client misses the downgrade-warning
signal. This is a UX bug with security flavor: the silent-eat
hazard for downgrade messages is partially restored when push wins
the race.

**Severity**: **LOW** — fix is to mirror the poll_inbox path's
status computation in `decrypt_message_for_push` and write it into
both the message's `enc_status` field and the channel notification's
`meta` JSON. Aligning with stanza's c2c_mcp code-health audit
(`.collab/research/2026-04-29-stanza-coder-c2c-mcp-code-health.md`)
which already flags the duplicate decrypt logic between push and
poll paths.

---

### 12. NIT — `box_easy` / `box_open_easy` / `box_beforenm` / `box_afternm` are dead code

**File**: `relay_e2e.ml:116-145`.

Four helpers (`box_easy`, `box_open_easy`, `box_beforenm`,
`box_afternm`) wrap `Hacl_star.Hacl.NaCl.box`/etc. None are used
outside this module — production callers go through
`encrypt_for_recipient` and `decrypt_for_me`. The `box_beforenm`
optimization (precomputed shared key for repeated send to one
recipient) might be wanted later, but today the helpers add ~30
lines and a footgun (the API takes nonces as plain strings, no
length check).

**Severity**: **NIT**. Either wire them in (room broadcast e2e) or
delete.

---

### 13. NIT — `exception _ ->` catches kill at receive boundary

**Files**: `c2c_mcp.ml:4108`, `c2c_mcp.ml:4111`,
`c2c_mcp.ml:5690`, `c2c_mcp.ml:5693`.

```ocaml
match Yojson.Safe.from_string content with
| exception _ -> content, None
| env_json ->
  match Relay_e2e.envelope_of_json env_json with
  | exception _ -> content, None
  | env -> ...
```

Bare `exception _` catches `Sys.Break` (Ctrl-C) and `Out_of_memory`,
not just parse exceptions. Standard OCaml-best-practice nit; in a
broker process this means a Ctrl-C during decrypt processing gets
swallowed and the next message is processed. Probably benign because
the surrounding loop will be interrupted by signal handler at the
next checkpoint, but worth tightening to
`Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ | Failure _`
or whatever the parse path actually throws.

**Severity**: **NIT**.

---

### 14. NIT — `relay_enc.of_json` accepts only version=1 / alg=x25519

**File**: `relay_enc.ml:101-104`.

Strict version + alg gate. Future schema migrations need to either
extend `of_json` or live in a new module. Documented decision; just
flagging that the alias-keyed migration today (`E2E S1`,
`394ba6cb`) revs the on-disk format but not the version int — so a
v1 file with the new alias-keyed shape and a v1 file with the old
shape are indistinguishable here. If the migration introduced a
shape change that's not version-bumped, a stale v1 file will load
through `of_json` and only fail at use site.

(Out-of-scope to verify the exact diff in `394ba6cb`; flagged as
a thing to recheck against the migration design doc.)

---

## Leave-it-alone notes (working-as-intended)

- **OK**: `relay_enc.save` is tmp+rename atomic with chmod 0o600
  before rename and after, mode 0o700 on parent dir. Stronger than
  most adjacent file writers in c2c.
- **OK**: NaCl primitive choice (XSalsa20-Poly1305 + X25519) is
  standard, well-vetted; Hacl* binding is maintained.
- **OK**: Ed25519 sig over canonical JSON with sorted keys mirrors
  TS/Python clients' default JSON serialization, satisfying the
  stated cross-client byte-stability requirement (covered by
  `test_canonical_json_byte_stability` /
  `test_canonical_json_sorted`).
- **OK**: `from_alias` reserved-system check at
  `c2c_mcp.ml:2018-2020` prevents spoofing of `c2c-system` /
  `coordinator1` etc. at the local-broker enqueue boundary.
- **OK**: send path explicitly rejects mismatched x25519 pin on
  outbound (`c2c_mcp.ml:5283-5284`, `Key_changed` rejection): the
  sender refuses to encrypt to a recipient whose advertised
  `enc_pubkey` differs from the local pin. This prevents the
  inverse-direction key-substitution (sender re-encrypts to attacker
  if recipient was rotated). Correct fail-closed.
- **OK**: `verify_ed25519` (line 109-114) length-guards `pk` and
  `sig_` before invoking the primitive. Defends against giving the
  raw OCaml binding a malformed input.
- **OK**: `Relay_enc.load_or_generate` only regenerates on ENOENT
  prefix-match (line 168). Permissions errors / corruption return
  the error rather than silent-overwrite (the lesson learned from
  the `a7496870` → `394ba6cb` "junk-key persist" bug).

---

## Summary table

| # | Severity | Finding | File:line |
|---|---|---|---|
| 1 | **CRIT** (latent) | `from_x25519` not in signed canonical_json | `relay_e2e.ml:79-102` |
| 2 | **CRIT** | No Ed25519 TOFU on first contact; first-msg drops as Failed | `c2c_mcp.ml:4144-4146`, `5728-5731` |
| 3 | **HIGH** | `env.from_` is the trust anchor; outer `from_alias` not cross-checked | `c2c_mcp.ml:4113-4115`, `5695-5697` |
| 4 | **MED** | `downgrade_states` table is per-process, not flock-protected, restart-clears | `c2c_mcp.ml:972-1101` |
| 5 | **MED** | `envelope_of_json` raises rather than returns Result; loose ts parse | `relay_e2e.ml:216-230` |
| 6 | **LOW** | `room` field on envelope schema but no room-e2e codepath wired | `relay_e2e.ml:26-35` |
| 7 | **LOW** | `relay_enc.save` doesn't refuse a parent dir with looser perms | `relay_enc.ml:111-127` |
| 8 | **LOW** | No verify-failure / decrypt-failure logging in broker.log | `relay_e2e.ml:158-163`, all decrypt sites |
| 9 | **LOW** | Pin-mismatch compare not constant-time (acceptable; public values) | `relay_e2e.ml:256-260` |
| 10 | **LOW** | `decrypt_message_for_push` doesn't propagate `enc_status` to channel push | `c2c_mcp.ml:4102-4158` |
| 11 | **NIT** | `box_easy`/`box_open_easy`/`box_beforenm`/`box_afternm` dead | `relay_e2e.ml:116-145` |
| 12 | **NIT** | Bare `exception _` at receive boundary catches Sys.Break | `c2c_mcp.ml:4108`, `4111`, `5690`, `5693` |
| 13 | **NIT** | `relay_enc.of_json` versioning brittle vs. shape migration | `relay_enc.ml:101-104` |
| 14 | **NIT** | `random_nonce` / `ensure_rng` duplicated in relay_enc + relay_e2e | `relay_enc.ml:31-37`, `relay_e2e.ml:43-49` |

---

## Top recommendations (ranked)

1. **Fix CRIT-1**: include `from_x25519` (and ideally a new
   `from_ed25519`) in `canonical_json`. Use `null` for legacy
   absent-field envelopes so existing signed envelopes keep verifying.
   Coordinate with TS/Python clients on the bit shape before flipping.
2. **Fix CRIT-2**: surface a distinct `enc_status:no-sender-pin`
   (or `pending-trust`) instead of `Failed` when
   `Broker.get_pinned_ed25519` returns None, AND add a
   `from_ed25519` field to envelopes so first-seen TOFU is even
   possible.
3. **Fix HIGH §3**: assert (case-folded) `env.from_ = msg.from_alias`
   before pin lookup; reject as `Failed` (or new `From_mismatch`
   status) on miscompare.
4. **Address MED §4**: either persist `downgrade_states` to disk or
   loud-document that downgrade-detection is reset on restart.
5. **Address MED §5**: convert `envelope_of_json` to Result-returning;
   pre-validate field shapes (lengths) before they reach Hacl.
6. **Address LOW §10**: have `decrypt_message_for_push` mirror the
   poll_inbox path's status computation so channel-push consumers
   see enc_status (downgrade-warning especially).
7. **Address LOW §8**: add broker.log audit lines for verify-fail and
   decrypt-fail at the relay-e2e boundary, parallel to the
   `pin_rotate REJECT` audit added in TOFU 5 obs.
8. **Address LOW §11/§12**: code-hygiene cleanup — delete dead `box_*`
   helpers OR wire them into a planned room-e2e slice; tighten the
   bare `exception _` catches.

Items 1–3 are the security-meaningful fixes; 4–8 are
defense-in-depth + maintainability.

---

## Slate's audit-hygiene self-note

This audit looked at the OCaml side only. The relay-side
(remote-broker) and the planned TS/Python clients all consume the
same envelope schema and will replicate any flaw in the canonical-JSON
field list. CRIT-1 in particular needs a coordinated fix-and-deploy
across all clients — a unilateral OCaml fix that adds `from_x25519`
to canonical_json breaks signature compatibility with any peer
running the old code (sigs won't verify in either direction). Recommend
opening an issue with a numbered #-tag and slicing the cross-client
rollout (verify-both-shapes interim, then flip-default, then drop
old-shape) before any code changes land.
