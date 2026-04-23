# Mobile Pairing Runbook

**Audience**: c2c operators and agents pairing a mobile device (phone) to a desktop machine via QR code token flow.
**Goal**: pair a phone client to a desktop relay binding without re-discovering known failure modes.

---

## TL;DR

```bash
# Desktop: mint QR token (S5a prepare)
c2c relay mobile-pair prepare --relay-url https://your-relay.example.com

# Phone: scan QR, then confirm (S5a confirm)
c2c relay mobile-pair confirm \
  --relay-url https://your-relay.example.com \
  --binding-id BINDING_ID \
  --phone-ed-pk B64_PHONE_ED25519_PUBKEY \
  --phone-x-pk B64_PHONE_X25519_PUBKEY \
  --token QR_TOKEN

# Desktop: verify binding
c2c relay status

# Revoke (S5a revoke)
c2c relay mobile-pair revoke --binding-id BINDING_ID
```

---

## §1 — Overview

Mobile pairing uses a signed token flow (§S5a) to bind a phone's identity keys to a desktop machine without transferring private keys.

```
Desktop                          Relay                        Phone
   |                              |                             |
   |-- prepare ──────────────────>|  store signed token         |
   |<── binding_id + token ───────|  (300s TTL)                 |
   |                              |                             |
   |  [QR code displayed]         |                             |
   |                              |                             |
   |                              |<─────── scan + confirm ------|
   |                              |  verify sig + burn token    |
   |                              |  create binding             |
   |                              |                             |
   |  [phone bound]               |                             |
```

**Key constraints**:
- Token TTL is capped at 300 seconds server-side — clients should request shorter TTLs for safety
- Tokens are one-time use — `prepare` can be called multiple times (rebind overwrites prior token)
- `/mobile-pair/prepare` and `/mobile-pair` are self-auth (no Bearer token required)
- Revocation (`DELETE /binding/<binding_id>`) requires no auth — binding_id is the secret

---

## §2 — Desktop Side: Prepare (Mint QR Token)

### 2.1 Generate a pairing token

```bash
c2c relay mobile-pair prepare \
  --relay-url https://your-relay.example.com \
  --binding-id my-phone-01
```

**Flags**:
| Flag | Description |
|------|-------------|
| `--relay-url` | Relay server URL (or set `C2C_RELAY_URL`) |
| `--binding-id` | Human-readable binding name (8–64 chars, `[A-Za-z0-9_-]`) |
| `--ttl` | Token TTL in seconds (default: 300, max: 300) |

**Output** (human-readable):
```
binding_id: my-phone-01
token: <long base64url string>
nonce: <uuid>
ttl: 300
QR content: <same as token>
```

**Output** (`--json`):
```json
{
  "binding_id": "my-phone-01",
  "token": "<base64url-encoded JSON token>",
  "nonce": "<uuid>",
  "ttl": 300.0
}
```

### 2.2 Display QR code

The `token` field (or `QR content`) is the base64url-encoded token to display as a QR. Any QR library can encode it. The token is a JSON object:

```json
{
  "binding_id": "my-phone-01",
  "machine_ed25519_pubkey": "<base64url machine ed25519 pubkey>",
  "issued_at": 1714000000.0,
  "expires_at": 1714000300.0,
  "nonce": "<uuid>",
  "sig": "<base64url Ed25519 signature of canonical blob>"
}
```

**Token canonical blob** (what is signed):
```
c2c/v1/mobile-pair-token
<binding_id>
<machine_ed25519_pubkey>
<issued_at>
<expires_at>
<nonce>
```
(newlines are literal separators, no trailing newline)

**Verify token integrity**:
```bash
# Decode token from QR
echo "TOKEN_FROM_QR" | base64 -d | jq .
```

---

## §3 — Phone Side: Scan and Confirm

### 3.1 Scan the QR

The phone client parses the QR content as a base64url string, decodes it to JSON, extracts the fields, and calls `/mobile-pair/confirm`.

### 3.2 Generate phone identity keys

The phone must generate two keypairs before confirming:

| Key | Algorithm | Use |
|-----|-----------|-----|
| Phone Ed25519 pubkey | Ed25519 | Identity signing |
| Phone X25519 pubkey | X25519 | E2E encryption ( Curve25519 ) |

Both pubkeys are submitted as **base64url-no-padding** encoded 32-byte strings.

### 3.3 Confirm the binding

```bash
c2c relay mobile-pair confirm \
  --relay-url https://your-relay.example.com \
  --binding-id my-phone-01 \
  --phone-ed-pk PHONE_ED25519_PUBKEY_B64 \
  --phone-x-pk PHONE_X25519_PUBKEY_B64 \
  --token QR_TOKEN
```

**Server validates** (in order):
1. Token JSON parses and has required fields (`binding_id`, `machine_ed25519_pubkey`, `issued_at`, `expires_at`, `nonce`, `sig`)
2. `now` is within `[issued_at - 5s, expires_at]` (5s clock skew tolerance)
3. TTL (`expires_at - issued_at`) ≤ 300s
4. `binding_id` matches 8–64 char `[A-Za-z0-9_-]`
5. Signature (`sig`) verifies against canonical blob using `machine_ed25519_pubkey`
6. Token has not been burned (one-time use)

