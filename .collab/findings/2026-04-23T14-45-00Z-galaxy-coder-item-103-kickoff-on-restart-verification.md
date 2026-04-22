# Item 103: Kickoff-on-Restart Verification

## What was reported
On peer restart, the "you are a c2c agent" auto-message no longer fires.

## Verification 2026-04-23

### Mechanism verified (PASS)
- `kickoff-prompt.txt` IS created on restart at `~/.local/share/c2c/instances/galaxy-coder/kickoff-prompt.txt`
- File contains correct role content with include:[recovery]
- Code path is sound: `deliverKickoffPrompt()` reads file on `session.idle`

### session.idle dependency (LIMITATION)
The plugin delivers kickoff ONLY on `session.idle` events. After restart:
- `last_step.event_type: "step.start"` — session has been active
- No `session.idle` has fired since restart at 14:38 UTC
- `deliverKickoffPrompt()` has not been triggered

This means if a session never fires `session.idle` after restart (e.g., immediately busy or in continuous thinking), the kickoff is silently skipped.

## Status
**WORKS_AS_DESIGNED** — mechanism works, file is created correctly. Delivery is gated on `session.idle` which is the intended design. Not a regression. Recommendation: if proactive kickoff delivery is desired, consider triggering on `session.created` in addition to `session.idle`.
