# OpenCode Password-Game Delivery Needed Notify-Only Wakeups

- **Time:** 2026-04-13T07:23:02Z
- **Reporter:** codex
- **Severity:** high for broker-native OpenCode DM proof

## Symptom

Direct broker sends to `opencode-local` queued correctly, but the live OpenCode
TUI did not receive them passively. A content-draining PTY delivery loop could
wake OpenCode, but that made the visible message look like
`source="pty" source_tool="c2c_poker"` and moved the message body through PTY
instead of through `mcp__c2c__poll_inbox`.

That violated the password-game requirement: PTY may wake the agent, but the
password request content must arrive through broker-native direct messaging.

## Root Cause

`c2c_deliver_inbox.py` had only one active delivery mode:

1. drain the inbox;
2. wrap each broker message body in a C2C envelope;
3. inject the full content into the target PTY.

That is useful for humans and for clients without MCP, but it is the wrong
mode for proving MCP/broker-native receipt in OpenCode. OpenCode needed a
minimal PTY nudge that leaves inbox content untouched so the model calls
`poll_inbox` itself.

While wiring managed OpenCode support, another lifecycle bug surfaced:
`run-opencode-inst` `pre_exec` is too early for rearming support loops because
it can run before the process has execed into OpenCode and before its terminal
fds are visible.

## Fix Status

Implemented locally:

- `c2c_deliver_inbox.py --notify-only` peeks the inbox and injects only a
  content-free `poll_inbox` nudge.
- Notify-only loops leave broker inbox JSON untouched.
- Notify-only loops debounce repeated nudges for the same message set, but
  re-notify immediately when the queued inbox signature changes.
- `run-opencode-inst-rearm` starts OpenCode support loops in notify-only mode.
- `run-opencode-inst-outer` now owns rearming after spawning the inner
  OpenCode process, instead of relying on too-early `pre_exec`.

## Verification

- Focused notify-only and OpenCode rearm tests pass.
- A live notify-only rearm against TUI pid `1337045` succeeded and started
  both delivery and poker loops.
- After notify-only wakeup, `opencode-local.inbox.json` was drained by
  OpenCode itself, confirming the content path was broker poll rather than PTY
  content injection.

## Residual Risk

`opencode-local` confirmed broker-native receipt but still did not provide a
password. It either lacks the game secret in its active context or its reply
path is not reliably sending direct DMs to alias `codex`. That is now separate
from the receive-side delivery mechanism.
