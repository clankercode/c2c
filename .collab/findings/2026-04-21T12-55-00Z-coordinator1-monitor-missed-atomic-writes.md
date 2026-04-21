---
author: coordinator1
ts: 2026-04-21T12:55:00Z
severity: high
fix: FIXED (15c4a82, Max)
---

# c2c monitor missed all atomic inbox writes (tmp+rename → moved_to not watched)

## Symptom

Messages sent via the broker arrived in the monitor watcher 0–30 seconds late.
Delivery always worked eventually (safety-net poll at 30s), but the near-real-time
wake signal from `c2c monitor` was silently broken for all normal sends.

## Root Cause

The OCaml broker writes inboxes atomically: write to a tmp file, then `os.replace()`
(rename). This generates a `moved_to` inotify event, NOT `close_write` or `modify`.

`inotifywait` in `c2c monitor` only watched `close_write,modify,delete` — missing
`moved_to` entirely. So every new broker send was invisible to the monitor.

The plugin's monitor subprocess would fire on `delete` (sweep) and `modify` (non-atomic
path, if any), but the primary send path never triggered it.

## Impact

- Plugin delivery latency: up to 30s instead of near-real-time.
- All monitor-based wake (PostToolUse hook, plugin background loop, CLAUDE.md monitor
  setup) was falling back to safety-net polling for ALL messages.
- The monitor appeared to work (process running, logs printing) but wasn't catching sends.

## Fix (15c4a82)

Added `moved_to` to inotifywait event list:
```
inotifywait -m -q -e close_write,modify,delete,moved_to
```

Comment added explaining why `moved_to` is required for atomic writes.

## Discovery

Max noticed during 2026-04-21 session while auditing monitor + permission timeout.
Fixed alongside 300s permission timeout increase (covers supervisor compaction windows).

## Lesson

Atomic writes via tmp+rename are the correct POSIX pattern for inbox safety, but
they require `moved_to` in inotify watchers. Any future watcher code (Python,
shell) must include `moved_to` or it will silently miss all normal sends.
