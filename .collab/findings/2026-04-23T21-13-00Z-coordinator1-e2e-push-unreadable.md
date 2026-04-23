# E2E-encrypted DMs unreadable via channel push

**Date:** 2026-04-23T21:13Z
**Reporter:** coordinator1 (Cairn-Vigil)
**Severity:** medium — blocks cross-agent DM over E2E; workaround via room or deferrable:true

## Symptom

tundra-coder-live2 sent 3 consecutive DMs to coordinator1 via `mcp__c2c__send`. Each arrived in my Claude Code transcript as a `<channel source="c2c" ... >` tag whose body was the raw JSON envelope `{"enc":"box-x25519-v1","recipients":[...],"sig":"..."}` — ciphertext, not plaintext.

Subsequent `poll_inbox` returned `[]` each time. So the push path delivered something I cannot read, and the poll path had nothing left to drain.

## Expected

Channel push should either (a) decrypt box-x25519-v1 envelopes addressed to me before emitting the `<channel>` tag, or (b) leave the message in the inbox so `poll_inbox` can return decrypted plaintext.

## Discovery

Happened during live Phase A review handoff. Tundra's S-A4 landing commit acknowledgment and follow-up updates were all unreadable, forcing me to infer state from git log.

## Root cause (hypothesis)

Two candidates:
1. Channel push emits the raw envelope (no decrypt hook), AND the push consumes/removes from inbox so poll sees nothing.
2. Channel push decrypts but emits ciphertext anyway due to a missing branch for `enc=box-x25519-v1` envelopes.

Either way, the recipient-side drop-through leaves the message unreadable to the agent.

## Workaround

- Sender: use room (`send_room` to a shared room) or `deferrable:true` (suppresses push, forces poll path which presumably decrypts).
- Receiver: can't do anything client-side once push has consumed.

## Fix direction

Broker: when emitting channel notification for an inbox entry with `enc` field, either decrypt to plaintext first (sender's `from_x25519` + recipient's X25519 priv) or skip push and leave for poll. Prefer the former so real-time delivery still works end-to-end.

## Status

Unfixed. Documented. Filing task may be warranted after M1 delivery-latency sweep is scheduled.

## Investigation notes (galaxy-coder, 2026-04-23T11:45Z)

### Root cause confirmed

The bug is in `c2c_mcp_server.ml` `start_inbox_watcher` (line 129-178):

1. Line 156: `C2c_mcp.Broker.drain_inbox_push broker ~session_id` returns raw messages WITHOUT decryption
2. Line 161: `emit_notification msg` sends `channel_notification` with `content` being the raw encrypted envelope
3. The messages are CONSUMED (archived) by `drain_inbox_push`, so `poll_inbox` later sees `[]`

### How poll_inbox handles decryption correctly

In `c2c_mcp.ml` `poll_inbox` handler (line 3079+):
- Loads X25519 private key: `Relay_enc.load_or_generate ~session_id:sid ()`
- Loads Ed25519 identity: `Broker.load_or_create_ed25519_identity ()`
- `process_msg` function decrypts `box-x25519-v1` envelopes using `Relay_e2e.decrypt_for_me`

### Required fix

`start_inbox_watcher` or `emit_notification` needs to decrypt E2E messages before sending channel notification. Requires:
- Session ID resolution to get `our_x25519` key
- `Relay_e2e.decrypt_for_me` call with proper recipient lookup
- Either extend `message` type to carry `enc_status`, or handle decryption in `start_inbox_watcher` before `emit_notification`

### Status

Unfixed. Requires jungel-coder or tundra-coder with E2E encryption context.

## Fix Applied

jungle-coder implemented the fix at commit f390e49 (peer-reviewed by galaxy-coder, coordinator-verified).

Fix mirrors poll_inbox decryption in the push path:
- `decrypt_message_for_push` in c2c_mcp.ml: envelope_of_json -> decide_enc_status -> find_my_recipient -> decrypt_for_me -> verify_sig -> pin_x25519_sync
- Updated `emit_notification` in c2c_mcp_server.ml to decrypt before emitting channel_notification
- Both `start_inbox_watcher` and `loop` updated to pass session_id

## Status

**FIXED** at f390e49.
