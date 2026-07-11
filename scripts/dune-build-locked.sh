#!/usr/bin/env bash
# Machine-wide + per-worktree gated dune invocations (B125).
#
# Why: parallel subagents — even across different worktrees — still softlock
# dune / opam (filed 2026-04-28; recurring 2026-07-11 with multi-hour hung
# builds at ~0.1% CPU). Per-worktree flock alone is insufficient because each
# worktree has its own _build/ and the hang is cross-worktree.
#
# This wrapper:
#   1. Enables Dune's shared artifact cache (cross-worktree reuse).
#   2. Acquires a machine-wide slot lock (default 1 concurrent dune).
#   3. Acquires the per-worktree _build/.c2c-build.lock.
#   4. Runs the command under scripts/dune-watchdog.sh (default 900s).
#
# Usage:
#   scripts/dune-build-locked.sh [dune-subcommand] [dune-args...]
#
# Defaults to `build` if no args are passed. Always passes `--root <worktree>`
# so the lock and the build operate on the same tree.
#
# Tunables:
#   C2C_DUNE_GLOBAL_SLOTS         Max concurrent cross-worktree dune builds
#                                 (positive integer; default: 1).
#   C2C_DUNE_GLOBAL_LOCK_DIR      Directory for global slot lock files
#                                 (default: ${XDG_CACHE_HOME:-$HOME/.cache}/c2c/dune-global).
#   C2C_DUNE_LOCK_WAIT_SECONDS    Optional integer; fail if a lock (global or
#                                 local) is not acquired within N seconds.
#   C2C_DUNE_SKIP_GLOBAL_LOCK=1   Bypass the machine-wide gate (emergency).
#   C2C_DUNE_LOCAL_LOCK_FILE      Override per-worktree lock path (tests).
#   C2C_DUNE_CACHE                Default for DUNE_CACHE when DUNE_CACHE is
#                                 unset (default: enabled). The special value
#                                 "disabled" always forces DUNE_CACHE=disabled
#                                 (opt out even if DUNE_CACHE was pre-set).
#   C2C_DUNE_CACHE_ROOT           Optional; exported as DUNE_CACHE_ROOT when
#                                 DUNE_CACHE_ROOT is unset.
#   C2C_DUNE_CACHE_STORAGE_MODE   Optional; exported as DUNE_CACHE_STORAGE_MODE
#                                 when unset (default: hardlink — same FS as
#                                 typical ~/.cache + worktree layout).
#   DUNE_WATCHDOG=0               Disable the watchdog for this call.
#   DUNE_WATCHDOG_TIMEOUT=N       Watchdog timeout seconds (default: 900).
#   C2C_DUNE_WRAPPER_TEST_CMD     Test-only: run this shell command instead of
#                                 `opam exec -- dune ...` (still under locks +
#                                 watchdog + cache env wiring).
#
# Prefer `just build` / this wrapper. Raw `opam exec -- dune build` bypasses
# every gate and is how multi-hour hangs keep happening.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
BUILD_DIR="$WORKTREE_ROOT/_build"
LOCAL_LOCK="${C2C_DUNE_LOCAL_LOCK_FILE:-$BUILD_DIR/.c2c-build.lock}"

# ---------------------------------------------------------------------------
# Shared Dune cache (cross-worktree artifact reuse)
# ---------------------------------------------------------------------------
# Dune 3.x defaults to enabled-except-user-rules; we prefer full `enabled`
# for agent rebuilds across many worktrees. Callers can still override by
# exporting DUNE_CACHE themselves before invoking the wrapper.
if [ -z "${DUNE_CACHE+x}" ]; then
    export DUNE_CACHE="${C2C_DUNE_CACHE:-enabled}"
fi
if [ "${C2C_DUNE_CACHE:-}" = "disabled" ]; then
    export DUNE_CACHE=disabled
fi

if [ -n "${C2C_DUNE_CACHE_ROOT:-}" ] && [ -z "${DUNE_CACHE_ROOT+x}" ]; then
    export DUNE_CACHE_ROOT="$C2C_DUNE_CACHE_ROOT"
fi

if [ -z "${DUNE_CACHE_STORAGE_MODE+x}" ]; then
    export DUNE_CACHE_STORAGE_MODE="${C2C_DUNE_CACHE_STORAGE_MODE:-hardlink}"
fi

# Ensure the cache root exists when we know it (avoids first-hit races).
_cache_root="${DUNE_CACHE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/dune}"
mkdir -p "$_cache_root" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Locks
# ---------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"
# Touch is fine even if the lock file exists; we want it to persist so
# concurrent invocations contend on the same inode.
if [ ! -e "$LOCAL_LOCK" ]; then
    : > "$LOCAL_LOCK" 2>/dev/null || true
