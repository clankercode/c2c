# `just test-ocaml` deadlocks in worktrees: embedded-skill tests nested-build c2c.exe under the outer build lock

**Severity:** Medium-high (full OCaml suite cannot complete in a worktree; two
45-min watchdog burns before diagnosis)
**Status:** documented; workaround below; root fix not scheduled

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

`ocaml/cli/test_c2c_claude_skill_embedded.ml` (`c2c_exe_path`, ~line 40)
**always** shells out to `opam exec -- dune build --root <repo_root> -j 2
./ocaml/cli/c2c.exe` so the binary can't lag the test module. Under
`dune runtest` via `scripts/dune-build-locked.sh`, the outer wrapper holds
`flock _build/.c2c-build.lock` for the whole run; the opam `dune` shim takes
the same lock; the nested build therefore blocks forever — classic
self-deadlock: outer waits on test, test waits on nested build, nested build
waits on outer's lock.

Compounding factor: in a worktree the nested root resolution can escape to
`<worktree>/_build/default` or the main checkout (see
`2026-07-15T03-55-00Z-dune-nested-worktree-root-escape.md`), so the nested
build is also building the wrong tree when it does run.

The same hazard presumably applies to any `test_c2c_*_skill_embedded` test
with the always-rebuild pattern. This is pre-existing on master, unrelated to
any single branch; it also means the stale-branch suite can never be gated
from a worktree.

## Workaround

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

## Fix status / ideas

- Not fixed. Candidate fixes: make the embedded-skill tests skip the nested
  rebuild when `C2C_INSIDE_DUNE`/the lock is held (env guard), declare
  `c2c.exe` as a dune `(deps ...)` instead of shelling out (preferred — dune
  then orders it correctly), or have `dune-build-locked.sh` release the flock
  before the runtest phase.
- Until fixed: do not run `just test-ocaml` / `just check` from a worktree
  expecting completion; use the direct-binary loop.
