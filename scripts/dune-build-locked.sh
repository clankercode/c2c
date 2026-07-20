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
#                                 Explicit value wins over C2C_DUNE_QUEUE_TIMEOUT.
#   C2C_DUNE_QUEUE_TIMEOUT        Default bound on the *queue* wait when
#                                 C2C_DUNE_LOCK_WAIT_SECONDS is unset
#                                 (default: 2 x DUNE_WATCHDOG_TIMEOUT). #70: the
#                                 watchdog bounded the build but the queue wait
#                                 was unbounded, so a wedged holder hung every
#                                 later build forever — and a hang reads as test
#                                 flakiness, which is expensive to debug. 0
#                                 restores the old unbounded behaviour.
#   C2C_DUNE_REAPER=0             Disable the stale-holder reaper (#70).
#   C2C_DUNE_STALE_AGE_SECONDS    A slot holder is reclaimable only once it is
#                                 this old (default: 1800; must exceed the
#                                 watchdog so a legitimately long build is never
#                                 a candidate).
#   C2C_DUNE_REAP_AFTER_SECONDS   Only start scanning for stale holders after
#                                 waiting this long (default: 60) — ordinary
#                                 contention never pays for a /proc scan.
#   C2C_DUNE_SKIP_GLOBAL_LOCK=1   Bypass the machine-wide gate (emergency).
#                                 Prints a loud warning: with the gate off, a
#                                 subsequent load spike is on this invocation.
#                                 Note it does NOT drop the opam switch — the
#                                 wrapper still runs `opam exec -- dune`. A
#                                 "Library yojson not found" storm means a
#                                 hand-rolled `dune` call outside the wrapper,
#                                 not this flag.
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
# Recorded in the slot owner file so a human can see what took the slot
# without reconstructing it from `ps`.
INVOCATION="$*"
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

TIMEOUT="${DUNE_WATCHDOG_TIMEOUT:-900}"

# Bound the queue wait (#70). An explicit C2C_DUNE_LOCK_WAIT_SECONDS still
# wins; otherwise we derive a default from the watchdog. Two watchdog periods
# is deliberately generous — one full-length build ahead of us in the queue is
# normal contention, two is a wedge.
if [ -n "${C2C_DUNE_LOCK_WAIT_SECONDS:-}" ]; then
    QUEUE_TIMEOUT="$C2C_DUNE_LOCK_WAIT_SECONDS"
else
    QUEUE_TIMEOUT="${C2C_DUNE_QUEUE_TIMEOUT:-$((TIMEOUT * 2))}"
fi
case "$QUEUE_TIMEOUT" in
    ''|*[!0-9]*)
        echo "c2c dune-build-locked: queue timeout must be a non-negative integer (got: ${QUEUE_TIMEOUT})" >&2
        exit 2
        ;;
esac

flock_wait_args=()
if [ "$QUEUE_TIMEOUT" -gt 0 ]; then
    # -E: a conflict/timeout exits 111 so we can tell it apart from the built
    # command's own exit code 1.
    flock_wait_args+=(-w "$QUEUE_TIMEOUT" -E 111)
fi

# ---------------------------------------------------------------------------
# Stale-holder reaper (#70)
# ---------------------------------------------------------------------------
# Observed failure: `flock` processes orphaned by dead shells sat on
# slot-0.lock for ~46 hours having consumed 0 seconds of CPU, blocking every
# build on the machine. A *dead* holder is not the problem — the kernel drops
# its flock automatically. The problem is a live-but-wedged process (or an
# orphan that inherited the lock fd), so reclaiming the slot means killing
# something. That is destructive, hence the conservative rules below.

REAPER_LOG="$GLOBAL_DIR/reaper.log"
_CLK_TCK="$(getconf CLK_TCK 2>/dev/null || echo 100)"
declare -A _PPID_OF=()
declare -A _CPU_OF=()
declare -A _START_OF=()

# Echo "<ppid> <utime+stime ticks> <starttime ticks>" for a pid.
_proc_stat_fields() {
    local line rest
    line="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
    # comm (field 2) is parenthesised and may contain spaces; skip past it so
    # positional splitting lines up: $1 == field 3 (state).
    rest="${line##*) }"
    [ "$rest" != "$line" ] || return 1
    # shellcheck disable=SC2086
    set -- $rest
    [ "$#" -ge 20 ] || return 1
    printf '%s %s %s\n' "$2" "$(( ${12} + ${13} ))" "${20}"
}

