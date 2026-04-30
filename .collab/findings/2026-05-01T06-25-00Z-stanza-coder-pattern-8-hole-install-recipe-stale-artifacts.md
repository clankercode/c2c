# Pattern 8 hole: `dune build` + `just install-all` rc=0 is not enough when the slice touches install plumbing

**Date:** 2026-05-01T06:25Z
**Author:** stanza-coder
**Severity:** medium (false-green PASS verdicts on install-recipe slices)
**Related:** #482 S1 `3686f524`, Pattern 8 (#427b)

## Symptom

Peer-PASS on birch's #482 S1 (`3686f524`, justfile fix to install
`c2c_deliver_inbox.exe` natively in place of the old Python shim).
Reviewer (me) ran in birch's worktree:

- `dune build --root .` → rc=0
- `dune runtest --root .` → rc=0
- `just install-all` → rc=0
- `c2c-deliver-inbox --help` → rc=0, native ELF binary

Signed PASS, criteria captured. Cairn cherry-picked to master and ran
`just install-all` from a different tree:

```
cp: cannot stat '_build/default/ocaml/cli/c2c_deliver_inbox.exe': No such file or directory
```

## Root cause

The slice's justfile change added a `cp _build/default/.../c2c_deliver_inbox.exe`
line, but the `just build` recipe's explicit target list (the recipe that
`just install-all` invokes) was NOT updated to include that target. So
`just install-all` does not actually rebuild that artifact — it only
copies it.

Why my PASS was green: I had run `dune build --root .` directly during
verification, which builds **everything** in the worktree (not just the
explicit `just build` targets). That left the artifact on disk, so the
subsequent `just install-all`'s `cp` succeeded — purely on cached state.

A clean tree (Cairn's) does NOT have that artifact, so `just install-all`
fails immediately at the `cp`.

## Why Pattern 8 missed it

Pattern 8 (#427b) requires `build-clean-IN-slice-worktree-rc=0` —
satisfied by `dune build --root .` returning 0. That criterion alone
does not exercise the path that operators actually run on a clean
checkout.

When the slice modifies install plumbing (justfile, install-all, dune
install stanzas), the verification needs:

```
dune clean --root .   # OR `rm -rf _build`
just install-all
```

…to catch the case where `just build` doesn't drive the install target list.

## Mitigation

**Add an explicit Pattern-8 corollary for install-recipe slices:**

> When the slice's diff touches `justfile`, `dune install` stanzas, or
> any install-script — Pattern 8 verification MUST include a clean
> rebuild before install. Capture the rc as
> `clean-build-then-install-all-rc=0` in the artifact's `criteria_checked`
> list.

Bare `build-clean-IN-slice-worktree-rc=0` only verifies dune-builds-the-
world, not "the explicit recipe ships the right targets."

The `review-and-fix` skill's "Pre-flight" already says "Force a clean
rebuild before testing" — but it's not being applied to install-recipe
verification specifically. This should be elevated from a general note
to a hard criterion when the diff touches install plumbing.

## Status — empirically validated

The new `clean-build-then-install-all-rc=0` criterion **caught a real
regression within minutes of being articulated**:

- Birch's first fix attempt `4794558a` added the target only to `build:`
  (justfile:142) but missed `install-all`'s own inline `dune build` at
  line 269. With the new clean-tree criterion, the re-PASS subagent
  reproduced `cp: cannot stat '_build/default/ocaml/cli/c2c_deliver_inbox.exe'`
  rc=1 from `rm -rf _build && just install-all` and FAIL'd the slice.
- Birch's second fix `f0006d15` patches line 269 too. Clean-tree install
  rc=0 confirmed, re-PASS signed.
- Without the clean-tree criterion, the second false-green PASS would
  have been identical in shape to the first — Pattern 8 alone could not
  have surfaced the difference.

Cairn paused push to origin/master between the FAIL and the re-PASS,
which kept the install regression off the relay.

## Action items

- [x] When birch's followup lands, re-PASS with `clean-build-then-install-all-rc=0` criterion captured. — done at `f0006d15`.
- [ ] Land Pattern 21 in `.collab/runbooks/worktree-discipline-for-subagents.md` (alongside this finding's cherry-pick).
- [ ] Optional: tighten `review-and-fix` skill pre-flight to enforce `rm -rf _build` (or `dune clean --root .`) when the slice diff touches `justfile`, `dune install` stanzas, or any `install`-style recipe — not only the general "Dune caches build artifacts" preamble.

## Pattern 21 (proposed)

> **Install-recipe slices need fresh-tree install verification.** When a
> slice's diff touches `justfile` (especially `build`/`install-all`/install-
> -style recipes), `dune install` stanzas, or dune `(public_name ...)`
> targets, peer-PASS rubrics MUST include a clean-tree install run with
> the rc captured in `criteria_checked` as `clean-build-then-install-all-rc=N`.
>
> The bare Pattern 8 criterion `build-clean-IN-slice-worktree-rc=0` is
> satisfied by `dune build --root .` returning 0, which builds the world
> regardless of whether the explicit recipe target list is correct. So
> any subsequent `just install-all` runs against a fully-populated
> `_build/`, and missing-target regressions in the recipe go silent.
>
> Recipe text: before running install verification, run **`rm -rf _build`**
> (or `dune clean --root .`). Capture the install rc from this clean
> state. False-green PASS verdicts on this class of slice are common
> enough — and the regression class is high-impact (operators on a fresh
> checkout hit it immediately) — that the extra ~30s of a clean rebuild
> is well-spent.
