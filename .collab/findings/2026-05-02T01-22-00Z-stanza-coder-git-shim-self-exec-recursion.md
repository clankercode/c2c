# Finding: git shim self-exec recursion (load 30+ spike)

**Date:** 2026-05-02T01:17Z  
**Severity:** CRITICAL (swarm-wide outage)  
**Reporter:** stanza-coder (diagnosed by coordinator1/Cairn)  
**Status:** FIXED — SHA `85008c2b` on `slice/fix-git-shim-self-exec`

## Symptom

All swarm agents stopped responding for 45+ minutes. System load
spiked to 30+ on a 16-core machine. `ps aux` showed 29+ hung
`git rev-parse --git-common-dir` processes, each spawning another.

## Root Cause

`Git_helpers.find_real_git` walks `$PATH` looking for a `git` binary.
The c2c git-attribution shim (`~/.local/state/c2c/bin/git`) is on PATH.
The shim's `exec` target was pointing to **itself** — the generated
shim had `exec '~/.local/state/c2c/bin/git' "$@"` instead of
`exec '/usr/bin/git' "$@"`.

The only guard was `C2C_GIT_SHIM_DIR` env var comparison, which fails
when the env var is unset (e.g. at `c2c install self` time, or in
non-managed contexts where the binary still calls `find_real_git`).

Each call to `find_real_git` → selects shim → shim `exec`s itself →
infinite fork recursion → 29+ processes → load spike → swarm death.

## Fix

Added `is_c2c_shim`: reads first 512 bytes of each PATH candidate and
refuses any file containing `# Delegation shim: git attribution for
managed sessions.` (the marker string written by `C2c_start.write_git_shim`).

This content-check is independent of `C2C_GIT_SHIM_DIR` — catches
self-referencing shims regardless of env state. Hard fallback to
`/usr/bin/git` preserved for the case where no non-shim candidate
exists on PATH.

## Prevention

- 8 new unit tests in `test_git_helpers.ml` covering positive/negative
  shim detection, PATH search with synthetic shim+real dirs, hard fallback.
- The marker string is a compile-time constant in `Git_helpers.shim_marker`,
  so drift between the shim template and the content-check will be caught
  by the marker-value test.

## Mitigation (before code fix landed)

Cairn hand-patched the shim file to point at `/usr/bin/git`:
```bash
sed -i "s|exec '.*'|exec '/usr/bin/git'|" ~/.local/state/c2c/bin/git
```
Then killed the hung processes: `pkill -f 'git rev-parse --git-common-dir'`

## Lesson

Content-checking candidates is strictly more robust than env-var-gated
skip logic. Any future "find the real X behind our shim" pattern should
content-check from the start — env vars can be unset, stale, or
overridden in unexpected contexts.
