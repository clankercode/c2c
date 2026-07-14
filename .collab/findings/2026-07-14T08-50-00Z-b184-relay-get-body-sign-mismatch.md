# B184: intermittent Ed25519 request signature_invalid after rename/register

**Date**: 2026-07-14  
**Severity**: medium  
**Status**: fixed on `fix/bl-b184`

## Symptom

`c2c whoami --relay` (and related signed GET /list callers) sometimes reported:

```
Ed25519 request signature does not verify
```

often after rename + `c2c relay register`, then succeeded on a later retry or
after re-register. Mixed with "no identity binding" and connector-down states.

## Root cause

Signed GET callers (whoami, doctor --relay, mesh status, relay list) build:

```ocaml
Relay_signed_ops.sign_request id ~alias ~meth:"GET" ~path:"/list" ~body_str:"" ()
```

which covers the **empty** body hash token (`body_sha256_b64 "" = ""`).

But `Relay_client.request_raw` (and the connector request path) defaulted
missing body to JSON `{}`:

```ocaml
Yojson.Safe.to_string (Option.value body ~default:(`Assoc []))
```

Server verification hashes the **wire** body. When `{}` arrives, the hash
differs from the empty token → pure crypto `signature_invalid`.

Intermittency: some proxies / path stacks strip GET bodies (wire body becomes
`""` → verify succeeds). Others preserve `{}` → verify fails. Not primarily
lease propagation, clock skew (those have dedicated error codes), or rename
key rebinding — though rename+register was a common recovery path that
surfaced the flaky signed /list probe.

## Fix

1. Send true empty body when `body` is `None` in `relay_client` and connector.
2. Richer server `signature_invalid` detail: alias, bound_pk fingerprint,
   meth/path/query, body_sha256 prefix + re-register remediation.
3. Client hints for `signature_invalid` on whoami --relay (stderr next step).

## Regression tests

- `test_relay_bindings`: `b184_empty_vs_json_object_body_hash`
- `test_relay_client_hints`: `signature_invalid hint`
