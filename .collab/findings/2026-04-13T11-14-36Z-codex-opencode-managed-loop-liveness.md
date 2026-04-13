# OpenCode Managed Loop Liveness Split

## Symptom

`mcp__c2c__send(from_alias="codex", to_alias="opencode-local", ...)` failed with:

```text
Invalid_argument("recipient is not alive: opencode-local")
```

At the same time, an OpenCode TUI for the target session was alive on `pts/22`.
This means the operator-visible OpenCode agent existed, but the broker-native
direct-send route rejected `opencode-local` because the broker row pointed at a
dead process.

## Discovery

The broker row showed a stale dead worker:

```text
alias=opencode-local
session_id=opencode-local
pid=2676994
alive=false
last_seen=4m ago
```

The durable TUI was separate and alive:

```text
2662572 pts/22 node /home/xertrov/.bun/bin/opencode -s ses_283b6f0daffe4Z0L0avo1Jo6ox
2662579 pts/22 /home/xertrov/.bun/install/global/node_modules/opencode-ai/bin/.opencode -s ses_283b6f0daffe4Z0L0avo1Jo6ox
```

The managed receiver loop was also alive, but not injectable because it had no
TTY:

```text
2663807 ? python3 ./run-opencode-inst-outer c2c-opencode-local --fork
2663808 ? node /home/xertrov/.bun/bin/opencode run --session ses_283b6f0daffe4Z0L0avo1Jo6ox --fork ...
2663815 ? /home/xertrov/.bun/install/global/node_modules/opencode-ai/bin/.opencode run --session ses_283b6f0daffe4Z0L0avo1Jo6ox --fork ...
```

`./c2c inject --pid 2663815 --client opencode --dry-run` failed with:

```text
RuntimeError: pid 2663815 has no /dev/pts/* on fds 0/1/2
```

The support loop logs already contain repeated versions of the same preflight
failure:

```text
skipping OpenCode support loops for c2c-opencode-local: pid <pid> has no /dev/pts/* on fds 0/1/2
```

As a fallback notification only, I successfully injected the report pointer into
the durable TUI process on `pts/22` with a 2.5s submit delay. That PTY delivery
is not broker-native proof; it was only used because the direct broker send was
rejected by stale liveness metadata.

## Root Cause

There are two OpenCode execution modes sharing the same conceptual identity:

1. A durable interactive TUI attached to `pts/22`.
2. A managed `opencode run --session ... --fork` loop with no TTY.

The broker registration can drift to the short-lived/no-TTY managed worker
instead of the durable TUI. When that worker exits, direct sends correctly fail
as `recipient is not alive`, even though the durable TUI is still running and
could receive a PTY wake.

The no-TTY managed worker can still poll while alive, so synchronized one-shot
proofs work, but it is not a stable always-addressable receiver. It also cannot
run the usual PTY notify/poker helpers because there is no terminal to inject.

## Fix Status

Not fixed by this finding. Existing fixes reduced identity collisions, but this
current live state proves the managed receiver loop can still leave
`opencode-local` non-sendable between worker lifetimes.

Recommended follow-ups:

- Make one stable process own `opencode-local`. If the durable TUI is the target,
  expose a safe `c2c refresh-peer opencode-local --pid <tui-child-pid>` style
  operator command instead of relying on Python helper imports.
- If the managed no-TTY loop is the target, do not treat it like a PTY-wakeable
  client. Prefer a broker queue model where sends can land while the worker is
  offline, or keep a persistent MCP-capable worker alive.
- Make `run-opencode-inst-outer` optionally stop after one successful inbox
  drain, or add a bounded/daemon mode that does not keep re-registering the
  durable alias to short-lived workers.
- Keep PTY nudges notify-only for proofs. The report pointer sent to the TUI was
  an operator fallback, not evidence for broker-native content delivery.

## Severity

High for autonomous OpenCode collaboration. The direct DM route works when the
OpenCode worker is alive and correctly registered, but the alias is not reliably
sendable across restarts or between managed-loop iterations.
