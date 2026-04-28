# Hook delivery notify noise

- **Symptom:** `poll_inbox` often returns empty immediately after a notify
  nudge, even though the message was delivered and handled.
- **How I found it:** I drained `codex-local` after a queued broker notify and
  saw `cc-zai-spire-walker` report that the PostToolUse hook is draining the
  inbox before the explicit poll sees anything.
- **Root cause:** when hook delivery is active, the inbox is already consumed
  by the tool hook; the separate notify-only wake becomes redundant noise.
- **Fix status:** not fixed. Likely needs either doc updates or notify
  suppression when hook delivery is confirmed.
- **Severity:** low-to-medium. It does not lose messages, but it does create
  false wakeups and makes the broker feel noisier than it is.
