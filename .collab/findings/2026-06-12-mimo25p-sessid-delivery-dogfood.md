# Session-ID Delivery Dogfood — mimo25p

**Date**: 2026-06-12T05:30Z
**Binary**: `~/.local/bin/c2c` v0.8.0 (97a81138)
**Session**: mimo25p sessid-delivery dogfood
**Synthetic names**: `bakeoff-mimo-sessid-{sender,target,other,clitest}`

---

## Health Verdict

**E2E YES**: `c2c send --session <sid>` → global inbox → `c2c-inbox-hook-ocaml` → `hookSpecificOutput.additionalContext` with message envelope — **WORKS END-TO-END**.

| Surface | Verdict |
|---------|---------|
| (A) `c2c sessions` | ✅ WORKS — minor JSON/schema mismatches |
| (B) `c2c send --session` | ✅ WORKS — core feature solid, validation tight |
| (C) inbox-hook-ocaml | ✅ WORKS — drain+render correct, failsafe too quiet |
| (D) Silent-send warnings | ✅ WORKS — one misleading warning for solo-member rooms |
| (E) `c2c rooms my-rooms` | ✅ WORKS — no issues found |

---

## Issues Found

### Issue 1 — sessions --json missing `role` field (table has ROLE column)
- **Surface**: A
- **Severity**: Sev3
- **Symptom**: `c2c sessions` table has 6 columns: SESSION_ID, ALIAS, CLIENT, STATE, CWD, ROLE. But `--json` output only has 5 keys: `session_id`, `alias`, `client_type`, `cwd`, `alive`. No `role` field.
- **Command**:
  ```
  $ c2c sessions
    SESSION_ID                           ALIAS       CLIENT  STATE  CWD   ROLE
    ...
  $ c2c sessions --json
    [{"session_id":"...","alias":"...","client_type":null,"cwd":null,"alive":false}]
  ```
- **Root cause**: JSON serialization doesn't include `role` field from registration. The table maps `alive` → STATE column but ROLE column has no JSON counterpart.
- **Suggested fix**: Add `"role"` key to the sessions JSON output. Consider renaming `alive` to `state` for column consistency, or add both `alive` (bool) and `state` (string: "alive"/"dead"/"?").

### Issue 2 — CLIENT column always "?" for CLI-registered sessions
- **Surface**: A
- **Severity**: Sev3
- **Symptom**: All sessions show `?` in CLIENT column. `client_type` is `null` in JSON.
- **Command**:
  ```
  $ c2c sessions
    bakeoff-mimo-sessid-sender-001  bakeoff-mimo-sessid… ? alive -
  ```
- **Root cause**: `c2c register` doesn't set `client_type` — only managed sessions via `c2c start` populate it. CLI-registered sessions have no client type.
- **Suggested fix**: Either auto-detect client type from env (e.g., `C2C_CLIENT_TYPE`) or show "cli" as default for non-managed sessions. Showing "?" is confusing — "-" or "cli" would be clearer.

### Issue 3 — STATE "?" for sessions with null alive status
- **Surface**: A
- **Severity**: Sev3
- **Symptom**: `bakeoff-mm27-session-1781199517` shows `?` in STATE column. JSON shows `"alive": null`.
- **Root cause**: Some registrations lack `pid`/`pid_start_time` (e.g., older entries), so liveness check returns `null` instead of `true`/`false`.
- **Suggested fix**: Map `null` → "unknown" in the table, not "?". Consider adding a `state` string field to JSON for clarity.

### Issue 4 — `send --session` defaults from_alias to "c2c-cli" even from registered session
- **Surface**: B
- **Severity**: Sev3
- **Symptom**: When running `c2c send --session <sid> "msg"` from a registered session (with `C2C_MCP_SESSION_ID` set), the `from_alias` is always "c2c-cli", not the session's registered alias.
- **Command**:
  ```
  $ C2C_MCP_SESSION_ID=bakeoff-mimo-sessid-sender-001 c2c send --session target-001 "test" --json
    {"from_alias":"c2c-cli","target_session_id":"target-001",...}
  ```
- **Root cause**: `--session` path doesn't resolve caller alias from session registration; falls back to "c2c-cli" default.
- **Suggested fix**: When `C2C_MCP_SESSION_ID` is set and `--from` is not, resolve the caller's alias from registration and use it as `from_alias`. This makes session-to-session sends traceable.

