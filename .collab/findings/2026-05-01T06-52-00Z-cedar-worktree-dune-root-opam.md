# Finding: worktree `dune --root` + opam discovery failure (#553 follow-on)

**Date:** 2026-05-01
**Alias:** cedar-coder
**Severity:** medium (worktree gotcha for test-only slices)

## Symptom

When running `dune runtest --root <worktree-ocaml-dir>` inside a worktree,
dune fails with:

```
Error: The current project defines some public elements, but no opam packages
are defined. Please add a <package>.opam file at the project root so that
these elements are installed into it.
```

Even when `c2c.opam` exists at the **worktree root** (not the ocaml subdir).

## Root Cause

The `dune-workspace` file at the worktree root has `(lang dune 3.12)`, but
the `dune-project` has `(lang dune 3.21)`. The workspace lang version
(3.12) predates features needed by the project (3.21).

When `dune --root ocaml/` is invoked from the worktree root, it appears to
scan upward for `dune-workspace` and uses the workspace lang version for
opam package resolution, finding no opam file at the (workspace-level)
root — even though the dune project (which it ignores when `--root` points
to a subdir) would have the package declaration.

In contrast, `dune runtest --root ocaml/` from the **main repo** works fine
because the main repo's dune-workspace also uses `(lang dune 3.12)` but the
main repo has no `public` executables in the `cli/` dune file — so the opam
check doesn't fire.

## Discovery Path

1. Fresh worktree created from `c2b939cf` (origin/master tip)
2. Added test file + dune stanza
3. `dune runtest --root ocaml/` in worktree → "no opam packages" error
4. Created `c2c.opam` at worktree root — error persists
5. Confirmed main repo `just test-ocaml` (which uses `dune runtest --root "$PWD" ocaml/`
   from main repo root) works fine
6. Concluded: worktree `--root` path triggers a different code path in dune's
   opam discovery

## Workaround

Verify test-only slices via `just test-ocaml` from the main repo (which uses
`--root "$PWD"` pointing at the main repo root). Build the test binary there,
confirm all tests pass, then commit from the worktree.

## Fix (for next slice author)

For a proper fix, the worktree's `dune-workspace` lang version should be bumped
to 3.21 (matching the dune-project), OR the worktree should have its own
`dune-project` at the worktree root level (not just in the ocaml/ subdir).

The worktree IS from the same git clone as the main repo, so the dune-project
and dune-workspace files are identical. The issue appears to be purely
dune's opam-package scanning triggered by `public_name` in the `cli/dune` file
when `--root` points into a subdirectory.

## Status

**Low priority to fix** — workaround (`just test-ocaml` from main repo) is
reliable and verified. This finding is filed for the next test-only slice
author who hits the same error.
