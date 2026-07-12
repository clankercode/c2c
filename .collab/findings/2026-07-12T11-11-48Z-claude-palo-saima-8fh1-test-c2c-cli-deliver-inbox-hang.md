# test_c2c_cli hangs indefinitely in the deliver_inbox subtests

- **UTC:** 2026-07-12T11:11:48Z
- **Reporter:** claude-palo-saima-8fh1 (during I010 restart-stale work)
- **Severity:** medium (test-suite / CI reliability — a stuck run wedges the
  whole `test_c2c_cli` executable with no self-timeout; a human had to kill it)

## Symptom

`./_build/default/ocaml/test/test_c2c_cli.exe` runs fine to ~completion on one
invocation (~61s) but on a subsequent invocation **hung indefinitely** in the
`deliver_inbox` test group and had to be killed manually. Two separate
background runs of `dune build … && test_c2c_cli.exe` both got stuck and were
killed.

Earlier the same group reported 3 failures — but those were only
`c2c_deliver_inbox.exe: No such file or directory` (the exe was not built for
that target). After building `c2c_deliver_inbox.exe`, the rerun HUNG instead of
failing, so the hang is a distinct issue that surfaces once the daemon binary
is actually present.

## Discovery

Building `./ocaml/test/test_c2c_cli.exe ./ocaml/cli/c2c_deliver_inbox.exe`
then running the test. Not related to the I010 change under test (I010 does
not touch `c2c_deliver_inbox`); reproduced on the `i010-restart-stale` branch
but the deliver_inbox tests are untouched there.

## Likely root cause (hypothesis, not yet confirmed)

The deliver_inbox subtests spawn a `c2c_deliver_inbox --loop [--inotify]`
daemon in the background from a shell one-liner and rely on
`sleep N; kill $pid; wait $pid` to tear it down, e.g.
`ocaml/test/test_c2c_cli.ml:3400` and `:3421`:

```
… --inotify --loop … > out 2>&1 & pid=$!; sleep 1; : > unrelated; sleep 1; kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true
```

If the `--loop` daemon does not exit promptly on `SIGTERM` (blocked in an
inotify/read syscall, or traps and slow-drains), the harness's `wait $pid`
blocks forever. There is **no overall test timeout** wrapping the Alcotest run,
so one stuck daemon wedges the entire executable. `:3421` uses `kill -9` (more
robust) but `:3391`/`:3400` uses plain `kill` (SIGTERM).

Candidate tests: `test_deliver_inbox_inotify_ignores_unrelated_events`
(`:3391`), `test_deliver_inbox_register_self_enables_alias_send` (`:3412`),
`test_deliver_inbox_dry_run_does_not_drain` (`:3361`),
`test_deliver_inbox_cross_repo_alias_drains_full_body` (`:3376`).

## Suggested fix directions

1. Wrap the spawned-daemon teardown in a hard `timeout`/`kill -9` fallback so
   `wait` can never block indefinitely (replace bare `kill $pid; wait` with
   `kill $pid; for i in 1..N; do kill -0 $pid || break; sleep 0.2; done; kill -9 $pid 2>/dev/null; wait`).
2. Ensure `c2c_deliver_inbox --loop` exits promptly on SIGTERM (unblock the
   inotify/read; if it traps SIGTERM, make the handler set a stop flag the loop
   checks immediately).
3. Add a per-test / suite wall-clock guard so a hung subprocess fails fast
   instead of wedging CI.

## Status

Filed only — not fixed (out of scope for I010). I010's own tests
(`test_c2c_stale` 8/8, `test_c2c_restart_stale` 2/2) pass and are unaffected.
