# Post-Shim-Incident Code Health Audit

**Filed by:** stanza-coder
**Date:** 2026-05-02T03:40:00Z
**Scope:** #609/#610/#611 emergency fixes + circuit-breaker + shim installation
**Severity:** Mixed (1 HIGH fix, 1 MEDIUM fix, findings for backlog)

## Fixes Applied (this audit)

### 1. Circuit breaker logging bug (HIGH)
**File:** `ocaml/Git_helpers.ml:91-103`
**Bug:** `logged_this_trip <- false` was set on line 95 immediately before
the `not git_counter.logged_this_trip` check on line 96, making the
condition always true. The "log once per trip epoch" intent was defeated —
the circuit breaker would log on EVERY spawn attempt after trip, creating
log spam during overload.
**Origin:** Commit `6519cd7b` (birch's Phase 2A circuit-breaker).
**Fix:** Removed the premature `logged_this_trip <- false` assignment.
The flag is already `false` at initialization and stays `false` until the
first log, then is set `true` to suppress subsequent logs within the same
trip epoch. `reset_git_circuit_breaker()` resets it for test isolation.

### 2. Missing git-pre-reset in per-instance shim (MEDIUM)
**File:** `ocaml/c2c_start.ml:3954-3967`
**Bug:** `ensure_swarm_git_shim_installed()` installs both the attribution
shim (`git`) and the pre-reset guard (`git-pre-reset`). The per-instance
defense-in-depth path at line 3965 only installed the attribution shim,
not `git-pre-reset`. If the swarm shim dir became inaccessible, the
per-instance fallback would have an incomplete shim set.
**Fix:** Added `install_pre_reset_shim ~dir:shim_bin_dir` with a warning
on failure, matching the swarm install pattern.

### 3. Stale incident backup cleanup (LOW)
**Location:** `~/.local/state/c2c/bin/`
**Issue:** Four stale backup files from the shim incident were still
present: `git.bak`, `git.disabled-incident-2026-05-02`,
`git.DISABLED.shim-recursion`, `git-pre-reset.disabled-incident-2026-05-02`.
**Fix:** Removed manually. No automated cleanup exists — consider adding
to `c2c install self` or a `c2c install cleanup` subcommand.

## Findings (backlog / no fix needed now)

### Test coverage gaps in Git_helpers.ml
11 of 18 functions lack direct unit test coverage. The emergency-fix
surface (is_c2c_shim, find_real_git, circuit breaker) is well-tested.
Untested functions are mostly git plumbing wrappers (git_common_dir,
git_repo_toplevel, git_shorthash, etc.) where failures are fail-safe
(return None/[]). Circuit breaker threshold/backoff unit tests would
improve confidence but aren't blocking.

### Circuit breaker env vars undocumented in CLAUDE.md
`C2C_GIT_SPAWN_WINDOW`, `C2C_GIT_SPAWN_MAX`, `C2C_GIT_BACKOFF_SEC`
are documented in Git_helpers.ml code comments and the design doc but
not in CLAUDE.md § Env vars or the env-vars runbook. Low priority —
these are tuning knobs, not operational switches.

### Shell-level pgrep guard performance
`git-shim.sh:29-38` runs `pgrep -c -f "git-shim|git-pre-reset"` on
every git invocation. Acceptable for now — the OCaml circuit breaker
is the primary defense, the shell guard is belt-and-suspenders. Would
matter if git call volume was much higher.

## Verdict
The #609/#610/#611 emergency fixes are solid. Two bugs found and fixed
(circuit breaker logging, per-instance pre-reset gap). No dead code,
no inconsistencies in shim marker strings, no silent error swallowing
in critical paths. Test coverage is good on the emergency-fix surface.
