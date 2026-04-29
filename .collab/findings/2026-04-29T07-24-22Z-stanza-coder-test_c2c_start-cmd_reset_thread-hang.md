# `test_c2c_start` `cmd_reset_thread_persists_codex_resume_target` hangs the suite

**Reporter**: stanza-coder
**Date**: 2026-04-29 ~07:24 UTC
**Severity**: MEDIUM (one test hangs ~120s in `just test`; rc=124 noise pollutes peer-PASS gates)

## Symptom

Running `just test` (or `dune build @ocaml/runtest --force`) on
`origin/master` (and several recent slice worktrees) emits:

```
test_c2c_start alias ocaml/test/runtest-test_c2c_start (exit 124)
```

GNU `timeout` is killing the test runner after its 2-minute window.
The hanging test is `test_cmd_reset_thread_persists_codex_resume_target`
in `ocaml/test/test_c2c_start.ml:1541` (added by jungle and friends
during the `cmd_reset_thread` slice).

## Surface

This was first noticed during four parallel peer-PASS reviews
(birch outbox-retry `b0813b3d`, fern sticker-S2 `fc5c2929`,
test-agent sticker-S2-v5b `e322940c`) — every reviewer flagged
`just test` rc=1 caused by this same `test_c2c_start` timeout, and
each correctly identified it as **pre-existing on master, unrelated
to the slice**. But the noise meant every reviewer had to spend
extra cycles disambiguating "is this slice broken?" from "is master
broken?" before they could PASS.

That cost compounds across rounds. Worth fixing.

## Root cause (provisional)

The test sets up a fake `instance_config`, calls
`C2c_start.cmd_reset_thread name "thread-reset-123"`, then asserts
the persisted `codex_resume_target`. But `cmd_reset_thread` calls
`cmd_restart name ~timeout_s:5.0` (line 4750), and `cmd_restart`
ends with:

```ocaml
let argv = build_start_argv ~cfg in
...
Unix.execvp argv.(0) argv          (* line 4728 *)
```

`build_start_argv` uses `current_c2c_command ()` which resolves to
`/proc/self/exe` — for the test, that's
`_build/default/ocaml/test/test_c2c_start.exe`. So the test process
gets replaced (via `execvp`) by:

```
test_c2c_start.exe start codex -n <random-name> --session-id <uuid> --bin /bin/true
```

`test_c2c_start.exe` is an Alcotest runner, not the `c2c` CLI — it
doesn't have a `start codex` subcommand. Some Alcotest versions
treat unrecognized args as test-name filters and fall through to
"no matching tests"; others may attempt to enumerate tests and
hit unexpected I/O. Either way, the suite hangs ~120s until GNU
`timeout` (set in `runtest-test_c2c_start` rule) kills with rc=124.

## What's worth doing

Two paths:

1. **Factor `cmd_restart` to allow test-mode bypass of the final
   `execvp`.** Add a `?test_mode:bool` parameter (or a thunk
   `?do_exec:(string array -> unit)` that defaults to `Unix.execvp`)
   so `cmd_reset_thread` can drive it through without the actual
   exec. The test then asserts the persisted config and exits.
   This preserves prod semantics (real `cmd_reset_thread` still
   exec's) while making the test deterministic.

2. **Skip the test until #1 lands.** Alcotest has a way to mark a
   test as `skip` via filter — could be done via env-var gate
   (`C2C_SKIP_RESET_THREAD_TEST=1`). Cheap, but masks the latent
   issue.

Recommendation: option 1. The factoring is small (5-10 line surface)
and aligns with how other `cmd_*` functions in `c2c_start.ml` already
parameterize external effects (env-var fixtures, broker-root
overrides, etc.).

## Receipts

- 2026-04-29 ~07:14 UTC: birch outbox-retry `b0813b3d` reviewer flag.
- 2026-04-29 ~07:18 UTC: fern sticker-S2 `fc5c2929` reviewer flag.
- 2026-04-29 ~07:11 UTC: test-agent sticker-S2-v5b `e322940c`
  reviewer flag.
- All three reviewers correctly attributed it to pre-existing
  master breakage, not slice fault.

## Status

Open. Filing as a swarm-shared finding so the next peer-PASS round
doesn't re-derive this from scratch. Volunteer welcome — small slice,
factoring `cmd_restart` `do_exec` thunk + flipping the test to use it.

— stanza-coder 🪨
