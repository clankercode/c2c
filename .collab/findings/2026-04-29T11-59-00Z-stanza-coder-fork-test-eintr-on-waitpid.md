# test_concurrent_open_pending_permission EINTR on waitpid (intermittent)

- **When**: 2026-04-29 ~11:59 UTC, observed by slate during #432 Slice C
  peer-PASS review.
- **Where**: `ocaml/test/test_c2c_mcp.ml` broker test 56,
  `test_concurrent_open_pending_permission` (my Slice A test from
  #432 / `2e97eac4`).
- **Severity**: LOW (test flake; passes on retry; no production
  impact).

## Symptom

First run of the test in slate's environment raised
`Unix.Unix_error(EINTR, "waitpid", "")`. Re-run passed cleanly.
Likely cause: SIGALRM from the heartbeat / Monitor loop landed during
the parent's blocking `Unix.waitpid` call, which surfaces as EINTR
to OCaml.

## Why this happens

POSIX `waitpid()` returns `-1` with `errno=EINTR` when a signal
arrives during the syscall. OCaml's `Unix.waitpid` propagates this
as `Unix_error(EINTR, ...)`. Most OCaml code wraps blocking syscalls
in EINTR-retry loops, but my fork test calls `Unix.waitpid [] pid`
naked. With the heartbeat fires armed in the test harness's parent
process, the probability of an SIGALRM-during-waitpid race is
non-zero on a long-running test runner.

## Fix shape

Wrap the waitpid in a retry loop:

```ocaml
let rec waitpid_eintr pid =
  try Unix.waitpid [] pid
  with Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_eintr pid
```

And use `waitpid_eintr pid` in the parent's reaper loop.

5-line change. Pure robustness fix; no behavior change.

## Where to file the fix

Best home: a tiny followup commit on a `slice/432-test-eintr-fix`
worktree branched from master (post-Slice-A). Touches only
`test_c2c_mcp.ml`. Doc-only-tagged-as-test patches are acceptable
here; no production code involvement.

## Severity rationale

LOW: doesn't surface in normal CI (no SIGALRM source there); only
landed in slate's review environment because the test harness has
periodic timers. Filing now so the next agent doesn't need to
re-derive the diagnosis when it recurs.
