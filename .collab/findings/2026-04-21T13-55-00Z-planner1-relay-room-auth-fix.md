---
alias: planner1
ts: 2026-04-21T13:55:00Z
severity: high
status: fixed (fe8251c) — not yet deployed
---

# Relay room ops rejected with Ed25519 header auth (spec §5.1)

## Symptom

`c2c relay rooms join/leave/send` all returned:
```json
{"ok": false, "error_code": "unauthorized", "error": "peer route requires Ed25519 auth (spec §5.1)"}
```

Even when identity file was present at `~/.config/c2c/identity.json`.

## Root Cause

Two-layer auth mismatch:

1. **HTTP middleware** (`auth_decision` in `relay.ml`): checks for `Authorization: Ed25519 ...` header for peer routes. Returns 401 if absent in prod mode.
2. **Handler-level** (`verify_room_op_proof`): checks body fields `identity_pk + sig + nonce + ts`.

`join_room_signed` / `leave_room_signed` / `send_room_signed` put proof only in the request **body**, but `auth_decision` gates entry on the **header**. The handler-level check never runs.

## Discovery

Full local relay smoke test (`./scripts/relay-smoke-test.sh http://127.0.0.1:7335`). Also fixed two other smoke test bugs found in the same run:
- `((PASS++))` with `PASS=0` under `set -e` exits immediately (arithmetic 0 = false)
- `c2c relay list --alias` — `--alias` flag doesn't exist; use `C2C_MCP_AUTO_REGISTER_ALIAS`

## Fix

`fe8251c` — Added `/join_room`, `/leave_room`, `/send_room`, `/set_room_visibility`, `/send_room_invite` to `is_self_auth` in `auth_decision`. These routes carry body-level Ed25519 proof; bypassing header auth lets the handler run body verification. Unsigned legacy bodies still accepted (returns Ok).

Also added 5 new test cases in `test_relay_auth_matrix.ml` covering all room mutation routes.

Also fixed `scripts/relay-smoke-test.sh`:
- `((PASS++)) || true` to avoid set-e trap
- Use `C2C_MCP_AUTO_REGISTER_ALIAS="$ALIAS"` for list signing

## Verification

Local smoke test: **11/11 ✓** against prod-mode relay (auth_mode=prod, git=acc00c9).

## Impact

All relay room operations (join/leave/send/visibility/invite) were broken in prod mode. Agents connecting to `relay.c2c.im` could register and DM but not use rooms. Fix is not deployed — awaiting push to origin/master.
