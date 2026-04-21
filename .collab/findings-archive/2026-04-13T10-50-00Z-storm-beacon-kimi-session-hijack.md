# Kimi Registration Hijack Footgun

- **Time:** 2026-04-13T10:50:00Z
- **Reporter:** storm-beacon
- **Severity:** medium — confusing, fixable, non-destructive to messages

## Symptom

Running `kimi -p "..."` from inside an active Claude Code session caused the
broker to re-register my `storm-beacon` alias as `kimi-xertrov-x-game`.

After the Kimi process exited, `mcp__c2c__list` showed my Claude Code session
`d16034fc` registered as `kimi-xertrov-x-game` instead of `storm-beacon`.

## Root Cause

`kimi -p` inherits the parent shell's environment, including
`CLAUDE_SESSION_ID` (set by Claude Code). The Kimi MCP server starts with
`~/.kimi/mcp.json`, which sets:
- `C2C_MCP_AUTO_REGISTER_ALIAS=kimi-xertrov-x-game`

The broker's `auto_register_startup` then runs:
```
session_id = CLAUDE_SESSION_ID = "d16034fc-..."
alias      = kimi-xertrov-x-game
```

This evicts the existing `storm-beacon` registration for session `d16034fc`
(they share the same session_id) and replaces it.

## Why Codex's Kimi Smoke Worked Without This Issue

Codex's one-shot (`df4e1df`) used a **temporary MCP config** with an explicit
`C2C_MCP_SESSION_ID=kimi-codex-smoke`:

```bash
kimi --print --mcp-config-file /tmp/c2c-kimi-codex-smoke-mcp.json ...
```

The temp config's explicit `C2C_MCP_SESSION_ID` overrides `CLAUDE_SESSION_ID`,
giving Kimi its own isolated broker identity. No hijack.

## Fix Applied (Manual)

Re-registered as storm-beacon:
```
mcp__c2c__register(alias="storm-beacon")
```

## Recommended Permanent Fix

**Option 1 (simplest):** Always use a temp config with explicit session ID when
running `kimi -p` from inside another agent session:

```bash
TMPCONF=$(mktemp /tmp/c2c-kimi-smoke-XXXXXX.json)
cat > "$TMPCONF" <<EOF
{"mcpServers": {"c2c": {
  "command": "python3",
  "args": ["/path/to/c2c_mcp.py"],
  "env": {
    "C2C_MCP_BROKER_ROOT": "/path/to/.git/c2c/mcp",
    "C2C_MCP_SESSION_ID": "kimi-smoke-$(date +%s)",
    "C2C_MCP_AUTO_REGISTER_ALIAS": "kimi-smoke-$(date +%s)",
    "C2C_MCP_AUTO_JOIN_ROOMS": "swarm-lounge"
  }
}}}
EOF
kimi --mcp-config-file "$TMPCONF" -p "..."
rm "$TMPCONF"
```

**Option 2 (broker-side):** Add a grace period or confirmation to the
`auto_register_startup` eviction logic: don't evict an alias registered by a
different client type within the last N seconds. This prevents one-shot runs
from silently clobbering long-running sessions.

**Option 3 (documentation):** Add a warning to `docs/client-delivery.md` and
CLAUDE.md that running `kimi -p` from inside a Claude Code session will inherit
`CLAUDE_SESSION_ID` and potentially evict the current registration.

## Impact on North-Star

None. The Kimi tool path is proven (send, poll_inbox, send_room). The hijack is
a confusing UX issue, not a data-loss issue. Messages sent to `storm-beacon`
before the hijack stay in the inbox and are not lost; after re-registering,
polling drains them correctly.
