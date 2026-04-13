# OpenCode Plugin Live Test Did Not Drain Broker Inbox

- **Discovered by:** codex
- **Discovered at:** 2026-04-13T14:11:40Z / 2026-04-14 00:11 AEST
- **Severity:** medium
- **Status:** open

## Symptom

After `2fda077` landed the OpenCode plugin sidecar config and SQLite relay
server wiring, Codex restarted the managed `opencode-local` process to load
the project plugin, stopped the `c2c_deliver_inbox --notify-only` PTY nudge
daemon, and sent a direct broker-native DM to alias `opencode-local`.

After waiting 20 seconds, Codex had no reply and
`.git/c2c/mcp/opencode-local.inbox.json` still contained the direct DM:

```text
to_aliases=['opencode-local']
from_aliases=['codex']
```

That means the native OpenCode plugin did not drain the broker inbox in this
managed session. The PTY notify daemon was restored afterward with
`python3 run-opencode-inst-rearm c2c-opencode-local --json`.

## How It Was Found

The test intentionally disabled the fallback delivery path that could fake
success:

1. Restarted managed `opencode-local` by terminating process group `2977561`;
   outer loop relaunched it as pid `3232331`.
2. Verified the new process inherited `C2C_MCP_SESSION_ID=opencode-local`,
   `C2C_MCP_CLIENT_PID=3232331`, `C2C_MCP_AUTO_REGISTER_ALIAS=opencode-local`,
   and `C2C_MCP_BROKER_ROOT=/home/xertrov/src/c2c-msg/.git/c2c/mcp`.
3. Ran `run-opencode-inst-rearm` to refresh broker registration and support
   loops.
4. Stopped the notify-only delivery daemon pid `3235262`.
5. Sent a direct broker-native DM via `mcp__c2c__send` to `opencode-local`.
6. Waited 20 seconds, then polled Codex's inbox and counted
   `opencode-local.inbox.json`.

## Likely Root Cause

The managed `opencode run --prompt ...` process may not be loading
project-level `.opencode/plugins/c2c.ts`, or the plugin may be loading but its
background poll is not running in this mode.

Known ambiguity: `run-opencode-inst` sets `OPENCODE_CONFIG` to the dedicated
file `run-opencode-inst.d/c2c-opencode-local.opencode.json` while the plugin
file lives under project `.opencode/plugins/c2c.ts`. It is not yet proven that
OpenCode loads project plugins when a custom config file path is supplied.

## Fix Status

No code fix yet. The reliable PTY notify fallback was restored after the test.

## Suggested Next Checks

- Confirm whether OpenCode logs show the plugin `lifecycle.start` message for
  `c2c`.
- Verify plugin loading with a minimal plugin that only logs/toasts on start.
- If custom `OPENCODE_CONFIG` suppresses project plugin discovery, update
  `run-opencode-inst` or generated config so managed OpenCode instances load
  the plugin directory explicitly.
- Add a plugin-side health marker or broker-visible startup ping so agents can
  tell whether the plugin is running without reading OpenCode transcripts.
