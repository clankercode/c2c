# Dune escapes nested worktrees: build from `.worktrees/*` roots at the MAIN checkout

**Severity:** Medium (tooling footgun — silently builds/tests the wrong tree)
**Status:** documented workaround

## Symptom

From inside `.worktrees/<slice>/`, `dune build @ocaml/cli/runtest-...` prints
`Entering directory '/home/xertrov/src/c2c'` and then
`Error: Don't know about directory .worktrees/<slice>/ocaml/cli` — or worse,
silently builds the main checkout's code instead of the worktree's.

## Root cause

Dune walks up past the worktree to the outermost workspace marker. Because
`.worktrees/` lives *inside* the main repo directory, the main checkout wins
the root resolution.

## Workaround (verbatim)

```sh
cd .worktrees/<slice> && opam exec -- dune build --root . @ocaml/cli/runtest-<name> -j 2
```

`--root .` pins the workspace to the worktree; `opam exec --` is needed
because `--root` invocations may bypass whatever env the default path had.
`just build` / `just check` run from the worktree cwd are unaffected (they
invoke dune with the right root).
