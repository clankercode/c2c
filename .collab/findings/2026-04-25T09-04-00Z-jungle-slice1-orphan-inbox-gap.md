# Slice 1 Orphan Inbox Gap (Restart Redesign)

**Author**: jungle-coder  
**Date**: 2026-04-25  
**Status**: Known gap, deferred to Slice 3

## Gap

Direction B restart has a brief window between outer exit and new start registration:

1. Old outer exits (lock released)
2. New `c2c start` exec'd but not yet registered
3. Any messages for this session go to orphan inbox → dead-letter on next sweep

## Mitigation

Spec says: "After restart, the new outer should check for any orphan inbox content 
from the previous session and replay it."

The orphan inbox path for a session `<sid>` is:
```
<broker_root>/mcp/<sid>.inbox.json
```

## What's Needed (Slice 3)

After the new outer registers with the broker, check for orphan inbox entries 
for `resume_session_id` and drain/replay them before normal operation begins.

This is the same Class F interaction noted in the spec. Slice 3 should:
1. Add `--orphan-replay` flag to `c2c restart`  
2. After re-registration, call `poll_inbox` for the orphan session
3. Forward any messages to the new registration

## Severity

Medium — messages would be delayed (not lost) since orphan inbox is appended 
before sweep, and re-registration replay is available via `c2c dead-letter --replay`.

## Slice 3 (Orphan Inbox Replay + --timeout flag)

### Scope

1. **Orphan inbox replay**: After `cmd_restart` execs new `c2c start`, the new outer should check for orphan inbox content at `<broker_root>/mcp/<resume_session_id>.inbox.json` and drain/replay it to the new registration before normal operation.

2. **`--timeout` CLI flag for `c2c restart`**: Add `?timeout:float` optional arg to the `restart` command in `c2c.ml`, passed through to `cmd_restart`. Default 5s.

3. **Smoke test for restart**: Add a test that verifies the restart flow works end-to-end with a mock instance.

### Implementation notes

- Orphan inbox path: `<broker_root>/mcp/<resume_session_id>.inbox.json`
- After re-registration (when the new outer loop calls `build_env` which registers), poll the orphan inbox and handle any messages
- The `C2C_MCP_INBOX_WATCHER_DELAY` mechanism should handle delivery naturally once the new session is registered

### Priority

Medium — messages are delayed not lost; manual `c2c dead-letter --replay` is a workaround.
