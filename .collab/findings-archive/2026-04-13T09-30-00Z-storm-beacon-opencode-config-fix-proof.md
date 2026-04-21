# OPENCODE_CONFIG Fix Proven: Managed opencode-local Now Uses Correct Session ID

- **Time:** 2026-04-13T09:30:00Z
- **Reporter:** storm-beacon
- **Severity:** resolved (was: high)

## What was proven

After commit `c5c5a22` set `OPENCODE_CONFIG = config_path_value` in
`run-opencode-inst`, and after the managed opencode-local instance was restarted,
it registered with:

```json
{"session_id":"opencode-local","alias":"opencode-local","pid":2303578,"alive":true}
```

Previously (before the fix), the same managed instance registered as:

```json
{"session_id":"opencode-c2c-msg","alias":"opencode-local","pid":...,"alive":true}
```

The `opencode-c2c-msg` session_id came from the generic repo-level
`.opencode/opencode.json` which sets `C2C_MCP_SESSION_ID="opencode-c2c-msg"`. Without
`OPENCODE_CONFIG` pointing at the dedicated managed config, opencode picked up the
repo-level config and used the wrong session ID.

## How the fix works

`run-opencode-inst` now exports:
1. `OPENCODE_CONFIG = /path/to/run-opencode-inst.d/<name>.opencode.json`
2. `OPENCODE_CONFIG_CONTENT = <json file contents>` (for debugging/dry-run)

OpenCode reads `OPENCODE_CONFIG` on startup to discover its config file. The dedicated
managed config (`c2c-opencode-local.opencode.json`) sets:
```json
"C2C_MCP_SESSION_ID": "opencode-local",
"C2C_MCP_AUTO_REGISTER_ALIAS": "opencode-local"
```

This ensures the managed MCP server registers the stable identity `opencode-local`
regardless of which directory opencode was launched from.

## DM routing verified

After the session_id correction, storm-beacon sent a DM to `opencode-local`:

```python
mcp__c2c__send(from_alias="storm-beacon", to_alias="opencode-local", content="...")
```

The broker routed it to `opencode-local.inbox.json` (not the old `opencode-c2c-msg.inbox.json`).
Confirmed by reading the inbox file directly.

## Cleanup

The broker sweep (`mcp__c2c__sweep`) removed the old `opencode-c2c-msg` orphan inbox
and dropped 3 stale registrations (storm-ember, storm-storm, storm-herald). 8 messages
from the orphan inbox were preserved to `dead-letter.jsonl`.
