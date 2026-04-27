#!/usr/bin/env bash
# c2c-install-guard.sh — refuse to clobber a newer ~/.local/bin/c2c with an
# older one. Run BEFORE the cp in `just install-all`.
#
# Reads the version stamp at ~/.local/bin/.c2c-version (written by
# c2c-install-stamp.sh after a successful install) and compares its `sha`
# field against `git rev-parse HEAD` in the current working directory.
#
# Exit semantics:
#   0  — safe to install (same SHA, descendant, no stamp, no .git, divergent-warn)
#   1  — REFUSE (new commit is an ancestor of installed commit, i.e. older).
#         Override with C2C_INSTALL_FORCE=1.
#
# Optional env:
#   C2C_INSTALL_FORCE=1   bypass the refuse path
#   C2C_INSTALL_QUIET=1   suppress informational messages on stderr
#   C2C_INSTALL_STAMP=PATH override the stamp path (testing)
#   C2C_INSTALL_TARGET=PATH override the target binary path (testing)
set -euo pipefail

stamp_file="${C2C_INSTALL_STAMP:-$HOME/.local/bin/.c2c-version}"
target_bin="${C2C_INSTALL_TARGET:-$HOME/.local/bin/c2c}"

log() {
  if [ "${C2C_INSTALL_QUIET:-0}" != "1" ]; then
    printf '[c2c install-guard] %s\n' "$*" >&2
  fi
}

# Nothing currently installed → nothing to clobber.
if [ ! -f "$target_bin" ]; then
  exit 0
fi

# No stamp from a previous install → first guarded install. Proceed; the
# stamp script will write one after cp.
if [ ! -f "$stamp_file" ]; then
  log "no version stamp found — first guarded install, proceeding"
  exit 0
fi

# Not in a git repo (e.g. tarball install) → no ancestry to check.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  log "not in a git repo — guard is a no-op"
  exit 0
fi

new_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
if [ -z "$new_sha" ]; then
  log "git rev-parse HEAD failed — guard is a no-op"
  exit 0
fi

# Extract a string field from the stamp without requiring jq. The stamp is
# our own format so a simple sed is safe.
extract_field() {
  sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$stamp_file" | head -n1
}

old_sha=$(extract_field sha)
old_alias=$(extract_field alias)
old_worktree=$(extract_field worktree)

if [ -z "$old_sha" ]; then
  log "stamp at $stamp_file has no sha field — proceeding (will rewrite stamp)"
  exit 0
fi

# Same SHA → no-op.
if [ "$old_sha" = "$new_sha" ]; then
  exit 0
fi

# If the recorded SHA isn't reachable from this repo (e.g. installed from a
# different clone), we can't compare ancestry meaningfully — proceed with a
# warning so the user notices.
if ! git cat-file -e "$old_sha" 2>/dev/null; then
  log "WARN: installed sha $old_sha is not reachable from this repo —"
  log "      proceeding (cross-clone install). previous: ${old_alias:-?} @ ${old_worktree:-?}"
  exit 0
fi

# new is an ancestor of old → REFUSE (would clobber newer with older).
if git merge-base --is-ancestor "$new_sha" "$old_sha" 2>/dev/null; then
  log "REFUSE: new install ($new_sha) is older than current install ($old_sha)."
  log "  current: ${old_alias:-?} @ ${old_worktree:-?}"
  log "  this:    ${C2C_MCP_AUTO_REGISTER_ALIAS:-${USER:-?}} @ $PWD"
  log "  Set C2C_INSTALL_FORCE=1 to override."
  if [ "${C2C_INSTALL_FORCE:-0}" = "1" ]; then
    log "C2C_INSTALL_FORCE=1 — overriding refuse, proceeding."
    exit 0
  fi
  exit 1
fi

# old is an ancestor of new → linear progress, proceed silently.
if git merge-base --is-ancestor "$old_sha" "$new_sha" 2>/dev/null; then
  exit 0
fi

# Divergent → warn but proceed (both branches contain commits the other
# doesn't; either could be "right").
log "WARN: installing divergent SHA ($new_sha) over ($old_sha by ${old_alias:-?})"
exit 0
