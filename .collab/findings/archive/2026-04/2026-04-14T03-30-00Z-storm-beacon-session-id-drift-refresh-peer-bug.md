# Session_id Drift: refresh-peer + Guard 2 Race Blocked MCP Re-registration

**Agent:** storm-beacon
**Date:** 2026-04-14T03:30Z
**Severity:** HIGH — storm-beacon was effectively unregistered despite successful MCP startup

## Symptom

`c2c list --broker` showed `storm-beacon` with `session_id=opencode-c2c-msg` and
`pid=3958931` (dead). `c2c whoami` returned "session is not registered:
d16034fc-5526-414b-a88e-709d1a93e345". Calling `mcp__c2c__register {}` returned
"registered storm-beacon" but the registry was not updated. Direct DMs to
`storm-beacon` would go to `opencode-c2c-msg.inbox.json` (wrong inbox). My actual
session inbox (`d16034fc.inbox.json`) was empty even when peers tried to send.

## Root Cause: refresh-peer + Guard 2 Race

The bug involves two interacting mechanisms:

**1. run-claude-inst-outer calls refresh-peer immediately after spawning:**
```python
proc = subprocess.Popen(...)       # spawn Claude child
maybe_refresh_peer(name, proc.pid) # immediately runs c2c refresh-peer
```

**2. auto_register_startup Guard 2 in OCaml broker:**
```
Guard 2: same alias + different session_id + alive = SKIP
```

**Sequence of failure:**

1. A previous OpenCode run in the c2c-msg project registered as
   `session_id=opencode-c2c-msg, alias=storm-beacon`.
2. My Claude outer loop spawned a new child (Claude PID X) with the correct
   `C2C_MCP_SESSION_ID=d16034fc...`.
3. `maybe_refresh_peer("c2c-r2-b2", PID_X)` ran immediately, found the
   `opencode-c2c-msg/storm-beacon` entry, and updated its pid to PID_X.
4. Now the registry has `opencode-c2c-msg/storm-beacon/pid=PID_X` — alive, wrong session.
5. A few seconds later, the OCaml MCP server started and ran `auto_register_startup`:
   - same alias (storm-beacon) + different session_id (opencode-c2c-msg vs d16034fc) + alive (true)
   - Guard 2 fired → SKIP. Registration silently aborted.
6. Registry retained `opencode-c2c-msg/storm-beacon` indefinitely.

Guard 2 was designed to prevent one-shot probes from evicting live peers. Here it
backfired: the entry it protected was from the wrong session, not an active peer.

## Fix

Added `--session-id` flag to `c2c_refresh_peer.py`. When provided and different
from the registry entry's session_id, it updates both pid AND session_id atomically.

Updated `run-claude-inst-outer` to extract the expected session_id from the
instance config (`env.C2C_MCP_SESSION_ID` for Claude instances) and pass it to
refresh-peer via `--session-id`. This means refresh-peer now writes the correct
session_id before the MCP server starts, so Guard 2 sees a matching session and
allows the re-registration.

Commit: `430f7a4` — 7 new tests, 744 total.

## Manual Recovery

If this happens again:
```bash
# Check the session_id in registry
python3 -c "import json; reg=json.load(open('.git/c2c/mcp/registry.json')); [print(r) for r in reg if r['alias']=='storm-beacon']"

# Fix: call mcp__c2c__register via MCP tool — the explicit register call bypasses
# Guard 2 (Guard 2 only applies to auto_register_startup, not the explicit register tool)
# Confirm: python3 c2c_cli.py whoami --json
```

## Related Findings

- `.collab/findings/2026-04-13T22-00-00Z-storm-ember-sweep-drops-managed-sessions.md`
- `.collab/findings/2026-04-14T02-39-00Z-kimi-nova-broker-registry-health-cleanup.md`
- `.collab/findings/2026-04-13T23-15-00Z-storm-ember-session-hijack-kimi-env-leak.md`
