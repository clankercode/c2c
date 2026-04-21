# Register inbox migration on alias re-register

- **Discovered:** 2026-04-13 14:35 by storm-beacon (Claude Opus 4.6,
  session d16034fc) while reviewing storm-echo's 03:56Z
  sweep-binary-mismatch finding follow-up #3.
- **Severity:** medium. Real correctness gap, not a crash. Bites
  re-launched agents that had unread messages buffered behind their
  prior session_id.

## Symptom

When an agent re-registers under the same alias with a fresh
`session_id` (most commonly: process restart, or
`/run-claude-inst` re-spawn), any messages already queued on the OLD
session's inbox file are stranded:

1. `register` already (correctly) dedupes by alias and evicts the
   prior reg row from `registry.json`. New routing works.
2. But the orphan inbox file at `<old-session>.inbox.json` is left
   on disk with its undrained messages intact.
3. `sweep` will eventually find the orphan and dump it to
   `dead-letter.jsonl` (good), then unlink it (good).
4. The re-launched agent — same logical alias, same human, same
   purpose — never sees those messages in its own inbox. They are
   only recoverable by an operator manually grepping
   `dead-letter.jsonl`.

## Root cause

`Broker.register` was missing the "I'm the same logical agent, please
forward my mail" semantic. Eviction-from-registry is necessary but
not sufficient when there is buffered state attached to the evicted
row.

## Fix

`ocaml/c2c_mcp.ml :: Broker.register` now:

1. Under `with_registry_lock`: partition regs into evicted (matching
   either session_id OR alias) + kept; write the new reg + kept.
2. Release registry lock.
3. For each evicted reg whose `session_id` differs from the new one:
   a. Take `with_inbox_lock t ~session_id:old_sid`. Read its inbox
      messages. If non-empty, write `[]` then `Unix.unlink` the file.
      Release lock.
   b. If we drained anything, take
      `with_inbox_lock t ~session_id:new_sid`, append the migrated
      messages to its current inbox, release.

Lock ordering is strictly registry → old_inbox → new_inbox, with
each lock fully released before the next is taken. No nested inbox
locks, so no chance of A-B/B-A deadlock between two concurrent
re-registers.

Migrated messages are appended (not prepended), so they preserve
arrival order relative to anything that landed on the new session's
inbox in between. (In practice that's the empty case, but the test
covers the ordering invariant explicitly.)

## Test

`ocaml/test/test_c2c_mcp.ml ::
test_register_migrates_undrained_inbox_on_alias_re_register`:

1. Register `storm-recv` with `old-session`.
2. Enqueue two messages to `storm-recv` (lands in old-session inbox).
3. Re-register `storm-recv` with `new-session`.
4. Drain `new-session` inbox → 2 messages.
5. Assert content + order.
6. Assert `<dir>/old-session.inbox.json` no longer exists.

Suite: 41/41 green (was 40/40).

## Status

- Working tree only. Uncommitted. Pending Max approval per the
  storm-beacon no-commits-without-approval rule.
- Released `ocaml/c2c_mcp.ml` + `ocaml/test/test_c2c_mcp.ml` locks
  in `tmp_collab_lock.md` history (14:48 entry).
- Acked storm-echo via c2c send.

## Follow-up slice (also landed in working tree at 15:08)

After writing this finding I went back and closed the concurrent
race below in a follow-on slice. Both `enqueue_message` and
`send_all` now take `with_registry_lock` around their full
resolve+inbox-lock+write path, and the migration block in `register`
now runs INSIDE the registry lock. New regression test
`register serializes with concurrent enqueue` forks a sender pushing
60 messages while the parent re-registers the alias 8 times; passes
42/42 stable across 5 runs.

## Original known-limitation analysis (now closed)

While auditing this slice I noticed a pre-existing race that the
migration fix does **not** fully close, and it deserves its own
follow-up:

`Broker.enqueue_message` reads the registry via
`resolve_live_session_id_by_alias` **without** taking
`with_registry_lock`. A concurrent register flow can:

1. Take registry lock, evict the prior reg row for the alias, save,
   release registry lock.
2. Take old inbox lock, migrate messages, unlink old inbox file,
   release old inbox lock.

Meanwhile a sender thread C may have read the registry **before**
step 1's save, so C still has the old session_id resolved for the
alias. C then takes the old inbox lock (after migration releases it),
sees an empty inbox (file gone), appends its message, and `save_inbox`
**recreates** the old inbox file with C's message. That file now has
no live registry row pointing at it, so the new logical session never
sees C's message and the next sweep dumps it to dead-letter.

This pre-dates my fix — the same window existed even before alias
re-register ever migrated anything (sender enqueued to a stranded
file then). The migration fix is still net-positive: it closes the
"buffered before re-register" half of the gap. Closing the
"in-flight during re-register" half requires either:

- wrapping `enqueue_message` in `with_registry_lock` so it serializes
  with `register`, or
- a two-phase resolve where the inbox lock is taken *while still
  holding* the registry lock and only released after the write.

Both have the same lock order as `sweep` (registry → inbox) so no
deadlock risk. The cost is that all enqueues serialize on the
registry mutex; given the existing 12-child fork test passes the
locked path in ~1s for 240 messages this is almost certainly
acceptable.

**I'm leaving this for a separate slice** so the migration patch
stays small and focused. Filed mentally as: "register-locked
enqueue."

## Related

- Closes the orphan-message half of storm-echo's 03:56Z follow-up #3
  about the "double-surprise on storm-storm's inbox deletion".
  Sweep deleting an orphan inbox is no longer a data-loss surprise
  for *re-launched aliases*: the messages get migrated before sweep
  ever sees the orphan. Sweep's dead-letter path remains the
  recovery channel for the truly-dead-and-not-coming-back case.
- Builds on the existing alias-dedupe slice (b6ef334-era) which
  evicted the registry row but stopped short of the buffered state.
