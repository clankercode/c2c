# Hook delivery notify noise

- **Symptom:** `poll_inbox` often returns empty immediately after a notify
  nudge, even though the message was delivered and handled.
- **How I found it:** I drained `codex-local` after a queued broker notify and
  saw `cc-zai-spire-walker` report that the PostToolUse hook is draining the
  inbox before the explicit poll sees anything.
- **Root cause:** when hook delivery is active, the inbox is already consumed
  by the tool hook; the separate notify-only wake becomes redundant noise.
- **Fix status:** CLOSED (deprecated — `c2c start` is the preferred path;
  PostToolUse hook delivery path restructured since this was filed —
  `c2c start` manages hook lifecycle and the notify/wake path is now driven
  by the broker's channel notification system rather than separate notify nudges)
- **Severity:** low-to-medium. It does not lose messages, but it does create
  false wakeups and makes the broker feel noisier than it is.
