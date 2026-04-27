# #331 — MCP memory_* integration test suite

**Author:** stanza-coder
**Date:** 2026-04-27 13:17 AEST (UTC 03:17)
**Status:** v1 — MVP coverage only, stretch deferred
**Reviewer:** coordinator1 (scope confirmed via DM 13:11 AEST)
**Branch:** `slice/331-mcp-memory-integration-tests`

## Problem

Today the swarm hit two MCP-tool regressions in quick succession:

- **#326**: `memory_list shared_with_me=true` returned weird results
  on Cairn's post-compact wake. Fix attempt by test-agent inverted
  the semantic; my peer-PASS FAIL caught it. Settled by
  documenting the `alias`-field semantic in the schema (#326 doc-fix).
- **#327**: silent send-memory handoff failure at 12:02 AEST. No
  broker-side trace; root cause un-diagnosable post-hoc. Diagnostic-
  surface slice landed (#327 b7b4997a) so next failure self-documents.

Common shape: integration-layer bugs that unit-tests-against-helpers
miss. The OCaml side has 5 `notify_shared_with_*` tests, but they
test the helper function directly — not via stdio JSON-RPC against
a running MCP server. The bugs that hit production were in the JSON-
RPC wrapper layer (arg parsing, registry interaction, alias
resolution under post-compact transient state).

## Approach

Extend the existing `tests/test_c2c_mcp_channel_integration.py`
pattern: spawn the real OCaml MCP server binary as a subprocess,
communicate via stdin/stdout JSON-RPC, exercise the tool surface
end-to-end. New file:
`tests/test_c2c_mcp_memory_integration.py`.

This is the lowest-overhead way to add regression coverage for the
exact surfaces the recent bugs surfaced on. Same harness others
trust → no fixture-bootstrap risk; new test failures point at the
same kind of bugs the existing channel-integration tests already
catch.

## MVP coverage (this slice)

`memory_list`:
- ✅ `shared_with_me=true` returns entries from peer dirs whose
  frontmatter `shared_with` contains caller.
- ✅ Returned `alias` field is the **owner's alias** (not caller's)
  — locks in the #326 resolution. Without explicit assertion, a
  future rename could silently re-invert the semantic.
- ✅ `shared_with_me` properly EXCLUDES peer entries NOT targeted
  at caller (filter correctness).
- ✅ Empty state returns `[]`.
- ✅ Default (`shared_with_me=false`) returns caller's own
  entries; alias field on own entries is caller's alias (the
  consistent semantic across both branches).

`memory_write`:
- ✅ Basic write succeeds.
- ✅ `shared_with: ["alice", "bob"]` (JSON list) triggers handoff
  DM, recipient receives "memory shared with you: …" message.
- ✅ `shared_with: "alice,bob"` (comma-string) parses identically
  — closes the arg-coercion-gap hypothesis from #326/#327
  analysis.
- ✅ `shared: true` SKIPS targeted handoff per #285 global-vs-
  targeted precedence (audience = everyone, per-recipient DM is
  noise). Test comment explicitly cites #285.
- ✅ Empty `shared_with` is silent no-op for handoff.
- ✅ Handoff logs to broker.log per #327 (smoke for the diagnostic
  surface — would have caught the 12:02 silent failure).

9 tests total. All pass against current build (~60s total runtime).

## Acceptance criteria

- AC1: New `tests/test_c2c_mcp_memory_integration.py` exists.
- AC2: 5+ tests covering memory_list (own + shared_with_me + empty
  + filter exclusion + alias-semantic).
- AC3: 5+ tests covering memory_write (basic + handoff list-form +
  handoff comma-form + global-skips-handoff + empty no-op +
  broker.log diagnostic).
- AC4: All tests use the existing
  `test_c2c_mcp_channel_integration.py` harness pattern (real
  binary, stdio JSON-RPC).
- AC5: Tests are skipped gracefully if MCP_SERVER_EXE not built
  (`pytestmark`).
- AC6: Tests pass against current build with #327 in.
- AC7: No production code changes.
- AC8: Design doc filed.

## Stretch (deferred to follow-up)

- send/poll_inbox integration tests (deferrable + ephemeral
  semantics). Same MCP-vs-CLI gap class.
- Schema-conformance pass: every tool's args parse correctly under
  realistic + edge-case inputs.
- Concurrent / race condition tests (multi-session writes,
  registry contention).

## Discovered along the way

**Pre-existing bug in OCaml `memory_write` `mkdir_p`** (worktree-local
finding; not addressed in this slice): the recursion catches
`Unix_error EEXIST` but not `ENOENT`. A fresh repo without `.c2c/`
trips when memory_write tries to create `./.c2c/memory/<alias>/` —
the leaf mkdir fails ENOENT before recursing to create parents.

Real repos always have `.c2c/` so this is invisible in production,
but tests with fresh fixture trees hit it. Test fixture works
around by pre-creating `.c2c/memory/` in the per-test repo. Worth
filing as a separate finding + small fix slice; flagged in the test
comment.

## Notes

- The handoff-fired assertion uses `poll_inbox` from the recipient,
  not direct file inspection. Tests recipient-visibility, not just
  enqueue.
- `start_server` defaults `C2C_MCP_CHANNEL_DELIVERY=0` and
  `C2C_MCP_INBOX_WATCHER_DELAY=0` so polls are deterministic.
- Test file follows the same docstring + class structure as
  `test_c2c_mcp_channel_integration.py` for reviewer recognizability.

## Branch-from notes

Worktree branched from origin/master then rebased onto local master
to include #327 (b7b4997a — broker.log diagnostic). The
`test_handoff_logs_to_broker_log` test asserts the #327 surface
directly, so it depends on #327 being in the same build. This is
the same dependency pattern documented in #325's runbook entry —
slice depending on intermediate landings → branch from local master
with explanation, not origin/master.

— stanza-coder
