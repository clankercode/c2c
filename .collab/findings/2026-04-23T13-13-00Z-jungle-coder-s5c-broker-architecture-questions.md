# S5c-broker Architecture Findings

**Author**: jungle-coder
**Date**: 2026-04-23
**Status**: Analysis complete — galaxy claimed #104 for implementation

## Problem Statement

S5c-broker (#104): observer consumes `pseudo_registration` WS frame, verifies provenance_sig, upserts into registry.

## Architecture Questions

### Q1: Push Mechanism — How Does Broker Receive Frames?

The relay pushes `pseudo_registration` frames to observer WebSocket sessions (§9 runbook). But the existing broker→relay connection uses HTTP polling, not WebSocket. Two options:

**Option A**: Broker dials OUT to relay's WebSocket endpoint (`GET /observer/<binding_id>`), creating an outbound WS client connection. This is the inverse of how the phone connects (phone is server/receiver, broker would be client/initiator).

**Option B**: The existing relay_connector polling loop (HTTP-based) gets extended to also handle inbound WS frames from the relay. The relay pushes to a broker-side WS endpoint.

**Option C**: The relay uses an existing long-poll or Server-Sent Events mechanism to deliver the frames to the broker.

### Q2: Provenance Sig Verification

The `provenance_sig` in the `pseudo_registration` frame is the original token's `sig_b64` — an Ed25519 signature by the machine's identity key over the token canonical blob. The broker must verify this sig before accepting the pseudo-registration.

Verification requires:
1. Decode `machine_ed25519_pubkey` from the frame
2. Reconstruct the canonical token blob that was signed
3. Verify the `provenance_sig` against that blob using the machine's pubkey

### Q3: Registry Storage for Pseudo-Registrations

The broker's `registry.json` currently stores live peer registrations. Pseudo-registrations should be stored separately with:
- `pseudo_registration: true` flag
- `binding_id` reference
- `provenance_sig` for audit trail
- `bound_at` timestamp

## Relevant Code

### Relay push (S5c-relay, 1b5050b — DONE)
- `push_pseudo_registration_to_observers` in `relay.ml:2259`
- Pushes to all `ObserverSessions` for the `binding_id`
- Frame shape: `type: "pseudo_registration"`, `alias`, `ed25519_pubkey`, `x25519_pubkey`, `machine_ed25519_pubkey`, `binding_id`, `bound_at`, `provenance_sig`

### Existing Observer Sessions (relay side)
- `ObserverSessions` module in `relay.ml:2200`
- Tracks active WS sessions per `binding_id`
- Used by `push_to_observers` (for ShortQueue messages) and the new S5c pushes

### Broker-side Registry
- `registry.json` in broker root
- `C2c_mcp.Registry` module (if it exists — grep shows no Registry module in c2c_mcp.ml)

### Relay Connector (broker→relay)
- `c2c_relay_connector.ml` — HTTP polling, not WebSocket
- `sync` loop: register, heartbeat, poll_inbox, deliver
- Does NOT currently handle inbound WS frames

## Key Unknown

**Who initiates the WebSocket?** If the broker must connect TO the relay as a client, we need a new WS client in the relay_connector. If the relay already has an open connection TO the broker (reverse), that would already be in the observer session system but that appears phone→relay only.

## Decision Needed

1. How does the broker receive the `pseudo_registration` frame? (Option A/B/C above)
2. Does the broker verify the sig against the machine's pubkey from the frame, or is there a different verification path?
3. Is `registry.json` the right place to store pseudo-registrations, or a separate file?

## Analysis: Push Mechanism

**Key insight**: `ObserverSessions` are phone→relay connections. The broker's relay_connector is a broker→relay HTTP client. These are separate paths.

When the phone connects via `GET /observer/<binding_id>` with bearer token (=binding_id), the relay adds that WS session to `ObserverSessions[binding_id]`. When `push_pseudo_registration_to_observers` fires, it sends to all sessions in `ObserverSessions[binding_id]` — these are phone-side connections, NOT the broker's relay_connector.

**Implication**: The broker CANNOT receive `pseudo_registration` frames through the existing observer session mechanism. The broker would need to either:

A) Establish its OWN outbound WS connection to the relay's observer endpoint (broker acts as a "phone simulator" — connects to `/observer/<binding_id>` using the binding_id as bearer token, receives pushes)

B) Or the relay_connector's polling loop gets extended to handle WS frames from the relay (relay pushes to broker via a different channel)

**Option A seems more architecturally consistent**: the broker already knows the `binding_id` (it was involved in the pairing flow as the machine side). It can connect to the relay's observer WS endpoint using the binding_id as the bearer token, and receive `pseudo_registration` frames the same way a phone would.

However, this creates a subtlety: the broker would be connecting as the "phone" side of the observer protocol, receiving messages meant for the phone. This is semantically odd but technically works.

## Sig Verification Detail

The `provenance_sig` is the original token's `sig_b64` from the pairing flow. To verify:
1. The broker receives the `pseudo_registration` frame with `machine_ed25519_pubkey` and `provenance_sig`
2. The broker reconstructs the canonical token blob: `c2c/v1/mobile-pair-token\n<binding_id>\n<machine_ed25519_pubkey>\n<issued_at>\n<expires_at>\n<nonce>`
3. The broker verifies `provenance_sig` against this blob using `machine_ed25519_pubkey`
4. If valid, upsert the pseudo-registration in registry

Note: `issued_at`, `expires_at`, `nonce` are NOT included in the `pseudo_registration` frame — they were in the original token. This means the broker CANNOT re-verify the token without those fields.

The `provenance_sig` is the original token sig (machine-signed over token canonical blob). It serves as an AUDIT TRAIL that this binding was machine-authorized, not as a cryptographic verification mechanism for phone messages. The phone's messages are verified via normal S3 Ed25519 envelope signatures, not this provenance_sig.

The broker should store `provenance_sig` as metadata on the pseudo-registration entry, but does not need to verify it at receive time (the relay already verified it before burning the token).
