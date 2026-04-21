---
date: 2026-04-21T12:00:00Z
author: coder2-expert
severity: HIGH (blocks prod-mode relay connector heartbeats/polls)
status: FIXED (92aba0d)
---

# Relay connector peer routes lacked Ed25519 auth in prod mode

## Symptom

`c2c relay connect` (Python connector) and `c2c relay dm poll` (OCaml CLI)
would fail all peer route requests (heartbeat, poll_inbox, send, list) in
prod mode with error:

```
"peer routes require Ed25519 auth per spec §5.1; Bearer is admin-only"
```

## Root cause

The relay's `auth_decision` distinguishes two categories:
- **Admin routes** (`/gc`, `/dead_letter`, `/admin/unbind`, `/list?include_dead`):
  require Bearer token
- **Peer routes** (everything else except `/health`, `/register`):
  require Ed25519 header auth (`Authorization: Ed25519 alias=...,ts=...,nonce=...,sig=...`)

In prod mode (`RELAY_TOKEN` set), Bearer on a peer route is explicitly rejected.
Dev mode (`token = None`) allows unsigned requests.

`c2c_relay_connector.py` only ever added `Authorization: Bearer <token>`,
which works in dev mode but fails in prod.

`c2c relay dm poll` (OCaml CLI) always used `Relay_client.poll_inbox`
(unsigned), not the signed variant.

## Fix

**92aba0d** — three-part fix:

1. **`Relay_client`** (`ocaml/relay.ml`): Added `heartbeat_signed` and
   `poll_inbox_signed` variants that accept `~auth_header:string`.

2. **`c2c relay dm poll`** (`ocaml/cli/c2c.ml`): Updated to use
   `poll_inbox_signed` when `Relay_identity.load()` succeeds; falls back to
   unsigned (backward compat with dev mode / no identity).

3. **`c2c_relay_connector.py`**: Added `_sign_peer_request()` implementing
   spec §5.1 canonical_request_blob via `cryptography.Ed25519PrivateKey`.
   `_request()` now:
   - For unauthenticated/self-auth routes: no header
   - For admin routes: Bearer token
   - For peer routes when identity is loaded: Ed25519 signed per-request
   - Fallback: Bearer (preserves dev-mode behavior)
   
   `heartbeat`, `poll_inbox`, `send` now pass `alias=` so the per-request
   signature uses the correct signer alias.

## Notes

- The identity file is at `$XDG_CONFIG_HOME/c2c/identity.json`
  (default `~/.config/c2c/identity.json`). Both OCaml and Python now load it.
- Python refuses to load identity files with group/world-readable perms
  (mirrors OCaml behavior).
- The Python connector `cryptography` package was already available on the
  system; no new dependency needed.
- `Relay_client.heartbeat_signed` is not yet called from anywhere in the
  MCP broker loop (the broker doesn't heartbeat a remote relay directly yet),
  but it's available for future use when `relay connect` is ported to OCaml.
