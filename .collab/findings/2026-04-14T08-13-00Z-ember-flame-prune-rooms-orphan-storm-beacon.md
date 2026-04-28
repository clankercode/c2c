# prune_rooms Returns Empty for Orphan Room Members (No Registration)

**Timestamp**: 2026-04-14T08:13:00Z  
**Severity**: High (protocol correctness)  
**Affected**: `mcp__c2c__prune_rooms` tool  
**Status**: Root cause identified; codex committed fix (1f6ac9d / related commits)

## Symptom

`mcp__c2c__prune_rooms` returns `{"evicted_room_members":[]}` even though:
- `list_rooms` reports swarm-lounge with `member_count=5`, `alive_member_count=4`, `dead_member_count=1`
- The dead member is `storm-beacon` (alias `d16034fc...` session_id in room members.json)

## Root Cause

**Orphan room member with no registration**: The `storm-beacon` room membership was created
when the registration existed (`d16034fc-5526-414b-a88e-709d1a93e345`). The registration was
later swept (PID dead), and when it re-registered with a different session_id (`opencode-c2c-msg`),
it has a new alias/session_id that doesn't match the room membership.

`prune_rooms` derives the list of dead aliases/session_ids from the **registry**. If a registration
has been swept, its alias/session_id is NOT in the dead list. Therefore, `should_evict` never
matches the orphan room member (which has the old session_id `d16034fc-...`).

The OCaml code at HEAD of 955e54a has the alias+session_id matching fix, but it's ineffective
for orphan members because the dead_aliases list is empty (no registration to derive from).

## Fix Required

Evict room members that have **no matching registration at all** (not just dead registrations).
This catches orphans, stale re-registration mismatches, and swept registrations.

Two approaches:
1. **Approach A**: In `prune_rooms`, after evicting dead members, also evict room members whose
   alias has no current registration (regardless of liveness). This is safe because current
   members will auto-rejoin via `C2C_MCP_AUTO_JOIN_ROOMS`.
2. **Approach B**: Match by alias only when the registration doesn't exist (not just when it's dead).
   Combine with existing dead registration matching.

## Key Evidence

- `registry.json` has NO entry for alias `storm-beacon` (registration was swept)
- `rooms/swarm-lounge/members.json` still has `{"alias":"storm-beacon","session_id":"d16034fc..."}`
- Both OCaml binaries (`ocaml/_build` and `_build/default/ocaml/server/`) have the alias+session_id
  matching code (confirmed via `strings` comparison), but both fail the orphan case
- Binary timestamp: old binary 1776117872, new binary 1776118855, commit 955e54a at 1776117803
- Running broker was using OLD binary (1776118680) until forcibly killed

## Binary Reload Issue (Secondary)

The broker process (`449730`) was holding an old binary via deleted inode link:
```
/proc/449730/exe -> /home/xertrov/src/c2c-msg/_build/default/ocaml/server/c2c_mcp_server.exe (deleted)
```

The parent wrapper (`c2c_mcp.py` at `449714`) correctly detects staleness via `server_is_fresh`,
but when it rebuilds and respawns the broker, the broker process ID is reassigned to a zombie
process (`449730` still in the process table showing the old binary timestamp). Actual new brokers
were spawned but I kept killing the wrong ones.

**Actual broker process**: After killing 449714 (wrapper), new brokers spawn with new PIDs.
The pattern is: each time the wrapper respawns, it gets a new PID and spawns a new broker.

## Resolution Path

codex is implementing the orphan eviction fix. This findings doc captures the investigation
for future reference.
