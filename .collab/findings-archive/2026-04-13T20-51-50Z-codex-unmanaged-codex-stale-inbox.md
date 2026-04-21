# Unmanaged Codex TUI Does Not Drain Broker Inbox After Notify-Only PTY Nudge

## Symptom

`c2c verify --broker --alive-only` showed the swarm at 4/5 `goal_met`, blocked
only on `codex-aalto`:

- `codex-aalto`: `sent=3`, `received=6`
- `c2c health --json` reported `codex-xertrov-x-game` / `codex-aalto` with
  19 pending inbox messages.

The process was alive (`pid=4135019`) and attached to `/dev/pts/91`, but no
managed `run-codex-inst-outer` loop was visible for that session.

## Discovery

On the 2026-04-14 06:50 AEST heartbeat, Codex drained its own inbox, ran:

```bash
./c2c verify --broker --alive-only
./c2c health --json
```

Health showed `codex-aalto` as stale with 19 pending messages. Inspecting
`/proc/4135019` showed a live Codex TUI in `/home/xertrov/src/c2c-msg` with
stdin/stdout/stderr on `/dev/pts/91`, but its environment did not include
`C2C_MCP_SESSION_ID`, `C2C_MCP_AUTO_REGISTER_ALIAS`, or managed harness vars.

## Attempted Mitigation

Codex sent a notify-only PTY nudge:

```bash
./c2c inject --pid 4135019 --client codex --event notify \
  --from c2c-deliver-inbox --alias codex-xertrov-x-game \
  --submit-delay 1.0 \
  '19 broker-native C2C messages are queued for session codex-xertrov-x-game / alias codex-aalto. ...'
```

The injection reported `ok: true`, but after an 8 second wait:

- `codex-aalto` remained at `sent=3 received=6`
- `c2c health --json` still showed 19 pending messages for
  `codex-xertrov-x-game`

## Follow-up

The PTY wake did eventually work. A later inbox drain received broker-native
messages from `codex-aalto`, and `c2c health --json` no longer reported
`codex-xertrov-x-game` as a stale inbox. The next broker verification showed:

```text
codex-aalto: sent=11 received=26 status=in_progress
```

So the first post-injection check was too short or the target Codex session
needed additional time to process the injected prompt. The issue is narrower
than "PTY notify does not work"; it is "unmanaged Codex notify lacks a reliable
readiness/ack path and can look failed if checked too quickly."

## Root Cause

Likely root cause: `codex-aalto` is an unmanaged Codex TUI. It is alive and
registered, but it lacks the managed harness delivery loop and visible C2C MCP
environment. A PTY nudge can wake it, but the sender has no reliable ack beyond
watching broker archives and stale-inbox counts.

This is distinct from managed `codex-local`, where `run-codex-inst-outer` keeps
`c2c_deliver_inbox.py --notify-only --loop` and `c2c_poker.py` running.

## Severity

Medium for dogfooding and group-goal accounting:

- Broker routing works: messages queue correctly.
- Delivery/read side is weak for unmanaged Codex sessions.
- The new stale-inbox health check surfaces the issue, but there is no automatic
  remediation path for unmanaged Codex yet.

## Fix Status

Partially mitigated live by notify-only PTY injection. Open for productization.

Potential fixes:

- Make `c2c setup codex` / `c2c restart-me` clearer for unmanaged Codex sessions
  that are registered but not running a delivery daemon.
- Add a `c2c codex-wake` or generalized `c2c wake-peer ALIAS` helper that can
  resolve alias -> session -> pid/pts and retry notify-only injection with
  client-specific delay.
- Consider making `c2c health` offer an actionable command when it finds a stale
  inbox for an alive Codex process.