fi
# Parent of an overridden local lock path may not exist (tests).
mkdir -p "$(dirname -- "$LOCAL_LOCK")"
[ -e "$LOCAL_LOCK" ] || : > "$LOCAL_LOCK"

SLOTS="${C2C_DUNE_GLOBAL_SLOTS:-1}"
case "$SLOTS" in
    ''|*[!0-9]*)
        echo "c2c dune-build-locked: C2C_DUNE_GLOBAL_SLOTS must be a positive integer (got: ${SLOTS})" >&2
        exit 2
        ;;
esac
if [ "$SLOTS" -lt 1 ]; then
    echo "c2c dune-build-locked: C2C_DUNE_GLOBAL_SLOTS must be >= 1 (got: ${SLOTS})" >&2
    exit 2
fi

GLOBAL_DIR="${C2C_DUNE_GLOBAL_LOCK_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/c2c/dune-global}"
mkdir -p "$GLOBAL_DIR"

flock_wait_args=()
if [ -n "${C2C_DUNE_LOCK_WAIT_SECONDS:-}" ]; then
    flock_wait_args+=(-w "$C2C_DUNE_LOCK_WAIT_SECONDS")
fi

# Acquire one machine-wide slot on a dynamically allocated FD (bash {fd}).
# Held for the lifetime of this process (inherited by flock → watchdog →
# dune children). Released automatically when this shell exits.
_C2C_DUNE_GLOBAL_FD=""
acquire_global_slot() {
    if [ "${C2C_DUNE_SKIP_GLOBAL_LOCK:-0}" = "1" ]; then
        return 0
    fi

    local i lock start_ts now
    start_ts=$(date +%s)

    while true; do
        for i in $(seq 0 $((SLOTS - 1))); do
            lock="$GLOBAL_DIR/slot-$i.lock"
            : >> "$lock" 2>/dev/null || : > "$lock"
            # Close any previous probe FD before opening the next slot file.
            if [ -n "${_C2C_DUNE_GLOBAL_FD}" ]; then
                # shellcheck disable=SC2094
                exec {_C2C_DUNE_GLOBAL_FD}>&-
                _C2C_DUNE_GLOBAL_FD=""
            fi
            # Dynamically allocate an FD so we do not clobber a caller's FD 9.
            exec {_C2C_DUNE_GLOBAL_FD}>>"$lock"
            if flock -n "${_C2C_DUNE_GLOBAL_FD}"; then
                return 0
            fi
            exec {_C2C_DUNE_GLOBAL_FD}>&-
            _C2C_DUNE_GLOBAL_FD=""
        done

        if [ -n "${C2C_DUNE_LOCK_WAIT_SECONDS:-}" ]; then
            now=$(date +%s)
            if [ $((now - start_ts)) -ge "$C2C_DUNE_LOCK_WAIT_SECONDS" ]; then
                echo "c2c dune-build-locked: timed out after ${C2C_DUNE_LOCK_WAIT_SECONDS}s waiting for a global dune slot (${SLOTS} slots under $GLOBAL_DIR)" >&2
                return 1
            fi
        fi

        # Avoid busy-spin: block briefly on slot-0 (released immediately
        # via `true`), then re-scan all slots. If slot-0 is free but others
        # are the contended ones, the non-blocking loop above still wins.
        if [ -e "$GLOBAL_DIR/slot-0.lock" ]; then
            flock -w 2 "$GLOBAL_DIR/slot-0.lock" true 2>/dev/null || sleep 0.2
        else
            sleep 0.2
        fi
    done
}

acquire_global_slot

if [ "$#" -eq 0 ]; then
    set -- build
fi

subcmd="$1"
shift

TIMEOUT="${DUNE_WATCHDOG_TIMEOUT:-900}"

run_under_local_lock() {
    # Local serialisation (same-worktree) + watchdog + real dune (or test cmd).
    if [ -n "${C2C_DUNE_WRAPPER_TEST_CMD:-}" ]; then
        flock "${flock_wait_args[@]}" "$LOCAL_LOCK" \
            "$SCRIPT_DIR/dune-watchdog.sh" "$TIMEOUT" \
            bash -c "$C2C_DUNE_WRAPPER_TEST_CMD"
        return
    fi

    flock "${flock_wait_args[@]}" "$LOCAL_LOCK" \
        "$SCRIPT_DIR/dune-watchdog.sh" "$TIMEOUT" \
        opam exec -- dune "$subcmd" --root "$WORKTREE_ROOT" "$@"
}

run_under_local_lock "$@"
