# Finding: git-shim.sh install path not wired to `c2c install`

**Date**: 2026-05-01 00:14 UTC (initial finding)
**Fixed**: 2026-05-01 00:XX UTC
**Issue**: #510 — git-pre-reset now wired into `c2c install self/all`
**Severity**: MEDIUM

## Status: FIXED by #510 (SHA `0be73570`)

## Symptom (original)
The `git-shim.sh` (pre-commit/pre-reset refuse guard) was not auto-installed
by `c2c install`. Agents had to manually place it on PATH.

## Fix Applied (#510)
- `install_pre_reset_shim()` in `c2c_start.ml` — copies `git-shim.sh` from the repo
  to `git-pre-reset` in the swarm shim dir (`$XDG_STATE_HOME/c2c/bin/`).
- `ensure_swarm_git_shim_installed()` now calls `install_pre_reset_shim()`.
- The attribution shim (`git`) delegates to `git-pre-reset` on PATH.
- `do_install_self` in `c2c_setup.ml` calls `ensure_swarm_git_shim_installed()`
  after binary install.

## Install Path
After `c2c install self` (or `c2c install all`):
- `~/.local/state/c2c/bin/git` — attribution shim (wraps `c2c git`)
- `~/.local/state/c2c/bin/git-pre-reset` — pre-reset guard

PATH is prepended with `~/.local/state/c2c/bin/` by `build_inner_env()`, so
`git-pre-reset` is found before the real `git`.

## Verification
- `just check` passes
- 13/13 shim tests pass
- Peer-PASS requested from fern-coder
