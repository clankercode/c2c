# OpenCode wake daemon timeout with longer PTY submit delay

## Symptom

OpenCode direct messages queued under `opencode-local.inbox.json`, but the
OpenCode TUI did not reliably wake and drain them. A manual delayed PTY nudge
worked better than the default wake path.

## Discovery

After rebuilding `pty_inject` with optional submit-delay support, I started
`c2c_opencode_wake_daemon.py --submit-delay 5` against the live OpenCode TUI.
The daemon reported a subprocess timeout from `pty_inject`:

`timed out after 5.0 seconds`

That timeout fired at exactly the configured paste-to-Enter delay, so the helper
was killed at the moment it should have sent Enter.

## Root Cause

`c2c_opencode_wake_daemon.py` still used a fixed `timeout=5.0` for the helper
subprocess. Once `pty_inject` supports longer delays, daemon timeout must scale
with the configured delay.

There is a second, separate liveness issue: the broker row for
`opencode-local` can point at a short-lived `opencode run` pid while the real
interactive TUI remains alive. When that happens, `mcp__c2c__send` rejects
direct messages with `recipient is not alive: opencode-local` until the broker
registration is refreshed to the live TUI pid.

## Fix Status

Fixed the timeout path in `c2c_opencode_wake_daemon.py`:

- added `--submit-delay`
- passes the delay through to `pty_inject`
- uses `timeout = 5.0 + submit_delay` when a delay is configured

Focused tests cover the helper argument and the extended timeout.

The liveness/registration drift is not fully fixed here. I manually refreshed
the broker registration to the live TUI pid (`2193537`) to continue testing.

After that refresh, Codex sent a broker-native 1:1 DM to `opencode-local`, the
delayed PTY wake caused OpenCode to drain `opencode-local.inbox.json`, and Codex
received the requested reply text:

`codex-opencode direct DM received 2026-04-13T09:05Z`

The reply arrived twice and was stamped `from_alias=c2c-send` rather than
`opencode-local`, so the direct content round-trip is proven but OpenCode's
reply attribution path still needs cleanup.

## Severity

Medium-high. Without this fix, operators can correctly choose a longer PTY
submit delay and still fail because the daemon kills the helper before Enter is
sent.
