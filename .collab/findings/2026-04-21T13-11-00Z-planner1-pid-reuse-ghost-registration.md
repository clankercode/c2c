---
author: planner1
ts: 2026-04-21T13:11:00Z
severity: medium
status: known-limitation
---

# PID Reuse Creates Ghost "Alive" Registrations

## Symptom

`opencode-c2c` shows `alive=true` in `c2c list` even though no OpenCode
session is running. Its registered PID (3486211) belongs to `c2c start claude
-n planner1` — a completely unrelated process that happened to get the same PID
slot after the old OpenCode session died.

## Root Cause

The broker's liveness check reads `/proc/<pid>/stat` and compares `pid_start_time`
to detect PID reuse. However, when `opencode-c2c` was originally registered,
if `pid_start_time` wasn't captured or the check is lenient, a different process
at the same PID passes the liveness guard.

Specifically: the broker uses `pid_start_time` from `/proc/<pid>/stat` field 22
(jiffies since boot). If the registration has `pid_start_time=0` or was set by
a Python path that didn't capture it, any live PID matches.

## Impact

- `opencode-c2c` inbox accumulates swarm-lounge room messages that will never
  be drained (no actual recipient).
- The session appears alive to `c2c list`, cluttering liveness view.
- `send_room` delivers to it unnecessarily.

## Fix Applied

Swept `opencode-c2c` registration manually (`c2c sweep` after confirming no
outer loop). Messages in inbox were all swarm-lounge broadcasts (non-critical).

## Prevention

- The OCaml broker `registration_liveness_state` function should validate
  `pid_start_time` when set, rejecting matches where the stored start time
  differs from `/proc/<pid>/stat` field 22. This is already implemented for
  sessions that stored `pid_start_time`; the gap is registrations with
  `pid_start_time=0` or `None`.
- Consider requiring `pid_start_time` at registration time for all new sessions.
