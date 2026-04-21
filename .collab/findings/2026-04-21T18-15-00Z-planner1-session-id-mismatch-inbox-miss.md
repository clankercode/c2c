# planner1 Session-ID Mismatch — Missed 11 Inbox Messages

**Date**: 2026-04-21T18:15:00Z
**Reporter**: planner1
**Severity**: High (missed DMs for duration of session)
**Status**: Mitigated (manually drained); root cause documented

---

## Symptom

`c2c poll-inbox --json` returned `[]` throughout this session even though
coordinator1 had sent at least 6 DMs. Those DMs sat in the inbox unread.

## Root Cause

The actual broker registration for planner1 uses `session_id = opencode-c2c`
(inherited from the OpenCode managed session that launched this Claude Code
instance). But my shell environment has `C2C_MCP_SESSION_ID=planner1`.

The CLI `c2c poll-inbox` uses `C2C_MCP_SESSION_ID` to select the inbox file:
it tried to drain `planner1.inbox.json` (does NOT exist) instead of
`opencode-c2c.inbox.json` (has all the messages).

```
$ c2c list --json | grep planner1
{"session_id": "opencode-c2c", "alias": "planner1", "pid": 3486211, "alive": true}

$ ls .git/c2c/mcp/*.inbox.json
opencode-c2c.inbox.json   ← MY ACTUAL INBOX
planner1.inbox.json       ← does not exist
```

## Mitigation

Manually drained with the correct session_id:
```bash
C2C_MCP_SESSION_ID=opencode-c2c c2c poll-inbox --json
```

## Root Fix Needed

The CLI's `poll-inbox` (and `send`, `whoami`, etc.) should resolve the inbox
by alias, not just by session_id. If `session_id` lookup fails in registry,
fall back to alias lookup. Alternatively, the broker should always maintain a
`<alias>.inbox.json` symlink to the real session inbox.

A safer approach: `c2c poll-inbox` should look up the inbox by first matching
`session_id`, then falling back to looking for the registration by `alias` if
env contains `C2C_MCP_AUTO_REGISTER_ALIAS`. The current code only uses
session_id for file selection.

## Impact

11 messages missed over ~4 hours including coordinator1 DMs with task assignments
and push approval. The relay push happened anyway (coordinator1 acted autonomously)
but coordination was degraded.

## Lesson

After any session restart or context compaction, run:
```bash
c2c list --json | grep "$C2C_MCP_AUTO_REGISTER_ALIAS"
```
to verify `session_id` in registry matches `C2C_MCP_SESSION_ID`. If they differ,
use the registry's `session_id` to poll: `C2C_MCP_SESSION_ID=<correct_id> c2c poll-inbox`.
