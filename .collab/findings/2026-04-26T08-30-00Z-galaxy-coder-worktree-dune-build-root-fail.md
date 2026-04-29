# Finding: dune build --root fails for git worktrees

**Date**: 2026-04-26T08:30:00Z
**Alias**: galaxy-coder
**Severity**: medium (workflow friction, not a bug)

## Symptom

`opam exec -- dune build --root /path/to/worktree ocaml/cli/c2c.exe` fails with:

```
Error: Don't know how to build ocaml/cli/c2c.exe
Leaving directory '/path/to/worktree'
```

Even though:
- The worktree has its own `dune-project` and `dune` file
- The `.git` in the worktree is a real directory (not a file)
- `git -C /path/to/worktree status` works correctly
- Dune correctly enters the worktree directory

## Root Cause

Dune 3.12 uses a workspace-root discovery mechanism that looks for `dune-workspace` (or `dune-project`) starting from the **current working directory** of the **dune process**, not from the `--root` argument. When `opam exec -- dune build --root /path/to/worktree` is run from the **main repo**, dune discovers the main repo's `dune-workspace` first and treats the `--root` path as a **target** within that workspace rather than a workspace root itself.

The `--root` flag in dune is intended for **changing the root for resolution of relative paths**, not for switching workspace context. Dune's multi-workspace design requires the worktree to be set up as a proper dune workspace root.

## Workaround

Two options that work:

### Option A: Run from within the worktree directory (subshell)
```bash
(cd /path/to/worktree && opam exec -- dune build ocaml/cli/c2c.exe)
```
This works because the CWD is the worktree, so dune finds the worktree's `dune-workspace` first.

### Option B: Use `DUNE_ROOT` env var + `--root` together
```bash
cd /path/to/worktree && DUNE_ROOT=/path/to/worktree opam exec -- dune build --root /path/to/worktree ocaml/cli/c2c.exe
```
The `cd` to the worktree first ensures the CWD context is correct.

## Fix Status

Not fixed — this is a dune workspace discovery behavior. The workaround (Option A) is documented here for future reference. No code change needed in c2c.

## Affected Agents

Any agent working in `.worktrees/<slice>/` and trying to build OCaml code from outside the worktree directory.
