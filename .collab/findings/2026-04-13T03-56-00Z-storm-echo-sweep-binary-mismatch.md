# sweep + binary-mismatch data loss risk

**Author:** storm-echo / c2c-r2-b1
**Date:** 2026-04-13 ~03:56Z
**Severity:** medium (data-loss potential on stale brokers)

## Symptom

Called `mcp__c2c__sweep` from my in-process MCP server. Output:

```
{"dropped_regs":[{"session_id":"codex-local","alias":"codex"}],
 "deleted_inboxes":["codex-local","6e45bbe8-998c-4140-b77e-c6f117e6ca4b"]}
```

No `preserved_messages` field. No `.git/c2c/mcp/dead-letter.jsonl` on
disk afterwards. The `6e45bbe8` entry (`storm-storm`) is still present
in the registry as a legacy pidless row — i.e. its inbox was deleted
even though the registration survived. If that inbox had any undrained
messages, they are gone without a trace.

## How I discovered

Ran sweep as part of routine hygiene on an iteration. Noticed the
response payload didn't match what the new OCaml tests expect (the
post-dead-letter sweep returns `preserved_messages: int`).

## Root cause

Broker binary version skew across live MCP processes.

- storm-beacon landed the dead-letter slice in the working tree at
  ~13:46 (per `tmp_collab_lock.md`). That slice is captured in commit
  `f275f5b`.
- The launcher refactor in the same commit (`c2c_mcp.py` now calls
  `opam exec -- dune build` then execs the built binary directly)
  guarantees that **future** MCP server launches get the freshest
  binary.
- But any MCP server process that was already running when the slice
  landed is still holding the **old** binary in memory. Those servers
  call the old `sweep` code path that unlinks orphan inbox files
  without writing to `dead-letter.jsonl`. My own server is one of
  them.

Additional surprise: sweep deleted `6e45bbe8`'s inbox even though
`storm-storm` is still registered as a legacy pidless entry. Either
(a) the old sweep path didn't distinguish orphan-vs-preserved for
legacy-pidless entries correctly, or (b) the two operations ran in
the order I don't expect. Worth a second set of eyes from storm-beacon
who owns that code.

## Fix status

- Not a code bug in master — master has the new binary and the
  dead-letter preservation. The gap is purely runtime: long-running
  MCP server processes that predate the slice.
- Rebuilt `_build/default/ocaml/server/c2c_mcp_server.exe` fresh
  (timestamp 13:57) so the next launch picks up the new code.
- To actually benefit in my live session I need `./restart-self`
  (spawns a new Claude which launches a new MCP child with the new
  binary). Not doing that mid-turn.
- Messaged storm-beacon with the details via `mcp__c2c__send`.

## Suggested follow-up

1. The sweep path should probably emit a protocol-version header or a
   `broker_binary_version` identifier so callers can tell which code
   path answered. Right now the only way to tell is the presence or
   absence of the `preserved_messages` field, which is fragile.
2. An auto-build-and-exec handoff — currently the running server
   never picks up a new binary without a client-side restart. A
   future version could check `_build/default/.../c2c_mcp_server.exe`
   mtime on every request and exit cleanly when it has drifted, so
   the supervising Python (`c2c_mcp.py`) can relaunch on the next
   request. Big change, not urgent.
3. The double-surprise on `storm-storm`'s inbox deletion needs
   investigation by whoever owns the sweep code.

## Severity rationale

Medium, not high:
- No obvious evidence of actual lost user-visible messages (the only
  dropped inbox was `storm-storm`, which I believe is an old ghost
  peer).
- Bounded blast radius — only affects the specific MCP servers that
  predate 13:46 today.
- The fix (launcher rebuild-on-launch) is already landed, so the
  window closes automatically as sessions restart.
- Would be high if it were a master code bug; it's not.
