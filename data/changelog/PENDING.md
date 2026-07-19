# Pending changelog entries — fold into CHANGELOG.md at the next release

Entries staged here are ready to paste under the next `## vX.Y.Z — <date>`
heading in `data/changelog/CHANGELOG.md` (then delete them from this file).
They must NOT be added to CHANGELOG.md before the release: the embedded
changelog feeds `update_available`, so a version heading newer than
`Version.version` makes every deployed binary print a bogus
"update available" notice (observed 2026-07-13 during B140).

### `c2c install git-hook` is retired (breaking)
summary: The `git-hook` install/uninstall component is gone. `c2c install git-hook` is now an unknown command and `c2c uninstall git-hook` reports an unknown component (with the remaining component list). The guard script it installed was inert in practice — the checkout's `core.hooksPath` points at the user-global hooks dir, not `.git/hooks`, so git never consulted it — and its name collided confusingly with the separate repo-local dev hooks (`scripts/git-hooks/` + `just install-git-hooks`, which are unaffected). The `git-shim` component is unchanged (kept for its active safety guards). Existing installs are no longer swept by `c2c uninstall all`; remove `.git/hooks/pre-commit` by hand if one is present.
audience: all
