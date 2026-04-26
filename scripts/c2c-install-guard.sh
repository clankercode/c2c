#!/usr/bin/env bash
# c2c-install-guard.sh — refuse to clobber a newer ~/.local/bin/c2c with an
# older one. Run BEFORE the cp in `just install-all`.
#
# Reads the version stamp at ~/.local/bin/.c2c-version (written by
# c2c-install-stamp.sh after a successful install) and compares its `sha`
# field against `git rev-parse HEAD` in the current working directory.
#
# Drift detection (#322): also checks that each installed binary's actual
# sha256 matches the stamp's recorded `binaries.<name>.sha256`. If any
# binary has drifted (e.g. an out-of-band `cp` or stale recipe overwrote
# the binary without updating the stamp), the guard does NOT refuse — it
# logs a loud WARN, exports C2C_INSTALL_DRIFT_DETECTED=1 (read by
# c2c-install-stamp.sh to mark the new stamp), and proceeds. Refusing
# would leave the user stuck; recovering with forensic evidence is the
# right shape. C2C_INSTALL_FORCE does NOT skip the drift check (drift is
# diagnostic, not gating; FORCE only bypasses the ancestry refuse).
#
# Exit semantics:
#   0  — safe to install (same SHA, descendant, no stamp, no .git, divergent-warn,
#        drift-detected-recover)
#   1  — REFUSE (new commit is an ancestor of installed commit, i.e. older).
#         Override with C2C_INSTALL_FORCE=1.
#
# Optional env:
#   C2C_INSTALL_FORCE=1   bypass the refuse path (drift check still runs)
#   C2C_INSTALL_QUIET=1   suppress informational messages on stderr
#   C2C_INSTALL_STAMP=PATH override the stamp path (testing)
#   C2C_INSTALL_TARGET=PATH override the target binary path (testing)
#   C2C_INSTALL_BIN_DIR=PATH override the binary install dir for drift
#                            check (testing). Default: dirname of stamp.
set -euo pipefail

stamp_file="${C2C_INSTALL_STAMP:-$HOME/.local/bin/.c2c-version}"
target_bin="${C2C_INSTALL_TARGET:-$HOME/.local/bin/c2c}"
bin_dir="${C2C_INSTALL_BIN_DIR:-$(dirname "$stamp_file")}"

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

# Drift detection (#322): for each binary the stamp records, hash the
# on-disk file and compare to the recorded sha256. Any mismatch means
# something bypassed install-all (out-of-band cp, stale individual
# recipe, dune install) and the stamp is lying. Recover-with-warning,
# don't refuse: the stamp script will write a new honest stamp with
# previous_drift_detected:true for forensic traceability.
#
# Best-effort: silent no-op if sha256sum is unavailable, the stamp lacks
# the binaries.<name>.sha256 field (older format), or the recorded path
# isn't on disk (binary missing — different bug class, not our concern).
if command -v sha256sum >/dev/null 2>&1; then
  drift_detected=0
  drifted_names=""
  # Extract a per-binary sha256 from the stamp. Format we look for:
  #   "binaries": { "c2c": { "path": "...", "sha256": "abc..." }, ... }
  # We match the FIRST sha256 inside the binaries.<name>.{...} block. If
  # the binaries section is absent (older stamp), the helper returns
  # empty and we skip silently.
  extract_binary_sha256() {
    # $1 = binary name (c2c, c2c-mcp-server, c2c-inbox-hook-ocaml, c2c-cold-boot-hook)
    # The stamp may have each binary's stanza on one line OR across multiple
    # lines. Squash newlines to spaces, then regex-extract the first
    # sha256 inside the named binary's {...} block. We anchor on the
    # opening { after the name so we don't read past into the next stanza.
    # NOTE: hex class is lowercase only because sha256sum emits lowercase.
    # If a future stamp writer uses uppercase hex this becomes a silent
    # no-op for that binary (drift undetectable). Widen to [0-9a-fA-F] if
    # that ever happens.
    tr '\n' ' ' < "$stamp_file" \
      | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*{[^}]*"sha256"[[:space:]]*:[[:space:]]*"\([0-9a-f]\+\)".*/\1/p' \
      | head -n1
  }
  check_drift() {
    # $1 = binary name, $2 = path on disk
    local name="$1" path="$2"
    local expected actual
    expected=$(extract_binary_sha256 "$name")
    [ -z "$expected" ] && return 0   # old stamp / missing field, silent
    [ -f "$path" ] || return 0       # binary missing, not our concern
    actual=$(sha256sum "$path" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
      drift_detected=1
      drifted_names="${drifted_names}${drifted_names:+, }${name}"
      log "DRIFT: $name stamp says sha256=$expected, on-disk has $actual"
    fi
  }
  check_drift "c2c"                   "$bin_dir/c2c"
  check_drift "c2c-mcp-server"        "$bin_dir/c2c-mcp-server"
  check_drift "c2c-inbox-hook-ocaml"  "$bin_dir/c2c-inbox-hook-ocaml"
  check_drift "c2c-cold-boot-hook"    "$bin_dir/c2c-cold-boot-hook"
  if [ "$drift_detected" -eq 1 ]; then
    log "WARN: install-stamp drift detected (binaries: $drifted_names)"
    log "      something bypassed install-all (out-of-band cp, stale"
    log "      individual recipe, or external install path)"
    log "      proceeding — new stamp will record previous_drift_detected:true"
    export C2C_INSTALL_DRIFT_DETECTED=1
    # Skip ancestry check: the stamp's recorded SHA is on lying data
    # (we can't trust it described what was actually installed). Better
    # to install-and-record-drift than refuse on phantom ancestry.
    exit 0
  fi
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
