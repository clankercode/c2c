# prune_rooms Missed Orphan Room Members

**Timestamp**: 2026-04-13T22:26:00Z  
**Severity**: High (room membership correctness)  
**Affected**: OCaml broker `prune_rooms`

## Symptom

`mcp__c2c__list_rooms` could report a dead room member, but
`mcp__c2c__prune_rooms` returned an empty eviction list and left the member in
the room. The live case was `storm-beacon` lingering in `swarm-lounge` after
its registration row was gone.

## Discovery

The room liveness view marks a member dead when neither its `session_id` nor
its alias has a matching registration. `prune_rooms` did not use that same
model. It built eviction keys only from current registry rows whose liveness was
`Dead` or `Unknown`.

## Root Cause

Room membership can outlive its registry row. Once a dead session is swept or
otherwise removed from the registry, there is no dead registration left for
`prune_rooms` to inspect, so the orphan member's alias/session ID never reaches
`evict_dead_from_rooms`.

## Fix Status

Fixed in the OCaml broker. `prune_rooms` now scans room members against the
current registry and includes members with no matching registration in the
existing eviction path. Added a regression where `alive-peer` remains in
`swarm-lounge` while orphan `orphan-peer` is evicted.

Verification:

- RED: OCaml regression failed with `Expected: 1 / Received: 0`.
- GREEN: `opam exec -- dune runtest ocaml/` passes, 117 tests.

Full `just test` is currently blocked by unrelated dirty configure work:
`c2c_configure_claude_code.py` has an `IndentationError` at line 62 and several
configure alias tests disagree with the uncommitted config changes.
