# OpenCode DM Handoff Footguns

## Symptom

While sending `opencode-local` a direct restart-report summary, the first native
MCP `mcp__c2c__send(from_alias="codex", to_alias="opencode-local", ...)` failed
with:

```text
Invalid_argument("recipient is not alive: opencode-local")
```

Seconds earlier, `./c2c list --broker --json` had shown `opencode-local` alive.
The failed send blocked a normal broker-native DM even though a durable OpenCode
TUI was still running and capable of polling.

In the same pass, calling `mcp__c2c__register` with no arguments produced:

```text
Yojson__Safe.Util.Type_error("Expected string, got null", ...)
```

Passing `{"alias":"codex"}` to the same tool worked and refreshed the `codex`
registration.

## Discovery

The broker row for `opencode-local` had drifted to a dead one-shot `opencode run`
pid. A separate durable TUI remained alive:

```text
node /home/xertrov/.bun/bin/opencode -s ses_283b6f0daffe4Z0L0avo1Jo6ox
`- /home/xertrov/.bun/install/global/node_modules/opencode-ai/bin/.opencode -s ses_283b6f0daffe4Z0L0avo1Jo6ox
```

After manually refreshing the broker row to the durable `.opencode` child pid via
the existing `c2c_mcp.maybe_auto_register_startup()` helper, the same native MCP
send queued successfully.

OpenCode later drained the exact queued direct message via `mcp__c2c__poll_inbox`
and replied 1:1 to `codex`, confirming the content path was broker-native and
not PTY-injected.

## Root Cause

Two separate issues showed up:

1. The host-exposed `mcp__c2c__register` schema still appears no-arg in this
   Codex session, but the server implementation expects an alias string. This
   makes the intuitive no-arg refresh path fail with an OCaml JSON type error.
2. `opencode-local` registration can still drift to a dead one-shot process,
   while the durable TUI process remains alive. The send path correctly rejects
   the dead row, but there is no obvious operator command to say "refresh this
   alias to the durable live OpenCode TUI pid" without importing Python helpers.

## Workaround Used

```bash
C2C_MCP_SESSION_ID=opencode-local \
C2C_MCP_AUTO_REGISTER_ALIAS=opencode-local \
C2C_MCP_CLIENT_PID=<durable-.opencode-pid> \
C2C_MCP_BROKER_ROOT=/home/xertrov/src/c2c-msg/.git/c2c/mcp \
python3 - <<'PY'
import os
import c2c_mcp
c2c_mcp.maybe_auto_register_startup(dict(os.environ))
PY
```

Then:

1. Send the real content with native `mcp__c2c__send`.
2. Use PTY injection only as a nudge:

```bash
./c2c inject --pid <opencode-tui-pid> --client opencode --submit-delay 2.5 \
  "Poll your C2C inbox now with mcp__c2c__poll_inbox; a broker-native direct message from codex is queued. This PTY nudge contains no DM body."
```

The longer submit delay worked; OpenCode drained the broker inbox and replied.

## Fix Status

Not fixed in code by this note.

Recommended follow-ups:

- Fix the MCP `register` tool schema or handler contract so the exposed tool
  shape matches reality. If alias is required, advertise it. If no-arg refresh
  is desired, default to the current identity.
- Add an operator-facing refresh command, for example
  `c2c refresh-peer opencode-local --pid <pid>` or make `c2c setup opencode`
  expose a safe re-registration path for durable TUI pids.
- Keep testing OpenCode direct DMs against the durable TUI row, not only
  one-shot `opencode run` rows.

## Severity

Medium-high for live collaboration. The broker-native DM path works, but stale
OpenCode liveness metadata turns a working route into `recipient is not alive`
until an agent knows the manual refresh incantation.
