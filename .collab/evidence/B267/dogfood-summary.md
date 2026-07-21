# B267 isolated local-relay dogfood (loopback only)

**When:** 2026-07-21T15:58Z  
**Binary:** worktree `feature/b264-private-discovery` `c2c.exe`  
**Relay:** `127.0.0.1:<ephemeral>` token-configured SQLite (`auth_mode=prod`)

## Results

| Step | Result |
|---|---|
| Health ads `contact_protocol=1`, `private_reachability=consent_gated`, `auth_mode=prod` | PASS |
| Register `zzalice` + `zzbob` with distinct Ed25519 identities | PASS |
| Anonymous `/list`, `/pubkey/zzalice`, `/send` | HTTP 401 unauthorized |
| Authenticated peer `/list` | `peers: []` (private default; no enumeration) |
| Authenticated legacy `/send` bob→alice without grant | `unknown_alias` (uniform), **no** inbox row, **no** content DLQ |
| `c2c relay contact issue` (alice binds bob) | secret once in JSON; list redacts secret |
| Signed `POST /contact/v1/deliver` authorised | `ok:true` once; inbox `AUTH-CONTACT-OK` |
| Replay same `message_id` | `ok:true, duplicate:true`; still one inbox row |
| Protocol downgrade `c2c-contact/0` | `contact_unauthorised` |

## Artefacts

`.collab/evidence/B267/dogfood-isolated-local/` (health, register, grant issue/list, signed list/send/contact JSON).

## Note on CLI signing

`c2c relay list/dm` with `C2C_RELAY_IDENTITY_PATH` hit signature_invalid in this session (path/env interaction). Authorised contact path was proven with a Python Ed25519 signer matching `Relay_signed_ops.sign_request` over the same identity files. Hermetic Alcotest suites remain the primary regression gate.

## Production

No write-capable smoke against `relay.c2c.im`.
