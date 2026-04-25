# Peer Review Findings: jungle #170 stickers @ 46fc8a0

## Date: 2026-04-25
## Reviewer: test-agent
## Verdict: PASS

## Build Status
All 3 binaries built successfully:
- c2c.exe ✓
- c2c_mcp_server.exe ✓
- c2c_inbox_hook.exe ✓

## Files Reviewed
- ocaml/cli/c2c_stickers.ml
- ocaml/cli/c2c_stickers.mli
- ocaml/relay_identity.ml / relay_identity.mli
- ocaml/relay_e2e.ml

## Crypto Findings (c088499 — coordinator-flagged bug)

**Bug**: OLD code passed `env.sender_pk` (base64-encoded) directly to `Relay_identity.verify`
which expects raw 32-byte public key.

**Fix (c088499)**: `verify_envelope` now:
1. `Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet env.signature` → sig_bytes
2. `Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet env.sender_pk` → pk_bytes
3. Validates `String.length pk_bytes = 32` and `String.length sig_bytes = 64`
4. Calls `Relay_identity.verify ~pk:pk_bytes ~msg:blob ~sig_:sig_bytes`

This is correct. `Relay_identity.verify` takes raw bytes (not base64) — confirmed from relay_identity.mli spec.

**sign_envelope**: correctly encodes `identity.public_key` via `b64url_nopad` before storing in `sender_pk` field. ✓

## Recursion Fix (c088499)

**OLD**: `go acc` tail-call after `Unix.readdir` with no exception handler → infinite recursion on EOF + fd leak.

**FIXED**: 
- `try match Unix.readdir d with ... | _ -> go acc with End_of_file -> acc`
- `Unix.closedir d` always runs after `go []`

## Non-blocking Notes
- `load_registry ()`: silently returns `[]` on any exception — acceptable for safe fallback
- `atomic_write_file`: uses temp+rename pattern correctly ✓