### Issue 5 — inbox-hook-ocaml silently exits 0 on malformed/empty stdin
- **Surface**: C
- **Severity**: Sev3
- **Symptom**: Feeding empty string, invalid JSON, or missing `session_id` field to the hook all produce exit 0 with no output and no stderr.
- **Commands**:
  ```
  $ echo '' | c2c-inbox-hook-ocaml; echo $?
    0
  $ echo 'not json' | c2c-inbox-hook-ocaml; echo $?
    0
  $ echo '{"other":"val"}' | c2c-inbox-hook-ocaml; echo $?
    0
  ```
- **Root cause**: `C2c_hook_lib.resolve_session_id()` returns `Ok ""` on missing/invalid input, and the hook does `exit 0` for empty session_id. This is "fail safe" (won't break Claude) but makes debugging hook issues very hard.
- **Suggested fix**: Emit a single stderr line on parse failure (e.g., `{"warning":"c2c-inbox-hook: no session_id in stdin"}`) before exit 0. This preserves fail-safe behavior while giving operators a breadcrumb.

### Issue 6 — inbox-hook-ocaml --help produces no output
- **Surface**: C
- **Severity**: Sev3
- **Symptom**: `c2c-inbox-hook-ocaml --help` outputs nothing (stdout and stderr empty), exits 0.
- **Root cause**: The hook binary has no argument parsing — it ignores all CLI flags and just reads stdin.
- **Suggested fix**: Add a minimal `--help` / `-h` handler that prints usage: "c2c-inbox-hook-ocaml: PostToolUse hook for c2c auto-delivery. Reads JSON from stdin with session_id field."

### Issue 7 — room send "0 members" warning when only sender is in room
- **Surface**: D
- **Severity**: Sev3
- **Symptom**: Sending to a room where the only member is the sender produces: `warning: room bakeoff-mimo-room has 0 members; message stored in history but not delivered`. Room actually has 1 member (the sender).
- **Command**:
  ```
  $ c2c rooms send bakeoff-mimo-room "hello"
    warning: room bakeoff-mimo-room has 0 members; message stored in history but not delivered
    Sent to room bakeoff-mimo-room (0 delivered, 0 skipped)
  ```
- **Root cause**: `fan_out_room_message` excludes the sender from delivery targets. When sender is the only member, both `delivered` and `skipped` are empty, triggering the "0 members" warning. The warning text is misleading — the room has 1 member, just no *other* members.
- **Suggested fix**: Change warning to: `"room <id> has no other members besides sender; message stored in history but not delivered"`. Or: `"0 recipients (only sender is a member)"`.

---

## What Works Well

1. **Path traversal is properly blocked**: `../escape-test` rejected with clear error and exit 2.
2. **Empty session_id rejected**: `--session ""` → clear error, exit 2.
3. **`--session` is well-documented in `--help`**: Clear description of what it does.
4. **`--json` on send returns useful fields**: `target_session_id` (not `to_alias`), `ts`, `from_alias`, `queued`.
5. **No-body send properly rejected**: `--session <sid>` without message → clear error.
6. **Inbox drain is correct**: Second hook call produces no output (already drained). Inbox file becomes `[]`.
7. **Tagged messages preserved through hook**: `--fail` tag appears as `tag="fail"` in envelope and `🔴 FAIL:` prefix in body.
8. **Room membership enforcement**: Not-a-member send → proper error with exit 1.
9. **Unregistered alias send → clear error**: "alias 'x' is not registered; message not queued", exit 1.
10. **`my-rooms --json`**: Correctly returns `[]` for sessions not in any room.
11. **Global sessions broker path**: Correctly at `${XDG_STATE_HOME}/sessions/broker/<sid>.inbox.json` — well-separated from per-repo broker.
12. **sessions --json is valid JSON**: Parses cleanly, fields are consistent.

---

## Summary

**7 issues found**: all Sev3 (polish/UX). Zero Sev1/2. The core session-id delivery feature (P0) works end-to-end. Path traversal protection is solid. The hook drain+render pipeline is correct. The main rough edges are: (a) sessions table/JSON schema mismatch, (b) `from_alias` defaulting to "c2c-cli" even in registered sessions, and (c) the solo-member room warning text being misleading.

**Key YES/NO**: Does `send --session` → `inbox-hook-ocaml` drain → `additionalContext` work end-to-end? **YES.**
