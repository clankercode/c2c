#!/usr/bin/env bash
# Smoke test for scripts/dune-build-locked.sh (B125).
#
# Covers:
#   - per-worktree local flock serialisation
#   - machine-wide global slot gate (default N=1)
#   - DUNE_CACHE / storage-mode env wiring
#   - multi-slot concurrency (N=2)
#   - wrapper dispatch under locks without invoking a real dune build
#   - stale-holder reaper: reclaims an orphaned zero-CPU holder, spares a
#     holder that is doing real work, bounds the queue wait, warns on bypass
#     (#70)
#
# Does not require a full multi-hour hang reproduction. Uses
# C2C_DUNE_WRAPPER_TEST_CMD so the test stays fast and dune-free.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$SCRIPT_DIR/scripts/dune-build-locked.sh"
TMPDIR_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/c2c-dune-flock.XXXXXX")"
# Every synthetic lock holder records its pid under $TMPDIR_ROOT/*.pid so an
# interrupted or timed-out run cannot leak a detached (setsid) holder — one
# CPU-burning stray escaped an early run of this file and had to be reaped by
# hand. Guarded on the cmdline so a recycled pid is never signalled.
cleanup() {
    local f pid cmd
    for f in "$TMPDIR_ROOT"/*.pid; do
        [ -f "$f" ] || continue
        pid="$(cat "$f" 2>/dev/null || true)"
        [ -n "$pid" ] || continue
        cmd="$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline" || true)"
        case "$cmd" in
            *"sleep 300"*|*"while :"*)
                pkill -9 -P "$pid" 2>/dev/null || true
                kill -9 "$pid" 2>/dev/null || true
                ;;
        esac
    done
    rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT

LOCAL_LOCK="$TMPDIR_ROOT/local.lock"
GLOBAL_DIR="$TMPDIR_ROOT/global"
mkdir -p "$GLOBAL_DIR"
: > "$LOCAL_LOCK"

export C2C_DUNE_LOCAL_LOCK_FILE="$LOCAL_LOCK"
export C2C_DUNE_GLOBAL_LOCK_DIR="$GLOBAL_DIR"
export DUNE_WATCHDOG=0

# ---------------------------------------------------------------------------
# 1) Local flock serialisation (same lock file the wrapper uses)
# ---------------------------------------------------------------------------
( flock "$LOCAL_LOCK" sleep 2 ) &
holder_pid=$!
sleep 0.2

if flock -n "$LOCAL_LOCK" true; then
    echo "FAIL: local lock was not held when expected" >&2
    kill "$holder_pid" 2>/dev/null || true
    exit 1
fi
echo "ok: second non-blocking attempt correctly blocked while first held the lock"

wait "$holder_pid"

if ! flock -n "$LOCAL_LOCK" true; then
    echo "FAIL: local lock not released after holder exited" >&2
    exit 1
fi
echo "ok: local lock released cleanly after holder exited"

# ---------------------------------------------------------------------------
# 2) Global slot gate (N=1): holder blocks a second wrapper invocation
# ---------------------------------------------------------------------------
: > "$GLOBAL_DIR/slot-0.lock"
( flock "$GLOBAL_DIR/slot-0.lock" sleep 3 ) &
gholder_pid=$!
sleep 0.2

# Non-blocking probe of the same slot file the wrapper uses.
if flock -n "$GLOBAL_DIR/slot-0.lock" true; then
    echo "FAIL: global slot-0 was not held when expected" >&2
    kill "$gholder_pid" 2>/dev/null || true
    exit 1
fi
echo "ok: global slot-0 held by concurrent peer"

# Wrapper with 1s wait should time out while the holder is alive.
set +e
C2C_DUNE_GLOBAL_SLOTS=1 \
C2C_DUNE_LOCK_WAIT_SECONDS=1 \
C2C_DUNE_WRAPPER_TEST_CMD='echo SHOULD_NOT_RUN' \
    "$WRAPPER" build >"$TMPDIR_ROOT/timeout.out" 2>"$TMPDIR_ROOT/timeout.err"
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
    echo "FAIL: wrapper should have timed out waiting for global slot" >&2
    echo "stdout: $(cat "$TMPDIR_ROOT/timeout.out")" >&2
    echo "stderr: $(cat "$TMPDIR_ROOT/timeout.err")" >&2
    kill "$gholder_pid" 2>/dev/null || true
    exit 1
fi
if ! grep -q 'timed out' "$TMPDIR_ROOT/timeout.err"; then
    echo "FAIL: expected timeout message on stderr" >&2
    echo "stderr: $(cat "$TMPDIR_ROOT/timeout.err")" >&2
    kill "$gholder_pid" 2>/dev/null || true
    exit 1
fi
if grep -q 'SHOULD_NOT_RUN' "$TMPDIR_ROOT/timeout.out"; then
    echo "FAIL: test cmd ran despite global slot contention" >&2
    kill "$gholder_pid" 2>/dev/null || true
    exit 1
fi
echo "ok: global gate timed out cleanly under contention (N=1)"

wait "$gholder_pid" 2>/dev/null || true

# After release, wrapper should proceed.
out="$(
C2C_DUNE_GLOBAL_SLOTS=1 \
C2C_DUNE_LOCK_WAIT_SECONDS=5 \
C2C_DUNE_WRAPPER_TEST_CMD='echo ran-after-release' \
    "$WRAPPER" build
)"
if [ "$out" != "ran-after-release" ]; then
    echo "FAIL: expected ran-after-release, got: $out" >&2
    exit 1
fi
echo "ok: global gate allows run after slot release"

# ---------------------------------------------------------------------------
# 3) DUNE_CACHE env wiring
# ---------------------------------------------------------------------------
# Default: wrapper sets DUNE_CACHE=enabled when unset.
cache_out="$(
env -u DUNE_CACHE -u DUNE_CACHE_STORAGE_MODE -u C2C_DUNE_CACHE \
    C2C_DUNE_LOCAL_LOCK_FILE="$LOCAL_LOCK" \
    C2C_DUNE_GLOBAL_LOCK_DIR="$GLOBAL_DIR" \
    DUNE_WATCHDOG=0 \
    C2C_DUNE_GLOBAL_SLOTS=1 \
    C2C_DUNE_WRAPPER_TEST_CMD='printf "CACHE=%s MODE=%s\n" "${DUNE_CACHE-}" "${DUNE_CACHE_STORAGE_MODE-}"' \
    "$WRAPPER" build
)"
if [ "$cache_out" != "CACHE=enabled MODE=hardlink" ]; then
    echo "FAIL: expected CACHE=enabled MODE=hardlink, got: $cache_out" >&2
    exit 1
fi
echo "ok: DUNE_CACHE defaults to enabled + hardlink storage mode"

# Explicit DUNE_CACHE in environment is preserved.
cache_out="$(
DUNE_CACHE=enabled-except-user-rules \
C2C_DUNE_GLOBAL_SLOTS=1 \
C2C_DUNE_WRAPPER_TEST_CMD='printf "CACHE=%s\n" "${DUNE_CACHE-}"' \
    "$WRAPPER" build
)"
if [ "$cache_out" != "CACHE=enabled-except-user-rules" ]; then
    echo "FAIL: explicit DUNE_CACHE not preserved, got: $cache_out" >&2
    exit 1
fi
echo "ok: explicit DUNE_CACHE preserved"

# C2C_DUNE_CACHE=disabled opts out.
cache_out="$(
env -u DUNE_CACHE \
    C2C_DUNE_LOCAL_LOCK_FILE="$LOCAL_LOCK" \
    C2C_DUNE_GLOBAL_LOCK_DIR="$GLOBAL_DIR" \
    DUNE_WATCHDOG=0 \
    C2C_DUNE_CACHE=disabled \
    C2C_DUNE_GLOBAL_SLOTS=1 \
    C2C_DUNE_WRAPPER_TEST_CMD='printf "CACHE=%s\n" "${DUNE_CACHE-}"' \
    "$WRAPPER" build
)"
if [ "$cache_out" != "CACHE=disabled" ]; then
    echo "FAIL: C2C_DUNE_CACHE=disabled not honoured, got: $cache_out" >&2
    exit 1
fi
echo "ok: C2C_DUNE_CACHE=disabled opts out of shared cache"

# C2C_DUNE_CACHE_ROOT exported when DUNE_CACHE_ROOT unset.
cache_root="$TMPDIR_ROOT/dune-cache-root"
cache_out="$(
env -u DUNE_CACHE_ROOT \
    C2C_DUNE_LOCAL_LOCK_FILE="$LOCAL_LOCK" \
    C2C_DUNE_GLOBAL_LOCK_DIR="$GLOBAL_DIR" \
    DUNE_WATCHDOG=0 \
    C2C_DUNE_CACHE_ROOT="$cache_root" \
    C2C_DUNE_GLOBAL_SLOTS=1 \
    C2C_DUNE_WRAPPER_TEST_CMD='printf "ROOT=%s\n" "${DUNE_CACHE_ROOT-}"' \
    "$WRAPPER" build
)"
if [ "$cache_out" != "ROOT=$cache_root" ]; then
    echo "FAIL: C2C_DUNE_CACHE_ROOT not exported, got: $cache_out" >&2
    exit 1
fi
if [ ! -d "$cache_root" ]; then
    echo "FAIL: cache root was not created: $cache_root" >&2
    exit 1
fi
echo "ok: C2C_DUNE_CACHE_ROOT exported and created"

# ---------------------------------------------------------------------------
# 4) Multi-slot (N=2): two concurrent wrappers can both run
# ---------------------------------------------------------------------------
# Hold only slot-0; with SLOTS=2 the wrapper should take slot-1 and run.
: > "$GLOBAL_DIR/slot-0.lock"
: > "$GLOBAL_DIR/slot-1.lock"
( flock "$GLOBAL_DIR/slot-0.lock" sleep 2 ) &
s0_pid=$!
sleep 0.2

out="$(
C2C_DUNE_GLOBAL_SLOTS=2 \
C2C_DUNE_LOCK_WAIT_SECONDS=5 \
C2C_DUNE_WRAPPER_TEST_CMD='echo multi-slot-ok' \
    "$WRAPPER" build
)"
if [ "$out" != "multi-slot-ok" ]; then
    echo "FAIL: N=2 should acquire free slot-1; got: $out" >&2
    kill "$s0_pid" 2>/dev/null || true
    exit 1
fi
echo "ok: multi-slot (N=2) uses a free slot while another is held"

wait "$s0_pid" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5) C2C_DUNE_SKIP_GLOBAL_LOCK bypass
# ---------------------------------------------------------------------------
( flock "$GLOBAL_DIR/slot-0.lock" sleep 2 ) &
s0_pid=$!
sleep 0.2
out="$(
C2C_DUNE_GLOBAL_SLOTS=1 \
C2C_DUNE_SKIP_GLOBAL_LOCK=1 \
C2C_DUNE_LOCK_WAIT_SECONDS=5 \
C2C_DUNE_WRAPPER_TEST_CMD='echo skip-global-ok' \
    "$WRAPPER" build
)"
if [ "$out" != "skip-global-ok" ]; then
    echo "FAIL: SKIP_GLOBAL_LOCK should bypass contention; got: $out" >&2
    kill "$s0_pid" 2>/dev/null || true
    exit 1
fi
echo "ok: C2C_DUNE_SKIP_GLOBAL_LOCK=1 bypasses global gate"
wait "$s0_pid" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 6) Invalid SLOTS rejected
# ---------------------------------------------------------------------------
set +e
C2C_DUNE_GLOBAL_SLOTS=0 \
C2C_DUNE_WRAPPER_TEST_CMD='true' \
    "$WRAPPER" build >/dev/null 2>"$TMPDIR_ROOT/badslots.err"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    echo "FAIL: SLOTS=0 should be rejected" >&2
    exit 1
fi
echo "ok: C2C_DUNE_GLOBAL_SLOTS=0 rejected"

# ---------------------------------------------------------------------------
# 7) Stale-holder reaper (#70): reclaim a wedged, zero-CPU slot holder
# ---------------------------------------------------------------------------
# Synthetic stale holder: a setsid'd process that takes the flock and then
# `exec sleep`s, so it is orphaned (ppid 1) and accumulates no CPU at all —
# the exact shape of the ~46h orphans that wedged every build on the box.
stale_pidfile="$TMPDIR_ROOT/stale.pid"
: > "$GLOBAL_DIR/slot-0.lock"
setsid sh -c '
    echo $$ > "'"$stale_pidfile"'"
    exec 9>>"'"$GLOBAL_DIR"'/slot-0.lock"
    flock 9
    exec sleep 300
' &
disown %% 2>/dev/null || true
sleep 0.5
stale_pid="$(cat "$stale_pidfile")"
kill_stale() { kill -9 "$stale_pid" 2>/dev/null || true; }

if flock -n "$GLOBAL_DIR/slot-0.lock" true; then
    echo "FAIL: synthetic stale holder did not take slot-0" >&2
    kill_stale
    exit 1
fi
echo "ok: synthetic stale holder (orphaned, 0 CPU) holds slot-0"

set +e
out="$(
C2C_DUNE_GLOBAL_SLOTS=1 \
C2C_DUNE_STALE_AGE_SECONDS=0 \
C2C_DUNE_REAP_AFTER_SECONDS=0 \
C2C_DUNE_QUEUE_TIMEOUT=30 \
C2C_DUNE_WRAPPER_TEST_CMD='echo reaped-and-ran' \
    "$WRAPPER" build 2>"$TMPDIR_ROOT/reap.err"
)"
rc=$?
set -e
if [ "$rc" -ne 0 ] || [ "$out" != "reaped-and-ran" ]; then
    echo "FAIL: reaper did not reclaim the stale slot (rc=$rc, out=$out)" >&2
    cat "$TMPDIR_ROOT/reap.err" >&2
    kill_stale
    exit 1
fi
if ! grep -q 'reclaiming stale dune slot' "$TMPDIR_ROOT/reap.err"; then
    echo "FAIL: reaper did not announce the reclaim" >&2
    cat "$TMPDIR_ROOT/reap.err" >&2
    kill_stale
    exit 1
fi
if kill -0 "$stale_pid" 2>/dev/null; then
    echo "FAIL: stale holder $stale_pid survived the reap" >&2
    kill_stale
    exit 1
fi
if [ ! -s "$GLOBAL_DIR/reaper.log" ]; then
    echo "FAIL: reap was not logged to $GLOBAL_DIR/reaper.log" >&2
    exit 1
fi
echo "ok: reaper reclaimed the stale slot, killed the holder, and logged why"

# ---------------------------------------------------------------------------
# 8) Reaper must NOT touch a holder that is doing real work
# ---------------------------------------------------------------------------
# Same shape, but with a CPU-burning descendant: the holder shell itself burns
# ~0 CPU while a build runs underneath it, so only the whole-tree CPU check
# distinguishes this from case 7. Getting this wrong would kill live builds.
busy_pidfile="$TMPDIR_ROOT/busy.pid"
live_pidfile="$TMPDIR_ROOT/live.pid"
: > "$GLOBAL_DIR/slot-0.lock"
setsid sh -c '
    echo $$ > "'"$live_pidfile"'"
    exec 9>>"'"$GLOBAL_DIR"'/slot-0.lock"
    flock 9
    sh -c "echo \$\$ > '"$busy_pidfile"'; while :; do :; done" &
    exec sleep 300
' &
disown %% 2>/dev/null || true
sleep 1
live_pid="$(cat "$live_pidfile")"
busy_pid="$(cat "$busy_pidfile")"
kill_live() { kill -9 "$busy_pid" "$live_pid" 2>/dev/null || true; }

set +e
C2C_DUNE_GLOBAL_SLOTS=1 \
C2C_DUNE_STALE_AGE_SECONDS=0 \
C2C_DUNE_REAP_AFTER_SECONDS=0 \
C2C_DUNE_QUEUE_TIMEOUT=3 \
C2C_DUNE_WRAPPER_TEST_CMD='echo SHOULD_NOT_RUN' \
    "$WRAPPER" build >"$TMPDIR_ROOT/live.out" 2>"$TMPDIR_ROOT/live.err"
rc=$?
set -e
if [ "$rc" -eq 0 ] || grep -q 'SHOULD_NOT_RUN' "$TMPDIR_ROOT/live.out"; then
    echo "FAIL: wrapper ran despite a live (CPU-burning) slot holder" >&2
    kill_live
    exit 1
fi
if ! kill -0 "$live_pid" 2>/dev/null; then
    echo "FAIL: reaper killed a live slot holder — the concurrency guard is broken" >&2
    kill_live
    exit 1
fi
if ! grep -q 'timed out' "$TMPDIR_ROOT/live.err"; then
    echo "FAIL: expected a loud queue timeout, got: $(cat "$TMPDIR_ROOT/live.err")" >&2
    kill_live
    exit 1
fi
if ! grep -q 'slot-0 holder:' "$TMPDIR_ROOT/live.err"; then
    echo "FAIL: queue timeout did not report who holds the slot" >&2
    kill_live
    exit 1
fi
echo "ok: live holder spared; waiter failed loudly with holder diagnostics"
kill_live
sleep 0.3

# ---------------------------------------------------------------------------
# 9) Bounded queue wait by default (no C2C_DUNE_LOCK_WAIT_SECONDS)
# ---------------------------------------------------------------------------
( flock "$GLOBAL_DIR/slot-0.lock" sleep 5 ) &
q_pid=$!
sleep 0.2
set +e
env -u C2C_DUNE_LOCK_WAIT_SECONDS \
    C2C_DUNE_LOCAL_LOCK_FILE="$LOCAL_LOCK" \
    C2C_DUNE_GLOBAL_LOCK_DIR="$GLOBAL_DIR" \
    DUNE_WATCHDOG=0 \
    C2C_DUNE_GLOBAL_SLOTS=1 \
    C2C_DUNE_QUEUE_TIMEOUT=2 \
    C2C_DUNE_REAPER=0 \
    C2C_DUNE_WRAPPER_TEST_CMD='echo SHOULD_NOT_RUN' \
    "$WRAPPER" build >"$TMPDIR_ROOT/queue.out" 2>"$TMPDIR_ROOT/queue.err"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    echo "FAIL: unbounded queue wait — wrapper should have given up" >&2
    kill "$q_pid" 2>/dev/null || true
    exit 1
fi
if ! grep -q 'queueing forever' "$TMPDIR_ROOT/queue.err"; then
    echo "FAIL: expected the loud #70 queue-timeout message" >&2
    cat "$TMPDIR_ROOT/queue.err" >&2
    kill "$q_pid" 2>/dev/null || true
    exit 1
fi
echo "ok: queue wait is bounded even without C2C_DUNE_LOCK_WAIT_SECONDS"
wait "$q_pid" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 10) Bypass warns loudly
# ---------------------------------------------------------------------------
out="$(
C2C_DUNE_GLOBAL_SLOTS=1 \
C2C_DUNE_SKIP_GLOBAL_LOCK=1 \
C2C_DUNE_WRAPPER_TEST_CMD='echo bypass-ok' \
    "$WRAPPER" build 2>"$TMPDIR_ROOT/bypass.err"
)"
if [ "$out" != "bypass-ok" ]; then
    echo "FAIL: bypass should still run the build; got: $out" >&2
    exit 1
fi
if ! grep -q 'concurrency guard is OFF' "$TMPDIR_ROOT/bypass.err"; then
    echo "FAIL: bypass did not warn that the guard is off" >&2
    cat "$TMPDIR_ROOT/bypass.err" >&2
    exit 1
fi
echo "ok: C2C_DUNE_SKIP_GLOBAL_LOCK=1 warns loudly on stderr"

echo "PASS: dune flock / global-gate / cache-env / reaper smoke test"
