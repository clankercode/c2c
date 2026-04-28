# Kimi Idle Delivery Gap — PTY Wake Doesn't Trigger Idle Kimi TUI

**Agent:** opencode-local
**Date:** 2026-04-14T00:22:00Z
**Severity:** HIGH — Kimi cannot receive DMs while idle

## Symptom

When Kimi Code TUI is sitting idle at its prompt (waiting for user input),
PTY-injected wake prompts do NOT cause Kimi to call `mcp__c2c__poll_inbox`.
Multiple injections sent to ghostty terminal PID 3725367 pts/0 — zero response.
Kimi has 1 unread DM in its inbox that it has not drained despite multiple wake attempts.

## What Works

Kimi DM delivery DOES work when Kimi is actively processing:
- At session start (orientation phase), Kimi responded to DMs via poll_inbox
- PTY wake successfully triggered Kimi to drain and reply with correct `from_alias=kimi-nova`
- The Kimi→OpenCode→Kimi DM roundtrip was proven earlier this session

## Root Cause

Kimi's TUI, when idle, does not process PTY-injected text the same way
OpenCode's TUI does. The `c2c_opencode_wake_daemon.py` injects a wake prompt
via bracketed paste + Enter into the terminal, but Kimi's input handler doesn't
act on it when sitting idle.

This is different from OpenCode, where the same PTY injection successfully
wakes the TUI and triggers `mcp__c2c__poll_inbox`.

## Related: Kimi Registration Keeps Disappearing

Kimi's MCP server (PID 2960162, child of Kimi PID 2959892) has
`C2C_MCP_SESSION_ID=kimi-nova` and `C2C_MCP_AUTO_REGISTER_ALIAS=kimi-nova`
but NO `C2C_MCP_CLIENT_PID`. The MCP server's `auto_register_startup` function
creates registrations with `pid: os.getppid()` (Kimi's PID, 2959892).

However, the registration keeps disappearing because:
1. `auto_register_startup` filter at line 206-210 removes entries matching
   EITHER session_id OR alias (AND logic: `session_id != X and alias != Y`)
2. Any one-shot MCP server starting with `alias=kimi-nova` but different
   session_id evicts Kimi's entry
3. A dead registration with `session_id=opencode-c2c-msg, alias=kimi-nova`
   was found in the registry, suggesting a one-shot replaced Kimi's entry

## Possible Solutions

1. **Kimi-specific plugin** (like OpenCode's `c2c.ts`) — would need Kimi's
   plugin/extension API to poll the broker and inject messages as user turns
2. **Fix the MCP server PID registration** — ensure `C2C_MCP_CLIENT_PID` is
   set correctly in Kimi's MCP config, and fix the auto_register_startup
   filter to not be so aggressive
3. **Different wake mechanism** — instead of PTY injection, use stdin pipe
   write (but Kimi's stdin is a PTY slave, not a pipe, so this won't work)
4. **Background poll thread in MCP server** — the MCP server could poll the
   inbox periodically and surface messages without needing PTY wake

## Impact

Without a working idle delivery mechanism, Kimi can only receive DMs when
actively processing. Agents sending DMs to Kimi while it's idle will see
messages queued but never drained.

## Verification

```bash
# Kimi process
ps -p 2959892 -o pid,etimes,stat,comm
# Kimi MCP server
ps -p 2960162 -o pid,etimes,comm
# Kimi inbox
cat .git/c2c/mcp/kimi-nova.inbox.json | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))"
# Try wake
python3 c2c_opencode_wake_daemon.py --session-id kimi-nova --terminal-pid 3725367 --pts 0 --once
# Check if inbox drained after 30s
sleep 30 && cat .git/c2c/mcp/kimi-nova.inbox.json | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))"
```
