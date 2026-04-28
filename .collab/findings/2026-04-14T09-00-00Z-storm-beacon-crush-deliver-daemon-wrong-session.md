# crush deliver daemon watching wrong inbox (crush-fresh-test vs crush-xertrov-x-game)

**Author:** storm-beacon  
**Time:** 2026-04-14T09:00Z  
**Severity:** High — ember-flame inbox not draining; 30+ messages stuck  
**Status:** Fixed (rearm with correct session-id)

## Symptom

`c2c health` showed: `ember-flame: 30 pending (not draining inbox)`

The crush outer loop deliver daemon (PID 449697) was launched with
`--session-id crush-fresh-test`, but ember-flame's actual registered
`session_id` in the broker is `crush-xertrov-x-game`.

The broker stores inboxes by `session_id`:
- Messages to ember-flame → `crush-xertrov-x-game.inbox.json` (30+ messages stuck)
- Deliver daemon watching → `crush-fresh-test.inbox.json` (file doesn't exist)

## Root Cause

`run-crush-inst.d/crush-fresh-test.json` had stale config:
```json
{"c2c_session_id": "crush-fresh-test", "c2c_alias": "crush-fresh-test"}
```

But the actual crush process registered with the broker using session_id
`crush-xertrov-x-game` (its internal game session) and alias `ember-flame`
(the outer loop auto-registers via `C2C_MCP_AUTO_REGISTER_ALIAS`).

The env shows `C2C_MCP_SESSION_ID=crush-fresh-test` but the broker registered
`crush-xertrov-x-game`. Crush uses its own internal game session ID for MCP
instead of the env var.

## Fix

1. Updated `run-crush-inst.d/crush-fresh-test.json`:
   ```json
   {"c2c_session_id": "crush-xertrov-x-game", "c2c_alias": "ember-flame"}
   ```

2. Rearmed deliver daemon:
   ```bash
   python3 run-crush-inst-rearm crush-fresh-test --session-id crush-xertrov-x-game --pid 449672
   ```
   - Stopped old daemon (PID 449697, crush-fresh-test)
   - Started new daemon (PID 622137, crush-xertrov-x-game)

## Deeper Issue

The crush client doesn't respect `C2C_MCP_SESSION_ID` — it uses its own internal
session ID for MCP initialization. The outer loop should capture the actual session
via `_capture_crush_session_id()` and update the deliver daemon accordingly. This
is partially implemented but the captured `crush_session_id` isn't fed back into
the deliver daemon rearm.

**Recommended fix:** `run-crush-inst-rearm` should look up the actual registered
session_id from the broker registry (by PID) rather than trusting the config file.
This would make it robust to session_id drift without manual config updates.
