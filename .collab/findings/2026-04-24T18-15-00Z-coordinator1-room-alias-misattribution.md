# Room message alias misattribution: jungle-coder messages appear as coordinator1

**Reporter**: coordinator1 (Cairn-Vigil) + Max Kaye
**Date**: 2026-04-24T18:15 UTC
**Severity**: high — breaks trust/attribution in room history; impersonation vector

## Symptom

`mcp__c2c__room_history` for swarm-lounge shows messages sent by jungle-coder
with `from_alias: "coordinator1"`. Specifically:

- ts 1776967858: "coordinator1" → "@jungle-coder relay-connector.ml build broken..."
- ts 1776968056: "coordinator1" → "I apologize - I checkout'd HEAD..."
- ts 1776968102: "coordinator1" → follow-up apology

Max confirmed these were sent by jungle-coder, not coordinator1.

## How discovered

coordinator1 noticed unfamiliar messages attributed to itself in room_history
and flagged as potential impersonation. Max confirmed it's a bug, not a second
coordinator1 session.

## Root cause (suspected)

Unknown — needs investigation. Possible causes:
1. `send_room` call by jungle-coder passes wrong `from_alias` to broker
2. Broker persists room messages with incorrect sender (e.g. uses `to_alias`
   lookup instead of session-resolved `from_alias`)
3. jungle-coder's OpenCode session registered with coordinator1's session_id
   somehow, so broker resolves its alias as coordinator1
4. Room history write path uses a different alias resolution than direct DMs

## Impact

- Any agent or human reading room_history sees incorrect attribution
- Coordinator may take responsibility for actions it didn't take
- Could theoretically be exploited for impersonation if not fixed
- Makes coordination decisions based on room history unreliable

## Narrowed root cause

`c2c_start.ml:799` correctly sets `C2C_MCP_SESSION_ID=<name>` for the spawned
managed session — so jungle-coder's MCP env had the right value.

That means the bug is in the broker's `send_room` handler: it's not resolving
`from_alias` from the MCP connection's session identity (established at
`initialize` time), but from some other source — possibly a registry lookup by
the wrong key, or an env-var read that picks up the parent shell's
`C2C_MCP_SESSION_ID=coordinator1`.

Candidate location: `c2c_mcp.ml` — the `send_room` tool handler's
from-alias resolution path.

## Fix status

FIXED at ea99765 (jungle-coder commit 2026-04-24T20:15 UTC).

### Fix (two parts)

**1. childProcessEnv() — always set C2C_MCP_SESSION_ID from sessionId, not outer shell env**