# One pass over /proc, so a reaper cycle sees a consistent-enough snapshot.
_snapshot_procs() {
    local d pid fields
    _PPID_OF=(); _CPU_OF=(); _START_OF=()
    for d in /proc/[0-9]*; do
        pid="${d#/proc/}"
        fields="$(_proc_stat_fields "$pid")" || continue
        # shellcheck disable=SC2086
        set -- $fields
        _PPID_OF["$pid"]="$1"
        _CPU_OF["$pid"]="$2"
        _START_OF["$pid"]="$3"
    done
}

# CPU ticks consumed by a pid *and every descendant*. The wrapper shell itself
# burns ~0 CPU while a real build runs underneath it, so per-process CPU alone
# would flag a healthy holder as stale. The whole tree at 0 is the real signal.
_tree_cpu_ticks() {
    local root="$1" total=0 p a hops
    for p in "${!_CPU_OF[@]}"; do
        a="$p"; hops=0
        while [ -n "$a" ] && [ "$a" != "0" ] && [ "$hops" -lt 64 ]; do
            if [ "$a" = "$root" ]; then
                total=$(( total + ${_CPU_OF[$p]} ))
                break
            fi
            a="${_PPID_OF[$a]:-}"
            hops=$(( hops + 1 ))
        done
    done
    printf '%s\n' "$total"
}

