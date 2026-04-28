# #310: Four-client mesh test failures — Findings Log

## Date: 2026-04-27
## Agent: test-agent

## Problem
`test_four_client_mesh.py::test_mesh_all_6_ordered_pairs` consistently failed —
bob→carol, bob→dave, carol→dave messages not received by recipients.

## Root Causes Found

### Root Cause #1 (Fixed in prior commits): Docker cross-container PID liveness
Containers can't reach host `/proc/<pid>` for other containers (PID namespace
isolation). Fixed via file-based lease system (`touch_session`/`check_lease`).

### Root Cause #2 (Fixed in prior commits): `utimes` can't create files
On overlayfs (Docker's filesystem), `utimes` failed with ENOENT when the
file didn't exist. Fixed via `openfile+O_CREAT` then `utimes` to set mtime.

### Root Cause #3 (Fixed in prior commits): `Broker.register` didn't touch Docker lease
CLI `c2c register` calls `Broker.register` directly (not via MCP server's
`handle_tool_call`), so Docker lease was never created. Fixed by inlining
lease-touch logic in `Broker.register`.

### Root Cause #4 (Fixed in prior commits): TTL too short
60s TTL expired during mesh test (~2min). Fixed to 300s.

### Root Cause #5 (Identified, NOT the actual breaking cause): `resolve_alias` session_id lookup
Initial hypothesis was that `from_alias=peer-b-*` (container alias, wrong) instead
of `bob-*` (correct sender alias) caused delivery failures. In the mesh test
containers, `C2C_MCP_SESSION_ID` is set, but `session_id_from_env` returns None
(because it checks `C2C_MCP_SESSION_ID` first, which IS set — but due to a
code path issue that was later understood to not be the actual failure mode).

### Actual Root Cause #6 (THE REAL FIX): Test structure — poll_inbox drains inbox
The test did ALL sends first, then ALL polls. Since `poll_inbox` **drains**
the inbox on read, when carol polled for alice→carol (first), she drained her
own inbox. When bob→carol was sent afterward, carol's inbox was empty — she had
no way to receive it because the inbox was already drained.

**Fix**: Interleave send and poll per pair so each recipient polls immediately
after their message is sent.

## Debug Infrastructure Added
- `Printf.eprintf "[DEBUG ...]"` printfs gated behind `C2C_MCP_DEBUG` env var
- Guard: `let debug_enabled = match Sys.getenv_opt "C2C_MCP_DEBUG" with ...`
- Applied to: `c2c_mcp.ml` (save_inbox, load_inbox, enqueue, resolve,
  load_registrations, session_id_from_env) and `c2c.ml` (env_session_id,
  resolve_alias, resolve_sid_for_inbox, send_cmd)

## Debug Pollution Incident
Uncommitted debug printfs in `c2c_mcp.ml` were accidentally installed to
`~/.local/bin/c2c` via `just install-all` from the worktree. These polluted
the globally-shared binary seen by stanza-coder's session. **Lesson learned**:
gate all debug output behind `C2C_MCP_DEBUG` before committing.

## Test Changes
- `docker-tests/test_four_client_mesh.py`: changed from all-sends-then-all-polls
  to interleaved send-per-pair-then-poll to match the draining semantics of
  `poll_inbox`.
- `Dockerfile.test`: reverted cache-busting `rm -rf _build` additions (not needed
  once binary was fresh).

## Files Changed
- `ocaml/c2c_mcp.ml`: debug gating + Docker lease fixes (prior commits)
- `ocaml/cli/c2c.ml`: debug gating + Docker lease fixes (prior commits)
- `docker-tests/test_four_client_mesh.py`: interleaved send/poll fix (this slice)
- `Dockerfile.test`: reverted (prior changes)

## Status
- `test_mesh_all_6_ordered_pairs`: **PASSING** (was failing)
- `test_concurrent_registration_mesh`: **PASSING** (was passing)
- `test_two_container_dm_*`: all **PASSING**
- `test_concurrent_registration`: **PASSING**

## Peer Review Notes (jungle-coder, e7a47a38)
- Non-blocking: trailing space in enqueue_message debug string (parser-resolved, cosmetic)
- Non-blocking: `resolve_live_session_id_by_alias` self-heal fold removal is intentional — Docker mode cannot use /proc-based self-heal; file-based lease is the only self-heal path in that mode
- Core bug genuinely fixed; all 6 Docker tests pass

## Trailing-Space Fix
Line 1427 in c2c_mcp.ml has a trailing space in the debug string. Should be cleaned up.

## Key Insight
`poll_inbox` is a **draining** read — it removes messages from the inbox.
This is fundamental to how the broker works (per-message exactly-once delivery).
Tests must account for this by polling immediately after the message is sent,
or by having recipients poll before senders send.
