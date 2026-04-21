---
date: 2026-04-21T12:15:00Z
author: coder2-expert
severity: MEDIUM — Python relay connector cannot use Ed25519 in prod mode
status: FIXED — cfc7939 (coder2-expert, 2026-04-21T12:20Z)
---

# Python relay connector: register lacks identity_pk binding for Ed25519 auth

## Problem

`c2c_relay_connector.py` was updated (92aba0d) to sign heartbeat/poll_inbox/send
with Ed25519 when `--identity-path` is provided. However, the signing will fail
in prod mode because:

1. Python `connector.relay.register(node_id, session_id, alias, ...)` calls
   `/register` WITHOUT `identity_pk` + `signature` + `nonce` + `timestamp` in the body.
2. The relay's `handle_register` only binds a pk to an alias when those fields are present.
3. When `heartbeat_signed` is called with `Authorization: Ed25519 alias=X,...`, the relay
   looks up `InMemoryRelay.identity_pk_of relay ~alias:X` and gets None.
4. Response: `"alias X has no identity binding"` (401).

## Root cause

`sign_register_body()` equivalent is not implemented in Python. The OCaml
`Relay_client.register_signed` takes pre-computed `identity_pk_b64`, `sig_b64`,
`nonce`, `ts` fields. The Python connector would need to implement the same
body-level proof using `Relay_signed_ops.sign_register`'s logic:

```
blob = "c2c/v1/register" + \x1f + alias + \x1f + relay_url.lower() + \x1f + pk_b64 + \x1f + ts + \x1f + nonce
sig = Ed25519.sign(private_key, blob)
```

## Impact

The Python connector (`c2c relay connect`) cannot be used in prod mode
(relay.c2c.im with RELAY_TOKEN set) until:
- Register includes identity_pk + signature in body
- Then heartbeat/poll_inbox/send can use Ed25519 with that bound pk

The OCaml CLI commands (`c2c relay register`, `c2c relay dm send/poll`) work
correctly in prod mode — they use `register_signed` and `sign_request`.

## Fix path

Add `sign_register_body()` to `c2c_relay_connector.py`:
1. Load identity from `identity_path`
2. Compute canonical msg: `"c2c/v1/register" + \x1f + alias + \x1f + relay_url.lower() + \x1f + pk_b64 + \x1f + ts + \x1f + nonce`
3. Sign with private key
4. Include `identity_pk`, `signature`, `nonce`, `timestamp` in register body

Then `RelayConnector.sync()` should use signed register when identity is available.

## Note

The session register constant is in `relay.ml`:
```ocaml
let register_sign_ctx = "c2c/v1/register"
```
The canonical msg uses unit-sep (\x1f), same as `sign_request`.
