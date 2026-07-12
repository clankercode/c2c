# Release landmine: changelog auto-show tests hardcoded the *next* version as a "future" sentinel

- **Severity:** medium (blocks every release ci-gate until fixed; caught pre-publish)
- **Discovered:** 2026-07-12, during the c2c 0.11.0 release
- **Fixed:** yes — commit `7aaf5181`

## Symptom

The v0.11.0 release workflow (`release.yml`) failed at `ci-gate / build-and-test`
on the **OCaml tests** step. All build/compile steps passed; the failure was a
single runtime assertion:

```
[FAIL] auto_show  4  remote-only waits then shows.
1 failure! in 0.006s. 18 tests run.
```

## Root cause

`ocaml/cli/test_c2c_changelog.ml :: test_remote_only_waits_then_shows` picked
`0.11.0` as a version that was **not yet embedded** in the changelog, to exercise
the "binary ahead of embedded changelog → auto_show waits (returns None) until a
remote cache lands" path:

```
(* Binary 0.11.0 (not embedded), last shown 0.10.0. No cache -> None ... *)
check (option string) "waits: no output yet" None out1;
```

Cutting the 0.11.0 release **embeds** `## v0.11.0` into
`data/changelog/CHANGELOG.md` (→ `c2c_changelog_embedded.ml`). Now
`auto_show ~current:"0.11.0"` finds it in the embed and returns `Some ...`
immediately, so the `None` assertion flips and the gate fails.

`test_client_filter_in_autoshow` had the identical latent bug with `0.12.0`
(would have broken the *next* release the same way).

## Why `just check` didn't catch it locally

`just check` runs `scripts/dune-build-locked.sh build` — it **compiles** the
tests but does **not run** them. The OCaml test suite only runs under
`just test-ocaml` (and in CI's ci-gate). Local release prep that only runs
`just check` will miss any release-sensitive *runtime* test failure.

## Fix

Use sentinel versions that will never be a real release (`99.x`) for the
remote-only / future-version auto-show tests, so the path stays exercised
across all future version bumps. Both tests updated in `7aaf5181`.

## Takeaways for the next release manager

1. **Run `just test-ocaml` (not just `just check`) before tagging.** The
   release ci-gate runs the full OCaml suite; `just check` only builds.
2. Never hardcode the next-in-line version number as a "future/not-embedded"
   sentinel in a test — it becomes real at the next release. Use `99.x`.
3. Moving a release tag is safe **only** when the prior run published nothing
   (verify: `gh release view vX.Y.Z` = not found, `npm view <pkg> version` still
   old). The 0.11.0 first run failed at ci-gate, so nothing was published and
   re-pointing the tag to the corrected commit was clean.
