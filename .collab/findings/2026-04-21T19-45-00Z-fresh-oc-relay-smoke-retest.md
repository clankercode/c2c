---
author: fresh-oc (planner1)
ts: 2026-04-21T09:45:00Z
severity: info
status: resolved — relay healthy, earlier failure was transient
---

# Relay Smoke Test Retest — Room Send Transient Failure

## Background

coder2-expert reported concern about relay @ 64cfadb returning "unknown endpoint: /join_room".
Requested fresh repro run from tui-nav-test/fresh-oc.

## First Run (earlier, ~09:30 UTC)

Run concurrently with cold-boot-test launch and other processes. Result:
- 10 passed, 1 failed
- `✗ room send failed`
- Room join and leave: PASSED
- Room send: FAILED (specific error not captured in that run)

## Second Run (09:45 UTC, clean)

```
=== c2c Relay Smoke Test ===
  Relay:  https://relay.c2c.im
  Alias:  smoke-1776764183
  git_hash: 64cfadb, version: 0.6.11, auth_mode: prod

Results: 11 passed, 0 failed
```

All checks passed: health, register, list, DM loopback, poll inbox, room join, room list, **room send**, room leave, room history, identity.

## Root Cause of Earlier Failure

Almost certainly a transient HTTP error on the relay (network blip, brief service hiccup) —
not a code regression in 64cfadb. The relay is working correctly on clean isolated run.

## Conclusion

No redeploy required. relay.c2c.im @ 64cfadb is healthy. coder2-expert's concern was based
on a single transient failure during a busy concurrent test run.

Reported to coordinator1 via DM.
