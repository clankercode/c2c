# `just test-ocaml` deadlocks in worktrees: embedded-skill tests nested-build c2c.exe under the outer build lock

**Severity:** Medium-high (full OCaml suite cannot complete in a worktree; two
45-min watchdog burns before diagnosis)
**Status:** fixed (this commit)

## Symptom

`just test-ocaml` from a worktree (`.worktrees/<name>/`) runs ~97 suites
green, then sits silent until `DUNE_WATCHDOG_TIMEOUT` kills it (exit 124).
Tail of the log always ends right after `nudge_debounce`.

## Discovery

While gating the kimi-reenable merge (2026-07-17) two full-suite runs in
`.worktrees/kimi-merge` stalled identically (900s and 2700s watchdogs).
`pstree` on the stuck run:

```
dune runtest (holds flock _build/.c2c-build.lock via scripts/dune-build-locked.sh)
└── test_c2c_claude_skill_embedded.exe
    └── bash …/dune build --root <root> -j 2 ./ocaml/cli/c2c.exe
        └── flock            ← waiting on _build/.c2c-build.lock
```

## Root cause

`ocaml/cli/test_c2c_claude_skill_embedded.ml` (`c2c_exe_path`, previously
~line 40) **always** shelled out to `opam exec -- dune build --root
<repo_root> -j 2 ./ocaml/cli/c2c.exe` so the binary couldn't lag the test
module (made unconditional by 4cc6b82b, 2026-07-01; before that it only
built when the exe was missing). The nested build deadlocks on two layers:

1. **Dune's own `_build/.lock` (fundamental).** The outer `dune runtest`
   holds the build-directory lock `<root>/_build/.lock` for its entire
   lifetime. Any nested dune invocation against the same root blocks
   silently and indefinitely waiting for that lock — known upstream
   behavior, ocaml/dune#12685. Classic self-deadlock: outer dune waits on
   the test, the test waits on the nested build, the nested build waits on
   the outer dune's lock. This layer exists with or without
   `scripts/dune-build-locked.sh`; the earlier version of this note blamed
   `_build/.c2c-build.lock`, which the wrapper does hold, but dune's own
   `_build/.lock` alone is sufficient to hang the nested build.

2. **Dune-throttle shim slot starvation (machine-specific aggravator).**
   The opam `dune` shim on this machine is a throttle wrapper that must
   acquire a concurrency slot before delegating. Long-lived daemons can
   inherit an already-acquired slot fd across `fork`/`exec` (the shim did
   not use close-on-exec), leaking the slot; with slots starved the nested
   build can stall even in contexts where layer 1 would not apply.
   Operator-side follow-up: the throttle shim should open slot files with
   `flock -o` / O_CLOEXEC so daemons stop inheriting slot fds.

Compounding factor: in a worktree the nested root resolution can escape to
`<worktree>/_build/default` or the main checkout (see
`2026-07-15T03-55-00Z-dune-nested-worktree-root-escape.md`), so the nested
build was also building the wrong tree when it did run.

## Fix (this commit)

The nested build was redundant all along: the test's dune stanza in
`ocaml/cli/dune` already declared `(deps %{exe:c2c.exe} (file
../../.collab/skills/c2c.md))`, so dune builds `c2c.exe` before running the
test and the binary cannot lag under `runtest`. `c2c_exe_path` now locates
the binary via `Filename.dirname Sys.executable_name // "c2c.exe"` (test
exe and `c2c.exe` live in the same `_build/default/ocaml/cli/` directory —
the pattern the `test_c2c_hook_{kimi,grok,claude,codex}` suites already
use) and `Alcotest.failf`s with run-`dune build`-first guidance if the file
is missing. No `Sys.command`, no nested dune. Verified: `just build` clean,
the fixed test plus the setup/hook sibling suites pass directly, and
`just test-ocaml` now runs to completion (remaining failures are the
pre-existing environment-dependent set tracked as B226).

## Workaround (for old commits before this fix)

Run the binaries directly (no outer lock — nested build then succeeds):

```sh
cd .worktrees/<name>
scripts/dune-build-locked.sh build            # build all test exes once
for exe in _build/default/ocaml/{test,cli}/*.exe; do
  timeout 900 "$exe"                          # skip test_c2c_mcp (known CWD flake)
done
```

or `just test-slice .worktrees/<name>` from the main repo (covers
`ocaml/test` only; `ocaml/cli` exes need the loop above).
