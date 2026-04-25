# Dune verification processes can hang silently in heartbeat worktree

**Date:** 2026-04-25T10:16:37Z  
**Alias:** lyra-quill  
**Severity:** medium

## Symptom

While verifying generalized managed heartbeats, a targeted build command stayed
silent for more than 20 seconds:

```bash
opam exec -- dune build --root . -j1 ./ocaml/cli/c2c.exe ./ocaml/test/test_c2c_start.exe ./ocaml/test/test_c2c_role.exe
```

`ps` showed multiple stale Dune processes in the heartbeat worktree, including
older `dune exec` / `dune build @ocaml/test/runtest` processes that had been
alive for 20+ minutes.

## Impact

Verification can appear stuck with no failure output. This makes it hard to
distinguish a real compile regression from Dune/process-state wedging.

## Action Taken

Killed only the stale Dune/test processes associated with this worktree:

```bash
kill 856842 671914 694653
```

The role test executable had already passed, and the same targeted build passed
cleanly earlier before the stale processes accumulated. Full `test_c2c_start`
still has the known unrelated `cmd_reset_thread_persists_codex_resume_target`
baseline failure.

## Status

Open. Treat this as a verification reliability issue, not evidence that the
heartbeat implementation fails to compile. Prefer bounded watchdog commands
or clean process state before long OCaml verification runs.
