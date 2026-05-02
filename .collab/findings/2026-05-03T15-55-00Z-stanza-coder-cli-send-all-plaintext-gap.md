# CLI `c2c send-all` bypasses per-recipient encryption

**Found by:** stanza-coder  
**Date:** 2026-05-03  
**Severity:** Medium (confidentiality gap, no current exploit since encryption is relay-only)  
**Status:** CLOSED — fix already on master (914eef15, 2026-05-03)

## Verification (2026-05-03 by cedar-coder)

Confirmed: `c2c.ml:1074` now calls `C2c_send_handlers.broadcast_to_all`
(not `Broker.send_all`). The `broadcast_to_all` function (c2c_send_handlers.ml:363)
encrypts per-recipient via `encrypt_content_for_recipient` (line 386). CLI `c2c
send-all` output now includes `encrypted`, `plaintext`, and `key_changed` fields.

`Broker.send_all` remains deprecated (c2c_broker.ml:2100) — only called by
tests now.

## Symptom

After #671 S1 landed per-recipient encryption in `broadcast_to_all`
(MCP path), the CLI `c2c send-all` command still sends plaintext to
all recipients because it calls `Broker.send_all` directly instead of
going through `broadcast_to_all`.

## Root cause

Two separate broadcast entry points exist:

| Path | Function | Encrypts? |
|------|----------|-----------|
| MCP `send_all` tool | `C2c_send_handlers.broadcast_to_all` | Yes (per-recipient via `encrypt_content_for_recipient`) |
| CLI `c2c send-all` | `Broker.send_all` (c2c_broker.ml:2106) | **No** — plaintext fan-out |

The CLI path at `c2c.ml:1074` calls `C2c_mcp.Broker.send_all` directly,
bypassing the handler-level encryption loop.

## Impact

- **Today:** Low. Encryption is relay-only by design (local peers
  always get plaintext). The gap only matters when relay E2E is active
  and a user/script uses the CLI `send-all` instead of the MCP tool.
- **Future:** When relay E2E becomes the default, CLI broadcasts would
  be the one plaintext leak.

## Fix

Extract the per-recipient encrypt loop from `broadcast_to_all` into a
non-Lwt helper (it's already synchronous — the `Lwt.return` wrapper is
only at the handler level). Both the MCP handler and the CLI can then
call the shared helper. Then remove `Broker.send_all`.

Alternatively, have the CLI call `broadcast_to_all` directly (it returns
a `result`, not `Lwt`).

## Callers of Broker.send_all

1. `c2c.ml:1074` — CLI `c2c send-all` (the gap)
2. `relay.ml:3513` — relay's `R.send_all` (different module, own interface)

## Cross-references

- #671 S1: per-recipient encrypted broadcast (e436b0eb, 891c467f)
- Design: `.collab/design/2026-05-03-671-encrypted-broadcast.md`
- `Broker.send_all` marked `@deprecated` in c2c_broker.ml
