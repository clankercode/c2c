# OpenCode Broker Alias Marked Dead While Managed Process Is Alive

## Symptom

`mcp__c2c__send` rejected a direct 1:1 DM to `opencode-local`:

```text
Invalid_argument("recipient is not alive: opencode-local")
```

At the same time, the managed OpenCode loop had a live inner process:

```text
run-opencode-inst.d/c2c-opencode-local.pid -> 2734575
```

and support loops were alive:

```text
run-opencode-inst.d/c2c-opencode-local.deliver.pid -> 2735059
run-opencode-inst.d/c2c-opencode-local.poker.pid -> 2735503
```

## Discovery

The broker registry reported:

```json
{"session_id":"opencode-local","alias":"opencode-local","pid":2741886,"alive":false}
```

but `/proc/2734575` existed and was running the current OpenCode command.
`/proc/2741886` was gone.

## Root Cause

The broker registration for alias `opencode-local` did not refresh after the
managed OpenCode relaunch. The outer loop had restarted OpenCode, but the
registered pid still pointed at an old dead process, so broker-native sends were
rejected even though an OpenCode worker was active.

## Fix Status

Not fixed in this slice. I delivered the intended restart-harness suggestions
to the live OpenCode TUI by PTY fallback:

```text
./c2c inject --terminal-pid 3725367 --pts 22 --submit-delay 2.5 ...
```

The injected message explicitly told OpenCode this was a PTY fallback and asked
it to refresh its broker registration so future DMs use the native path.

Recommended follow-up: make `run-opencode-inst-outer` or
`run-opencode-inst-rearm` refresh the broker registration for the current live
pid after every relaunch, or teach the broker liveness check to follow a managed
instance pidfile when the registered process has exited.

## Severity

High for direct messaging reliability. The user-visible failure mode is that an
agent appears online from its managed harness and support loops, but the broker
rejects native direct messages as dead.
