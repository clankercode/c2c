# Pending changelog entries — fold into CHANGELOG.md at the next release

Entries staged here are ready to paste under the next `## vX.Y.Z — <date>`
heading in `data/changelog/CHANGELOG.md` (then delete them from this file).
They must NOT be added to CHANGELOG.md before the release: the agent-facing
changelog auto-show (`merged_entries`) and remote-cache fetch both read
CHANGELOG.md, and a premature version heading confuses "what's new since last
binary" surfaces (observed 2026-07-13 during B140). Note B268's passive
`update_available` / `latest_known_newer` read the *remote* cache only, not
the embedded file — still keep unreleased headings out of CHANGELOG.md.

### Passive "newer release available" nudge (B268)
summary: When the local changelog cache already knows a release newer than this binary, `c2c doctor`, `c2c health` / `server-info` (JSON fields `latest_known_version` + `update_available`), SessionStart (one line, once per newer release), and `c2c --version` (optional trailing line) surface it. Relay version-behind-latest is informational in doctor/health. Cache-only — no synchronous network on hot paths; offline/empty cache stays silent.
audience: all
setup: c2c self-update

### `c2c install git-hook` is retired (breaking)
summary: The `git-hook` install/uninstall component is gone. `c2c install git-hook` is now an unknown command and `c2c uninstall git-hook` reports an unknown component (with the remaining component list). The guard script it installed was inert in practice — the checkout's `core.hooksPath` points at the user-global hooks dir, not `.git/hooks`, so git never consulted it — and its name collided confusingly with the separate repo-local dev hooks (`scripts/git-hooks/` + `just install-git-hooks`, which are unaffected). The `git-shim` component is unchanged (kept for its active safety guards). Existing installs are no longer swept by `c2c uninstall all`; remove `.git/hooks/pre-commit` by hand if one is present.
audience: all
