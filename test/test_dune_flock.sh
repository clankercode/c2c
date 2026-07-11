#!/usr/bin/env bash
# Smoke test for scripts/dune-build-locked.sh (B125).
#
# Covers:
#   - per-worktree local flock serialisation
#   - machine-wide global slot gate (default N=1)
#   - DUNE_CACHE / storage-mode env wiring
#   - multi-slot concurrency (N=2)
#   - wrapper dispatch under locks without invoking a real dune build
#
# Does not require a full multi-hour hang reproduction. Uses
# C2C_DUNE_WRAPPER_TEST_CMD so the test stays fast and dune-free.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$SCRIPT_DIR/scripts/dune-build-locked.sh"
TMPDIR_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/c2c-dune-flock.XXXXXX")"
cleanup() { rm -rf "$TMPDIR_ROOT"; }
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

echo "PASS: dune flock / global-gate / cache-env smoke test"