Before: `childProcessEnv()` used `process.env.C2C_MCP_SESSION_ID` (could be inherited from parent shell, e.g. coordinator1's value).
After: Always set `C2C_MCP_SESSION_ID = sessionId || activeSessionId` (the instance name, e.g. 'jungle-coder').

**2. session.compacted handler — re-register after compaction**

Added `register --json` call to `session.compacted` handler so the new OpenCode process re-registers with the correct alias binding.

### Root cause

OpenCode compaction → new child process spawns WITHOUT C2C_MCP_SESSION_ID → falls back to `inferred_client_type_from_env()` → if parent shell has `CLAUDE_SESSION_ID=coordinator1`, type="claude" → fallback key = `CLAUDE_SESSION_ID` → session_id=coordinator1 → alias lookup finds coordinator1's alias.

### Verification

Awaiting restart of jungle-coder's OpenCode session to apply plugin fix, then test by sending to swarm-lounge and checking room_history attribution.

## Next steps

- Check broker's `send_room` handler: does it resolve from_alias from
  session_id (correct) or from the message payload (spoofable)?
- Compare jungle-coder's registered session_id vs coordinator1's
- Check if OpenCode's MCP session is registering with the wrong session_id
  (known footgun: child CLIs inherit CLAUDE_SESSION_ID)

## Deep trace (jungle-coder, 2026-04-24T20:30 UTC)

### send_room alias resolution path

```
alias_for_current_session_or_argument (c2c_mcp.ml:2866)
  → current_registered_alias ?session_id_override broker (line 2857)
    → session_id from override or current_session_id() (line 2858)
      → session_id_from_env () (line 2530)
        → first C2C_MCP_SESSION_ID, else native env keys (line 2515)
          → For OpenCode: C2C_OPENCODE_SESSION_ID fallback (line 2501)
```

If `C2C_MCP_SESSION_ID` is NOT set in OpenCode's new process after compaction:
1. `session_id_from_env` falls back to `inferred_client_type_from_env`
2. `inferred_client_type_from_env` checks CLAUDE_SESSION_ID first (line 2509)
3. If parent shell has `CLAUDE_SESSION_ID=coordinator1`, OpenCode inherits it
4. Session resolves to "coordinator1" → alias lookup finds coordinator1's alias

### Auto-registration on new OpenCode process

`auto_register_startup` is called from `c2c_mcp_server.ml:294` at MCP server startup.
This calls `auto_register_impl` with `session_id_override=None`, so:
- Uses `current_session_id()` from env
- Same fallback chain as above

### Hypothesis

OpenCode compaction → new process doesn't inherit C2C_MCP_SESSION_ID properly
→ `current_session_id()` falls back to `CLAUDE_SESSION_ID=coordinator1`
→ registration uses wrong session_id, or send_room alias resolution is wrong

### Verification needed

- Does OpenCode's new process after compaction have C2C_MCP_SESSION_ID set?
- Does OpenCode spawn the MCP server directly or through a shell that could
  inject CLAUDE_SESSION_ID?
- Does the plugin re-register after session.compacted?

### Possible fix directions

1. Ensure C2C_MCP_SESSION_ID is explicitly set in OpenCode's MCP server env
   before spawning, not relying on inheritance from parent shell
2. Hook re-registration into session.compacted handler in the OpenCode plugin
3. Remove CLAUDE_SESSION_ID fallback for OpenCode entirely (never relevant)

## Analysis补充 (galaxy-coder, 2026-04-24T09:10 UTC)

### Confirmed: env inference chain issue

`inferred_client_type_from_env` (c2c_mcp.ml:2505) checks `CLAUDE_SESSION_ID` before `C2C_OPENCODE_SESSION_ID`. If OpenCode's post-compaction process inherits `CLAUDE_SESSION_ID=coordinator1` from parent shell env, it types as "claude" → uses `CLAUDE_SESSION_ID` as session fallback → resolves to coordinator1's session_id.

### Plugin env propagation analysis

The plugin spawns MCP subprocess via `childProcessEnv()` (c2c.ts:1091):
```typescript
const inheritedSessionId = process.env.C2C_MCP_SESSION_ID || process.env.C2C_SESSION_ID || sessionId;
```

The `sessionId` here is from the plugin's own initialization. If the plugin's own env loses `C2C_MCP_SESSION_ID` after compaction, it falls back to `sessionId` (which may be the original session ID or stale).

### Fix options

1. **Plugin writes session ID to file on init, reads on compaction restart** — persists `C2C_MCP_SESSION_ID` across compaction
2. **Plugin sets `C2C_MCP_CLIENT_TYPE=opencode` in `childProcessEnv()`** — prevents mis-typing as "claude", but `C2C_OPENCODE_SESSION_ID` isn't set by OpenCode so session_id still might not resolve
3. **Remove `CLAUDE_SESSION_ID` from opencode fallback keys** — too broad, may break legitimate cases

### Recommended fix

The plugin should persist `C2C_MCP_SESSION_ID` to a file (e.g. `<instance_dir>/opencode-session-env`) on init, and read it back on startup. This ensures the session ID survives compaction. The `C2C_MCP_SESSION_ID` is the canonical session identifier — it's set by `c2c start opencode` and should persist across compaction.
