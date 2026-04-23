# S5a Design Decision: /mobile-pair/prepare Round-Trip

## Decision Needed

Should `/mobile-pair/prepare` be a single round-trip or two?

## Option A: Single Round-Trip (Recommended)

**CLI → `POST /mobile-pair/prepare {machine_ed25519_pubkey}` → Relay**
- Relay generates `binding_id` (UUIDv4) + `token` (5-min TTL)
- Relay signs token with `machine_ed25519_pubkey`
- Response: `{binding_id, token}`
- CLI qrencodes `{relay_url, binding_id, token, machine_ed25519_pubkey}`

**Pros**: Fewer race windows, relay holds all state needed for verification at claim time
**Cons**: Slightly more work for relay (token gen + signing)

## Option B: Two Round-Trips

**CLI → `POST /mobile-pair/prepare` → Relay returns `{binding_id}`**
**CLI → `POST /mobile-pair/prepare {binding_id, machine_ed25519_pubkey, token}` → Relay stores token**

**Pros**: Simpler relay state initially
**Cons**: Race window between reserve and token-store; more HTTP round-trips

## Recommendation

**Option A** — single round-trip, as described by coordinator1.

Relay stores `(binding_id, token, machine_ed25519_pubkey, used=0, expires_at)` atomically at prepare time. When phone POSTs to `/mobile-pair`, relay verifies + burns token + creates binding in one compare-and-swap.

## Token Format

```
Payload JSON: {binding_id, issued_at, expires_at, nonce}
- nonce: random 16-byte hex (16 chars)
- Canonical msg for signing: "c2c/v1/mobile-pair-token" || binding_id || machine_ed25519_pubkey_b64 || issued_at || expires_at || nonce
- Sig: Ed25519 sign of canonical msg using machine's Ed25519 private key
- Token delivery to phone: base64url({binding_id, issued_at, expires_at, nonce, sig})
```

## SQLite Schema Addition

```sql
CREATE TABLE pairing_tokens (
    binding_id TEXT PRIMARY KEY,
    token_b64 TEXT NOT NULL,
    machine_ed25519_pubkey TEXT NOT NULL,
    used INTEGER NOT NULL DEFAULT 0,
    expires_at REAL NOT NULL
);
```

## Atomic Burn (C4)

```sql
UPDATE pairing_tokens SET used=1 WHERE binding_id=? AND used=0 AND expires_at>?;
-- If rows_affected == 0: token invalid (already used or expired)
```

## Files to Modify

1. `ocaml/relay_sqlite.ml` — add `pairing_tokens` table + DDL migration
2. `ocaml/relay.ml` — add `POST /mobile-pair/prepare` and `POST /mobile-pair` handlers
3. `ocaml/relay_identity.ml` — add `mobile_pair_token_sign_ctx` constant
4. `ocaml/cli/c2c.ml` — add `mobile-pair` subcommand
5. `ocaml/test/test_relay_bindings.ml` — add S5a tests