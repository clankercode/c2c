#!/usr/bin/env bash
# Per-worktree flock for dune invocations.
#
# Why: parallel subagents inside the same worktree can race on dune's
# internal locks, producing the "softlock" symptom where two `dune build`
# processes hang waiting on each other (filed in
# .collab/findings/2026-04-28T05-20-00Z-stanza-coder-parallel-dune-softlock.md).
# An exclusive flock on the per-worktree _build/.c2c-build.lock serialises
# same-worktree builds while leaving cross-worktree builds (separate _build/
# dirs) fully parallel.
#
# Usage:
#   scripts/dune-build-locked.sh [dune-args...]
#
# Defaults to `build` if no args are passed. Always passes `--root <worktree>`
# so the lock and the build operate on the same tree.
#
# Tunables:
#   C2C_DUNE_LOCK_WAIT_SECONDS  Optional integer; if set, wait at most that
#                               many seconds for the lock before failing
#                               (uses `flock -w`). Default: block forever.

set -euo pipefail

WORKTREE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
BUILD_DIR="$WORKTREE_ROOT/_build"
LOCK_FILE="$BUILD_DIR/.c2c-build.lock"

mkdir -p "$BUILD_DIR"
# Touch is fine even if the lock file exists; we want it to persist so
# concurrent invocations contend on the same inode.
: > "$LOCK_FILE.tmp" 2>/dev/null || true
[ -e "$LOCK_FILE" ] || mv -f "$LOCK_FILE.tmp" "$LOCK_FILE" 2>/dev/null || true
rm -f "$LOCK_FILE.tmp" 2>/dev/null || true
[ -e "$LOCK_FILE" ] || : > "$LOCK_FILE"

flock_args=()
if [ -n "${C2C_DUNE_LOCK_WAIT_SECONDS:-}" ]; then
    flock_args+=(-w "$C2C_DUNE_LOCK_WAIT_SECONDS")
fi

if [ "$#" -eq 0 ]; then
    set -- build
fi

# We always want the build to operate on this worktree, regardless of the
# caller's cwd. Inject --root after the dune subcommand (first arg).
subcmd="$1"; shift
exec flock "${flock_args[@]}" "$LOCK_FILE" \
    opam exec -- dune "$subcmd" --root "$WORKTREE_ROOT" "$@"
