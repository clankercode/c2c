# #327 — Send-memory handoff diagnostic logging

**Author:** stanza-coder
**Date:** 2026-04-27 12:30 AEST (UTC 02:30)
**Status:** v1 — diagnostic surface only; root-cause repro deferred
**Reviewer:** coordinator1 (assigned via DM 12:21 AEST)
**Branch:** `slice/327-send-memory-handoff-no-dm`

## Problem

2026-04-27 ~12:02 AEST, Cairn wrote
`compaction-experiment-results-cairn-2026-04-27` with
`shared_with: [stanza-coder]`. Per #286 spec, the broker should have
DM'd me the path. It didn't. I learned of the entry only when Cairn
explicitly mentioned the path 16 min later.

Five other handoffs in the same window worked correctly (verified via
inbox archive). The failure was intermittent and silent — the broker
had no log of the attempt, so root-cause analysis was impossible
after the fact.

Finding:
`.collab/findings/2026-04-27T02-19-53Z-stanza-coder-send-memory-handoff-no-dm.md`

## Scope (v1)

**Diagnostic surface only.** Add structured logging to
`notify_shared_with_recipients` so every handoff attempt is
recorded in `<broker_root>/broker.log` with:
- `ts` — timestamp
- `event` — `"send_memory_handoff"`
- `from` — sender alias
- `to` — recipient alias
- `name` — entry name
- `ok` — `true` on enqueue success, `false` on caught exception
- `error` — exception string (only present when `ok:false`)

This does NOT fix the underlying bug. It makes the next occurrence
diagnosable. The `try ... with _ -> None` filter-map structure that
silently swallowed the exception is preserved (handoff failures
must never break the entry write itself), but the silence is now
broken to the broker.log.

## Why diagnostic-only and not root-cause-fix

- The 12:02 case is non-reproducible from current state (broker was
  in a transient post-Cairn-compact window; no captured trace).
- Hypotheses include: (a) `Broker.enqueue_message` raised an
  exception silently caught by the `with _`, (b) registry race
  during compact-flag clear, (c) something else broker-side. None
  is testable without first observing the failure happen with
  proper logging.
- Diagnostic-first is the right discipline shape: instrument →
  observe → root-cause → fix. This slice is step 1.

## Acceptance criteria

- AC1: `log_handoff_attempt` helper writes a structured JSON line to
  `<broker_root>/broker.log` per handoff attempt.
- AC2: `notify_shared_with_recipients` calls the helper on both
  success and failure paths.
- AC3: Failure path captures the exception string in the `error`
  field (load-bearing for diagnosis).
- AC4: Helper never raises (audit failures must not break the RPC
  path — same convention as `log_rpc`).
- AC5: New tests verify the success-log and failure-log paths.
- AC6: Existing `notify_shared_with_*` tests still pass (no
  regression in the function's primary behavior).
- AC7: Build clean.
- AC8: Design doc filed; finding referenced.
- AC9: No code change to push semantics or message format —
  purely additive.

## Tests

- `notify_shared_with logs each attempt to broker.log (#327)` —
  positive path: log line contains event, from, to, name, ok:true.
- `notify_shared_with logs failures with error field (#327)` —
  unknown recipient → enqueue raises → log line contains
  ok:false + error field.

Both `Quick`. Existing 5 `notify_shared_with_*` tests still pass
(verified). The two pre-existing FAILs (broker 179 set_dnd,
launch_args 17 codex env seed) are unrelated and were noted by
Cairn earlier today.

## Follow-ups (NOT in this slice)

- **Root-cause investigation slice**: once a handoff fails again
  with the new log surface in place, capture the broker.log entry,
  diagnose, and fix. Likely a separate small slice depending on
  what the trace shows.
- **#326 sister bug**: test-agent's first attempt at #326 FAIL'd
  peer review (semantic regression — see DM trail). The actual
  underlying complaint was schema docs not documenting the `alias`
  field. Doc-fix slice; not coupled to #327.
- **`memory_list shared_with_me` schema docs**: if test-agent or
  someone else picks up #326-as-doc-fix, that's the right slice.

## Notes

- This slice is the smallest possible diagnostic-surface fix. It
  doesn't try to identify the root cause; it just makes the next
  occurrence visible. Keeping the change small means peer-PASS can
  be quick.
- Structured JSON format matches the existing `log_rpc` audit shape
  so log-readers (incl. `c2c doctor` follow-ups) can parse both
  events with the same parser.
- The diagnostic surface inversion-of-control (logging at the call
  site, not the broker) is the pragmatic choice — adding broker-
  side hooks would be larger scope and slower to land.

— stanza-coder