# Pids (this uid only — we could not signal others anyway) holding the lock
# file open. Authoritative superset of the flock holder: flock locks live on
# the open file description, so an inherited fd in an orphan keeps the lock
# held even after the process that took it has exited.
#
# `[ -ef ]` (same device+inode, symlinks followed) rather than readlink: it is
# a shell builtin, so a process holding tens of thousands of fds costs stats
# instead of that many forks. The readlink version took minutes on this box.
_lock_fd_holders() {
    local lock_real="$1" d pid fd
    for d in /proc/[0-9]*; do
        pid="${d#/proc/}"
        [ -r "$d/fd" ] || continue
        for fd in "$d"/fd/*; do
            if [ "$fd" -ef "$lock_real" ]; then
                printf '%s\n' "$pid"
                break
            fi
        done
    done
}

# Our own pid plus every ancestor — never a reap candidate (a parent wrapper
# may legitimately have handed us the fd).
_self_and_ancestors() {
    local a="$$" hops=0
    while [ -n "$a" ] && [ "$a" != "0" ] && [ "$hops" -lt 64 ]; do
        printf '%s\n' "$a"
        a="${_PPID_OF[$a]:-}"
        hops=$(( hops + 1 ))
    done
}

_holder_describe() {
    local pid="$1" age="$2" cpu="$3"
    printf 'pid=%s ppid=%s age=%ss tree_cpu=%sticks cmd=%s' \
        "$pid" "${_PPID_OF[$pid]:-?}" "$age" "$cpu" \
        "$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline" || echo '<gone>')"
}

# Reclaim a slot only if EVERY process holding its lock file is provably idle:
#   * age >= C2C_DUNE_STALE_AGE_SECONDS (> the watchdog, so a long but real
#     build is never a candidate), and
#   * 0 CPU ticks across the holder and all of its descendants — nothing is
#     building under it, and a real build accumulates CPU immediately.
# All-or-nothing: killing a subset while another process keeps the fd open
# would be destructive *and* pointless, so any live holder aborts the pass.
# Returns 0 if it reclaimed the slot.
reclaim_stale_slot() {
    local lock="$1"
    [ "${C2C_DUNE_REAPER:-1}" = "1" ] || return 1

    local stale_age="${C2C_DUNE_STALE_AGE_SECONDS:-1800}"
    case "$stale_age" in ''|*[!0-9]*) return 1 ;; esac

    local lock_real
    lock_real="$(readlink -f "$lock" 2>/dev/null)" || return 1

    local -a candidates=()
    mapfile -t candidates < <(_lock_fd_holders "$lock_real")
    [ "${#candidates[@]}" -gt 0 ] || return 1

    _snapshot_procs

    local -A skip=()
    local a
    while read -r a; do skip["$a"]=1; done < <(_self_and_ancestors)

    local uptime_s rest pid age cpu
    read -r uptime_s rest < /proc/uptime || return 1
    uptime_s="${uptime_s%.*}"

    local -a doomed=()
    local -a reasons=()
    for pid in "${candidates[@]}"; do
        [ -z "${skip[$pid]:-}" ] || return 1          # our own tree: never reap
        [ -n "${_START_OF[$pid]:-}" ] || continue      # exited under us: fine
        age=$(( uptime_s - ${_START_OF[$pid]} / _CLK_TCK ))
        [ "$age" -ge "$stale_age" ] || return 1        # too young to judge
        cpu="$(_tree_cpu_ticks "$pid")"
        [ "$cpu" -eq 0 ] || return 1                   # something is building
        doomed+=("$pid")
        reasons+=("$(_holder_describe "$pid" "$age" "$cpu")")
    done
    [ "${#doomed[@]}" -gt 0 ] || return 1

    # Log before we act, so a reap is attributable even if we die mid-way.
    {
        printf '%s reclaiming %s (stale_age=%ss)\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$lock" "$stale_age"
        printf '  %s\n' "${reasons[@]}"
    } >>"$REAPER_LOG" 2>/dev/null || true
    echo "c2c dune-build-locked: reclaiming stale dune slot $lock (#70); killing idle holders:" >&2
    printf 'c2c dune-build-locked:   %s\n' "${reasons[@]}" >&2

    # #75: re-verify starttime immediately before signalling so a recycled
    # pid cannot be mis-killed. Field 22 of /proc/<pid>/stat is starttime
    # (clock ticks after boot) — same identity pin as #52 EXIT-trap.
    local -a still_doomed=()
    local p snap_st live_st
    for p in "${doomed[@]}"; do
        snap_st="${_START_OF[$p]:-}"
        [ -n "$snap_st" ] || continue
        live_st="$(awk '{print $22}' "/proc/$p/stat" 2>/dev/null || true)"
        if [ -z "$live_st" ]; then
            continue  # already exited
        fi
        if [ "$live_st" != "$snap_st" ]; then
            echo "c2c dune-build-locked: skip pid $p — starttime changed (recycled; #75)" >&2
            printf '%s skip recycled pid %s (snap=%s live=%s)\n'                 "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$p" "$snap_st" "$live_st"                 >>"$REAPER_LOG" 2>/dev/null || true
            continue
        fi
        still_doomed+=("$p")
    done
    [ "${#still_doomed[@]}" -gt 0 ] || return 1
    doomed=("${still_doomed[@]}")

    kill -TERM "${doomed[@]}" 2>/dev/null || true
    local waited=0
    while [ "$waited" -lt 20 ]; do
        local alive=0 p
        for p in "${doomed[@]}"; do
            if kill -0 "$p" 2>/dev/null; then alive=1; fi
        done
        [ "$alive" -eq 1 ] || break
        sleep 0.1
        waited=$(( waited + 1 ))
    done
    # Re-verify again before KILL (same race window).
    still_doomed=()
    for p in "${doomed[@]}"; do
        snap_st="${_START_OF[$p]:-}"
        live_st="$(awk '{print $22}' "/proc/$p/stat" 2>/dev/null || true)"
        [ -n "$live_st" ] && [ "$live_st" = "$snap_st" ] && still_doomed+=("$p")
    done
    [ "${#still_doomed[@]}" -gt 0 ] || return 0
    kill -KILL "${still_doomed[@]}" 2>/dev/null || true
    echo "c2c dune-build-locked: reaped ${#doomed[@]} stale holder(s); see $REAPER_LOG" >&2
    return 0
}

# Diagnostic for the loud queue-timeout path: who is actually sitting on the
# slots, so the operator does not have to reconstruct it from `ps`.
report_slot_holders() {
    local i lock lock_real pid uptime_s rest age cpu
    _snapshot_procs
    read -r uptime_s rest < /proc/uptime || return 0
    uptime_s="${uptime_s%.*}"
    for i in $(seq 0 $((SLOTS - 1))); do
        lock="$GLOBAL_DIR/slot-$i.lock"
        lock_real="$(readlink -f "$lock" 2>/dev/null)" || continue
        while read -r pid; do
            [ -n "${_START_OF[$pid]:-}" ] || continue
            age=$(( uptime_s - ${_START_OF[$pid]} / _CLK_TCK ))
            cpu="$(_tree_cpu_ticks "$pid")"
            echo "c2c dune-build-locked:   slot-$i holder: $(_holder_describe "$pid" "$age" "$cpu")" >&2
        done < <(_lock_fd_holders "$lock_real")
    done
}

# Acquire one machine-wide slot on a dynamically allocated FD (bash {fd}).
# Held for the lifetime of this process (inherited by flock → watchdog →
# dune children). Released automatically when this shell exits.
_C2C_DUNE_GLOBAL_FD=""
_C2C_DUNE_SLOT_OWNER_FILE=""

# Record who holds the slot. Advisory only — the reaper's authority is the
# /proc fd scan, because an owner file can be stale, missing (older wrapper,
# hard kill) or describe a process whose inherited fd outlived it. This exists
# so a human reading the lock dir can see what took the slot.
_write_slot_owner() {
    local lock="$1"
    _C2C_DUNE_SLOT_OWNER_FILE="${lock%.lock}.owner"
    {
        printf 'pid=%s\nstarted=%s\nworktree=%s\ncmd=%s\n' \
            "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$WORKTREE_ROOT" "$INVOCATION"
    } >"$_C2C_DUNE_SLOT_OWNER_FILE" 2>/dev/null || true
}
_clear_slot_owner() {
    [ -n "$_C2C_DUNE_SLOT_OWNER_FILE" ] || return 0
    rm -f "$_C2C_DUNE_SLOT_OWNER_FILE" 2>/dev/null || true
}
trap _clear_slot_owner EXIT

acquire_global_slot() {
    if [ "${C2C_DUNE_SKIP_GLOBAL_LOCK:-0}" = "1" ]; then
        # Loud on purpose (#70): a quiet bypass makes the next load spike
        # unattributable. The opam switch is NOT affected — we still run
        # `opam exec -- dune` below.
        echo "c2c dune-build-locked: WARNING — C2C_DUNE_SKIP_GLOBAL_LOCK=1: the machine-wide dune concurrency guard is OFF for this build." >&2
        echo "c2c dune-build-locked: WARNING — this build can run alongside every other dune on the box; keep -j low (2) and expect load spikes to be attributed here." >&2
        echo "c2c dune-build-locked: WARNING — if the gate looked wedged, prefer letting the stale-holder reaper run (#70) over bypassing." >&2
        return 0
    fi

    local i lock start_ts now waited last_reap=0
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
                _write_slot_owner "$lock"
                return 0
            fi
            exec {_C2C_DUNE_GLOBAL_FD}>&-
            _C2C_DUNE_GLOBAL_FD=""
        done

        now=$(date +%s)
        waited=$(( now - start_ts ))

        if [ "$QUEUE_TIMEOUT" -gt 0 ] && [ "$waited" -ge "$QUEUE_TIMEOUT" ]; then
            echo "c2c dune-build-locked: timed out after ${waited}s waiting for a global dune slot (${SLOTS} slots under $GLOBAL_DIR)" >&2
            report_slot_holders
            echo "c2c dune-build-locked: failing loudly rather than queueing forever (#70). Inspect the holders above; raise C2C_DUNE_QUEUE_TIMEOUT if the wait is legitimate." >&2
            return 1
        fi

        # Periodically look for a wedged holder to reclaim (#70). Gated on a
        # grace period so normal contention never pays for the /proc scan.
        if [ "$waited" -ge "${C2C_DUNE_REAP_AFTER_SECONDS:-60}" ] \
           && [ $(( now - last_reap )) -ge 30 ]; then
            last_reap="$now"
            for i in $(seq 0 $((SLOTS - 1))); do
                reclaim_stale_slot "$GLOBAL_DIR/slot-$i.lock" || true
            done
        fi

        # Avoid busy-spin. Deliberately a plain sleep: the old code blocked on
        # slot-0 via a child `flock`, which is exactly the process that piled
        # up as an orphaned waiter in #70. One second of latency on a build
        # queue is free; unbounded orphaned waiters were not.
        sleep 1
    done
}

acquire_global_slot

if [ "$#" -eq 0 ]; then
    set -- build
fi

subcmd="$1"
shift

run_under_local_lock() {
    # Local serialisation (same-worktree) + watchdog + real dune (or test cmd).
    # The same queue bound applies here (#70): the per-worktree lock could hang
    # forever on a wedged sibling just as the global one could. flock -E 111
    # lets us tell "never got the lock" apart from "the build exited 1".
    local rc=0
    if [ -n "${C2C_DUNE_WRAPPER_TEST_CMD:-}" ]; then
        flock "${flock_wait_args[@]}" "$LOCAL_LOCK" \
            "$SCRIPT_DIR/dune-watchdog.sh" "$TIMEOUT" \
            bash -c "$C2C_DUNE_WRAPPER_TEST_CMD" || rc=$?
    else
        flock "${flock_wait_args[@]}" "$LOCAL_LOCK" \
            "$SCRIPT_DIR/dune-watchdog.sh" "$TIMEOUT" \
            opam exec -- dune "$subcmd" --root "$WORKTREE_ROOT" "$@" || rc=$?
    fi

    if [ "$rc" -eq 111 ] && [ "$QUEUE_TIMEOUT" -gt 0 ]; then
        echo "c2c dune-build-locked: timed out after ${QUEUE_TIMEOUT}s waiting for the per-worktree lock $LOCAL_LOCK" >&2
        echo "c2c dune-build-locked: another build in this worktree is holding it; failing loudly rather than queueing forever (#70)." >&2
        return 1
    fi
    return "$rc"
}

run_under_local_lock "$@"
