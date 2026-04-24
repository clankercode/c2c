# S5c Phase B Implementation Findings

**Author**: jungle-coder
**Date**: 2026-04-24
**Status**: In Progress - transport and storage implemented, integration pending

## What's Implemented

### 1. Client-side WebSocket Support (relay_ws_frame.ml)

Added:
- `generate_masking_key()` - generates random 4-byte masking key for RFC 6455
- `mask_data()` - XOR masking for client frames
- `write_frame_masked()` - masked server-bound frames
- `write_text_masked()`, `write_binary_masked()`, `write_close_masked()`, `write_ping_masked()`, `write_pong_masked()`
- `make_client_handshake_request()` - builds WS upgrade HTTP request
- `Client_session` module - manages client-side WS sessions

### 2. Broker WS Connector (c2c_relay_connector.ml)

Added:
- `broker_ws_connect()` - connects to relay's `/observer/<binding_id>` as outbound WS client
- `handle_pseudo_registration()` - processes incoming pseudo_registration frames
- `handle_pseudo_unregistration()` - processes incoming pseudo_unregistration frames
- `ws_client_loop()` - receive loop for WS frames

### 3. Pseudo-registration Storage (c2c_relay_connector.ml)

- Stored in `pseudo_registrations.json` (separate from `registry.json` per Max's approval)
- Type `pseudo_registration` with fields: alias, ed25519_pubkey, x25519_pubkey, machine_ed25519_pubkey, provenance_sig, bound_at
- `read_pseudo_registrations()` - reads from file
- `write_pseudo_registrations()` - writes to file (atomic via temp file + rename)
- `upsert_pseudo_registration()` - upsert by binding_id
- `remove_pseudo_registration()` - remove by binding_id

## What's Missing

### Integration into Sync Loop

`broker_ws_connect()` is implemented but NOT wired into the `sync()` loop. It needs to be called:
1. On startup (for each known binding_id that has an active WS connection)
2. When a new binding is established (via pairing flow)

### How It Should Work

1. When broker starts, it should connect to relay's `/observer/<binding_id>` for each known binding
2. When a mobile pair completes, broker receives pseudo_registration via WS and stores it
3. When binding is revoked, broker receives pseudo_unregistration via WS and removes it
4. The broker should also expose these pseudo-registrations via `c2c list` so agents can send to phones

## Auth Consideration

The relay's `/observer/<binding_id>` endpoint currently requires Ed25519 peer auth (bearer token = binding_id). For the broker to connect as an observer client, it needs to use the binding_id as the bearer token. This works with the existing auth because `token = None` passes through in dev mode.

## Test Status

- relay_ws_frame.ml: builds
- c2c_relay_connector.ml: builds
- test_relay_observer_contract.ml: all 8 tests pass

## Next Steps

1. Wire broker_ws_connect into sync loop (or startup)
2. Ensure binding_ids are tracked by the connector
3. Add `c2c list` integration to show pseudo-registrations as peers
