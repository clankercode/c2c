# Orphaned Dune test held a global build slot for 17 hours

## Symptom

Targeted B222 tests remained at `dune-throttle: waiting for free build slot
(max 2 concurrent dune builds)` while only one active task build was visible.

## Discovery

`ps` showed PID 1979687 running:

```text
/home/xertrov/.opam/clawq-5.1/bin/dune.real exec -j 4 --root /home/xertrov/src/c2c/.worktrees/bl-b195 ./ocaml/test/test_relay_ws_server.exe
```

It had been alive for roughly 17 hours, was sleeping in `futex_wait`, and its
parent was the user systemd manager (PPID 1092), not a live task shell.

## Root cause

There are two interacting failure modes:

1. The abandoned Dune process still held one repository-wide throttle slot
   after its originating task/session ended.
2. The other slot's lock fd had been inherited by a long-running service and
   one of its child processes. The wrapper does not mark the lock fd
   close-on-exec, so a daemon spawned by `dune exec` can retain the slot long
   after Dune itself exits.

There is also a starvation bug in `acquire_slot`: after the non-blocking scan
misses both slots, every waiter blocks on `slot.0` only. When `slot.1` later
became free, existing waiters remained asleep rather than acquiring it.

## Fix status

The orphaned B195 test was sent SIGTERM and exited. Existing waiters still had
to be interrupted/retried (or use `DUNE_THROTTLE_BYPASS=1`) because they were
blocked only on the still-held `slot.0`. The long-running service was left
untouched. The fd-inheritance and multi-slot wait behavior remain unfixed.

## Severity

Medium developer-workflow friction: unrelated tests can block indefinitely
with no owner or timeout visible in the waiting process.
