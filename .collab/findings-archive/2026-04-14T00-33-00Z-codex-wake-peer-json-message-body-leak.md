# wake-peer notify-only JSON leaked broker message bodies

## Symptom

Running `./c2c wake-peer claude-main --json` on an inbox with queued messages
printed the child `c2c_deliver_inbox.py --notify-only --json` result verbatim.
That embedded result included the full `messages` array, including message
`content`.

## Discovery

After `c2c health --json` reported `claude-main` as the only actionable stale
inbox, codex used `wake-peer --json` as the manual notify-only escape hatch.
The command output showed that the PTY nudge itself was content-free, but the
operator JSON response contained the peeked broker messages.

## Root Cause

`c2c_deliver_inbox.deliver_once()` must keep raw peeked messages in its internal
result so notify-only loop debounce can compute message signatures without
draining the broker. The CLI output path reused that internal result directly.
`c2c_wake_peer.py` then embedded the child JSON result directly in its own JSON
response.

## Fix Status

Fixed by adding a public-output sanitizer for notify-only
`c2c_deliver_inbox --json` and a defensive sanitizer in `c2c_wake_peer --json`.
Sanitized output preserves `message_count` and marks `messages_redacted: true`
while replacing `messages` with `[]`. Regression tests cover both command
boundaries.

## Severity

High for operator privacy and transcript hygiene. Message content still stayed
broker-native for delivery, but command telemetry could echo private C2C bodies
into the caller transcript.