**On success** — server returns:
```json
{
  "ok": true,
  "binding_id": "my-phone-01",
  "confirmation": "<base64url-encoded confirm JSON>"
}
```

The `confirmation` field is a signed receipt the phone stores locally to prove the binding.

### 3.4 Store the binding

The phone client stores:
- `binding_id`
- `phone_ed25519_privkey` (private key, local only)
- `phone_ed25519_pubkey`
- `phone_x25519_privkey` (private key, local only)
- `phone_x25519_pubkey`
- `machine_ed25519_pubkey` (the desktop's identity pubkey)
- `confirmation` receipt

---

## §4 — E2E Envelope Shape

Once bound, messages between desktop and phone use the S3 signed envelope format with NaCl crypto_box encryption.

**Envelope format v1** (spec M1-breakdown.md §S3):
```json
{
  "from": "<canonical_alias>",
  "to":   "<canonical_alias>" | null,
  "room": "<room_id>" | null,
  "ts":   <epoch_ms>,
  "enc":  "box-x25519-v1" | "plain",
  "recipients": [
    { "alias": "<canonical>", "nonce": "<b64 24B nonce>", "ciphertext": "<b64 encrypted payload>" }
  ],
  "sig":  "<b64 Ed25519 signature of canonical JSON>"
}
```

**Key fields**:
- `from`: sender's canonical alias (phone alias, e.g. `max-phone`)
- `to`: recipient alias, or `null` for room sends
- `room`: room_id if room message, else `null`
- `enc`: `"box-x25519-v1"` for encrypted, `"plain"` for unencrypted
- `recipients[]`: one entry per intended recipient, each with per-recipient nonce + ciphertext
- `sig`: Ed25519 signature over canonical JSON of `{from,to,room,ts,enc,recipients}` — sender signs regardless of encryption

**Encryption algorithm**: NaCl crypto_box (X25519 → HSalsa20 → XSalsa20-Poly1305). Not Signal-style double-ratchet — single DH per message.

### 4.1 Desktop → Phone E2E send

1. Look up `phone_x25519_pubkey` from the binding (stored during `/mobile-pair/confirm`)
2. Generate fresh 24-byte nonce per recipient
3. `crypto_box` per recipient: `Hacl.NaCl.box ~pt:body ~n:nonce ~pk:phone_x25519_pubkey ~sk:sender_x25519_privkey`
4. Wrap in S3 envelope with `enc: "box-x25519-v1"`, sign with Ed25519 identity key

**Envelope** (what gets stored in inbox):
```json
{
  "from": "desktop-alias",
  "to": "max-phone",
  "room": null,
  "ts": 1714000000.0,
  "enc": "box-x25519-v1",
  "recipients": [
    { "alias": "max-phone", "nonce": "<b64 24B>", "ciphertext": "<b64>" }
  ],
  "sig": "<b64 Ed25519 sig>"
}
```

### 4.2 Phone decryption

1. Find own entry in `recipients[]` by matching own alias
2. `crypto_box_open`: `Hacl.NaCl.box_open ~c:ciphertext ~n:nonce ~pk:sender_x25519_pubkey ~sk:phone_x25519_privkey`
3. Verify outer `sig` against sender's Ed25519 pubkey (pinned via S2 TOFU)

### 4.3 Relay inbox storage

The relay stores the E2E envelope as-is — it never decrypts E2E messages. The envelope is opaque binary from the relay's perspective.

---

## §5 — Revocation

### 5.1 Revoke a binding (desktop or phone)

```bash
c2c relay mobile-pair revoke \
  --relay-url https://your-relay.example.com \
  --binding-id my-phone-01
```

**CLI equivalent**:
```bash
curl -X DELETE \
  "https://your-relay.example.com/binding/my-phone-01"
```

**No auth required** — `binding_id` is the secret. Anyone with the binding ID can revoke it.

**Server behavior**:
- Removes `binding_id` from observer bindings store
- Returns `{"ok": true, "binding_id": "my-phone-01"}` if it existed
- Returns `{"ok": false, "error": "not_found"}` if binding_id was already gone

### 5.2 Rebind after revoke

Call `prepare` again with the same or a new `binding-id` to get a fresh token. The old token is invalid after revoke.

### 5.3 Confirmation of revoke

After revoke, the desktop's relay client should discard the stored binding for that `binding_id`. The phone should also delete its local binding record.

---

## §6 — API Reference

### POST /mobile-pair/prepare

Store a signed pairing token. Returns `binding_id`.

**Request**:
```json
{
  "machine_ed25519_pubkey": "<base64url 32-byte pubkey>",
  "token": "<base64url-encoded JSON token signed by machine>"
}
```

**Response 200**:
```json
{ "binding_id": "my-phone-01" }
```

**Errors**: 400 (missing fields, invalid encoding, signature invalid, expired token, TTL > 300s)

### POST /mobile-pair

Verify token signature, burn token, create binding.

**Request**:
```json
{
  "token": "<base64url-encoded JSON token>",
  "phone_ed25519_pubkey": "<base64url 32-byte pubkey>",
  "phone_x25519_pubkey": "<base64url 32-byte pubkey>"
}
```

**Response 200**:
```json
{
  "ok": true,
  "binding_id": "my-phone-01",
  "confirmation": "<base64url signed receipt>"
}
```

**Errors**: 400 (token already used, signature invalid, pubkey invalid)

### DELETE /binding/{binding_id}

Revoke a binding. No auth required.

**Response 200**:
```json
{ "ok": true, "binding_id": "my-phone-01" }
```

**Response 404**: binding not found

---

## §7 — Common Failure Modes

### 7.1 Token expired

**Symptom**: `{"ok": false, "error": "token expired"}`

**Cause**: More than 300s elapsed since `prepare`.

**Fix**: Run `prepare` again to get a fresh token. Display new QR. Confirm within 5 minutes.

### 7.2 Token already used

**Symptom**: `{"ok": false, "error": "token already used, expired, or not found"}`

**Cause**: `confirm` was already called with this token (one-time use).

**Fix**: Run `prepare` again to get a fresh token.

### 7.3 Signature verification failed

**Symptom**: `{"ok": false, "error": "token signature verification failed"}`

**Cause**: The machine's private key used to sign the token doesn't match the `machine_ed25519_pubkey` submitted in `prepare`.

**Fix**: Ensure the same identity keypair is used for both `prepare` signing and the pubkey field in the token JSON.

### 7.4 Binding ID collision

**Symptom**: `prepare` succeeds but `confirm` fails with "token mismatch after burn"

**Cause**: `prepare` was called twice with the same `binding-id` — the second call overwrote the stored token, but an old QR was scanned.

**Fix**: Use a fresh `binding-id` or ensure the phone scans the most recently issued QR.

### 7.5 Phone pubkey deserialization error

**Symptom**: `{"ok": false, "error": "phone_ed25519_pubkey must be 32 bytes"}`

**Cause**: Pubkey is not exactly 32 bytes after base64url decoding.

**Fix**: Ensure the phone generates proper Ed25519/X25519 keypairs and encodes only the 32-byte raw pubkey (no header, no base64 padding).

### 7.6 Clock skew

**Symptom**: `{"ok": false, "error": "token issued_at in future"}`

**Cause**: Desktop clock is more than 5 seconds ahead of relay server clock.

**Fix**: Sync desktop clock via NTP. The relay allows a 5-second skew tolerance on `issued_at`.

---

## §8 — Security Notes

- `binding_id` is the secret — anyone who knows it can revoke the binding
- The relay does not store phone private keys — only the two pubkeys
- E2E encryption is end-to-end between desktop and phone — relay never sees plaintext
- Token TTL is capped at 300s server-side to limit replay window
- One-time use of tokens prevents replay attacks on the confirm step

---

## §9 — S5c: Relay-to-Broker Push (Observer WebSocket)

After mobile pair confirm/revoke, the relay pushes notifications to connected observer WebSocket clients so the bound broker can update its registry.

### 9.1 On pair confirm — `pseudo_registration` push

After the binding is created in the relay's observer bindings store, the relay sends a `pseudo_registration` frame to all active observer WebSocket sessions for that binding_id:

```json
{
  "type": "pseudo_registration",
  "alias": "<phone_alias>",
  "ed25519_pubkey": "<phone Ed25519 pubkey>",
  "x25519_pubkey": "<phone X25519 pubkey>",
  "machine_ed25519_pubkey": "<desktop machine Ed25519 pubkey>",
  "binding_id": "<binding_id>",
  "bound_at": <epoch_float>,
  "provenance_sig": "<desktop-signed sig over above fields>"
}
```

**Note**: Without the broker-side consumer of this push (S5c-broker, tracked separately as #104), the phone is **not** a reachable peer after pair. Desktop cannot `c2c send <phone-alias>` until the broker processes this frame. The phone shows as a peer in the relay's observer sessions but not in the broker's registry.

### 9.2 On revoke — `pseudo_unregistration` push

When a binding is revoked, the relay sends:

```json
{
  "type": "pseudo_unregistration",
  "binding_id": "<binding_id>"
}
```

This tells the bound broker to remove the phone's pseudo-registration entry.

### 9.3 Observer WebSocket frame format

All observer WS frames are JSON text messages. The `type` field discriminates:
- `replay` — reconnect cursor replay (contains `messages[]` array + optional `gap: true`)
- `observer_pong` — response to ping
- `observer_ack` — acknowledgment of unknown frame type
- `pseudo_registration` — new phone binding pushed from relay
- `pseudo_unregistration` — phone binding removed
- `broker_offline` — broker unreachable (phone→relay buffering active)
