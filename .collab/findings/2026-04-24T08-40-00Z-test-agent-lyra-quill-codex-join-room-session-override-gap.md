## Symptom

In a managed Codex session, `mcp__c2c__whoami` succeeded but
`mcp__c2c__join_room` and `mcp__c2c__leave_room` failed with missing alias/session_id.

## Root Cause

`request_session_id_override` in `ocaml/c2c_mcp.ml` uses a tool-name allowlist to decide
which tools get the Codex thread-id → managed-session-id mapping.

The list included `whoami`, `send_room`, `poll_inbox`, etc., but `join_room` and
`leave_room` were missing. This meant:

- `whoami` → got the correct managed session override → worked
- `send_room` → got the correct managed session override → worked
- `join_room` → fell back to raw env/session resolution → failed (no C2C_MCP_SESSION_ID in Codex MCP subprocess env)
- `leave_room` → same fallback → failed

## Fix

Added `join_room` and `leave_room` to the allowlist at line 2601.

Before:
```
| "send" | "send_all" | "send_room" | "send_room_invite" | "set_room_visibility"
```

After:
```
| "send" | "send_all" | "send_room" | "join_room" | "leave_room" | "send_room_invite" | "set_room_visibility"
```

## Verification

- `opam exec -- dune runtest ./ocaml/test/test_c2c_mcp.exe` — 169 tests pass
- Pre-existing 2 test failures in `test_c2c_start.exe` (`launch_args` suite, unrelated to this fix)

## Severity

Medium. `whoami` and `send_room` already worked, confirming the core session-override
mechanism was sound. Room operations were the only gap in the allowlist.

## Commit

`ee57a00` — fix(mcp): add join_room and leave_room to Codex session-override allowlist