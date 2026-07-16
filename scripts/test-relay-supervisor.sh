#!/usr/bin/env bash
# Regression tests for the production relay supervisor (B219).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SUPERVISOR="$ROOT/scripts/relay-supervisor.sh"
REAPER_SOURCE="$ROOT/scripts/relay-child-reaper.c"
TMP=$(mktemp -d)
REAPER="$TMP/c2c-relay-child-reaper"

cleanup() {
    if [[ -n "${SIGNAL_SUPERVISOR_PID:-}" ]]; then
        kill -KILL "$SIGNAL_SUPERVISOR_PID" 2>/dev/null || true
        wait "$SIGNAL_SUPERVISOR_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

run_supervisor() {
    local diag_dir=$1
    shift
    C2C_RELAY_CHILD_REAPER="$REAPER" \
    C2C_RELAY_DIAG_DIR="$diag_dir" \
    C2C_RELAY_HEALTH_URL=http://127.0.0.1:1/health \
    C2C_RELAY_HEALTH_INTERVAL=0.1 \
    C2C_RELAY_HEALTH_TIMEOUT=1 \
    C2C_RELAY_HEALTH_FAILURE_THRESHOLD=2 \
        "$SUPERVISOR" "$@"
}

[[ -x "$SUPERVISOR" ]] || fail "missing executable $SUPERVISOR"
cc -std=c11 -O2 -Wall -Wextra -Werror -o "$REAPER" "$REAPER_SOURCE" \
    || fail "could not compile wait-status helper"

echo "[relay-supervisor-test] reaper temp writes do not follow symlinks"
symlink_diag="$TMP/symlink"
mkdir -p "$symlink_diag"
symlink_target="$TMP/symlink-target"
printf '%s\n' safe >"$symlink_target"
set +e
"$REAPER" --pid-file "$symlink_diag/pid" \
    --status-file "$symlink_diag/status" -- sh -c \
    'ln -s "$1" "$2.tmp.$PPID"; exit 7' sh \
    "$symlink_target" "$symlink_diag/status"
symlink_status=$?
set -e
[[ $symlink_status -eq 7 ]] || fail "symlink probe child status changed"
[[ $(cat "$symlink_target") == safe ]] \
    || fail "reaper followed a child-created status symlink"

echo "[relay-supervisor-test] preexisting metadata symlinks are removed"
metadata_symlink_diag="$TMP/metadata-symlink"
mkdir -p "$metadata_symlink_diag"
metadata_target="$TMP/metadata-target"
printf '%s\n' safe >"$metadata_target"
ln -s "$metadata_target" "$metadata_symlink_diag/lifecycle.jsonl"
run_supervisor "$metadata_symlink_diag" true
[[ $(cat "$metadata_target") == safe ]] \
    || fail "supervisor followed a preexisting lifecycle symlink"

echo "[relay-supervisor-test] child exit is persisted"
exit_diag="$TMP/exit"
set +e
run_supervisor "$exit_diag" sh -c 'exit 7'
exit_status=$?
set -e
[[ $exit_status -eq 7 ]] || fail "expected supervisor exit 7, got $exit_status"
grep -q '"event":"child_exit".*"status":7' "$exit_diag/lifecycle.jsonl" \
    || fail "child exit status was not recorded"
[[ ! -e "$exit_diag/active-run" ]] || fail "clean child exit left active-run marker"

echo "[relay-supervisor-test] native-style signals are classified"
signal_exit_diag="$TMP/signal-exit"
set +e
run_supervisor "$signal_exit_diag" sh -c 'ulimit -c 0; kill -SEGV $$'
signal_exit_status=$?
set -e
[[ $signal_exit_status -eq 139 ]] \
    || fail "expected supervisor exit 139, got $signal_exit_status"
grep -q '"event":"child_signaled".*"status":139.*"signal_number":11' \
    "$signal_exit_diag/lifecycle.jsonl" \
    || fail "child signal was not classified"
grep -q '"event":"core_file_missing"' "$signal_exit_diag/lifecycle.jsonl" \
    || fail "missing core was not made explicit"

echo "[relay-supervisor-test] explicit high exit codes are not called signals"
high_exit_diag="$TMP/high-exit"
set +e
run_supervisor "$high_exit_diag" sh -c 'exit 139'
high_exit_status=$?
set -e
[[ $high_exit_status -eq 139 ]] \
    || fail "expected explicit exit 139, got $high_exit_status"
grep -q '"event":"child_exit".*"status":139' \
    "$high_exit_diag/lifecycle.jsonl" \
    || fail "explicit exit 139 was not recorded as an exit"
if grep -q '"event":"child_signaled"' "$high_exit_diag/lifecycle.jsonl"; then
    fail "explicit exit 139 was misclassified as a signal"
fi

echo "[relay-supervisor-test] later ledger failures do not replace child status"
write_failure_diag="$TMP/write-failure"
mkdir -p "$write_failure_diag"
set +e
run_supervisor "$write_failure_diag" sh -c \
    'chmod 0400 "$1/lifecycle.jsonl"; exit 9' sh "$write_failure_diag"
write_failure_status=$?
set -e
chmod 0600 "$write_failure_diag/lifecycle.jsonl"
[[ $write_failure_status -eq 9 ]] \
    || fail "ledger failure replaced child status 9 with $write_failure_status"

echo "[relay-supervisor-test] an interrupted prior run is detected"
unclean_diag="$TMP/unclean"
mkdir -p "$unclean_diag"
printf '%s\n' 'prior-run-id' >"$unclean_diag/active-run"
run_supervisor "$unclean_diag" true
grep -q '"event":"previous_run_unclean".*"previous_run_id":"prior-run-id"' \
    "$unclean_diag/lifecycle.jsonl" \
    || fail "unclean prior run was not recorded"

echo "[relay-supervisor-test] interrupted capture temps are pruned on startup"
stale_capture_diag="$TMP/stale-capture"
mkdir -p "$stale_capture_diag"
: >"$stale_capture_diag/health-failure-old.txt.tmp.123"
run_supervisor "$stale_capture_diag" true
[[ ! -e "$stale_capture_diag/health-failure-old.txt.tmp.123" ]] \
    || fail "stale health capture temp survived startup"

echo "[relay-supervisor-test] repeated health failures capture process state"
health_diag="$TMP/health"
run_supervisor "$health_diag" sh -c 'sleep 2' B219_SECRET_SENTINEL
capture=$(find "$health_diag" -maxdepth 1 -name 'health-failure-*.txt' -print -quit)
[[ -n "$capture" ]] || fail "health failure did not create a diagnostic capture"
grep -q '^\[child-status\]$' "$capture" || fail "capture lacks child status"
grep -q '^\[cgroup-memory.events\]$' "$capture" \
    || fail "capture lacks cgroup memory events"
grep -q '^\[task-' "$capture" || fail "capture lacks per-task state"
grep -q '"event":"health_failure_capture"' "$health_diag/lifecycle.jsonl" \
    || fail "health capture was not recorded in lifecycle log"
if grep -R -q 'B219_SECRET_SENTINEL' "$health_diag"; then
    fail "child argv leaked into diagnostic artifacts"
fi

echo "[relay-supervisor-test] SIGTERM is logged and forwarded"
signal_diag="$TMP/signal"
term_seen="$TMP/term-seen"
C2C_RELAY_DIAG_DIR="$signal_diag" \
C2C_RELAY_CHILD_REAPER="$REAPER" \
C2C_RELAY_HEALTH_URL=http://127.0.0.1:1/health \
C2C_RELAY_HEALTH_INTERVAL=5 \
C2C_RELAY_HEALTH_TIMEOUT=1 \
C2C_RELAY_HEALTH_FAILURE_THRESHOLD=3 \
    "$SUPERVISOR" sh -c \
      'trap '\''printf term >"$1"; exit 0'\'' TERM; while :; do sleep 1; done' \
      sh "$term_seen" &
SIGNAL_SUPERVISOR_PID=$!
for _ in {1..100}; do
    [[ -f "$signal_diag/lifecycle.jsonl" ]] \
        && grep -q '"event":"child_start"' "$signal_diag/lifecycle.jsonl" \
        && break
    sleep 0.02
done
kill -TERM "$SIGNAL_SUPERVISOR_PID"
wait "$SIGNAL_SUPERVISOR_PID"
SIGNAL_SUPERVISOR_PID=
[[ -f "$term_seen" ]] || fail "SIGTERM was not forwarded to child"
grep -q '"event":"supervisor_signal".*"signal":"TERM"' \
    "$signal_diag/lifecycle.jsonl" \
    || fail "supervisor SIGTERM was not persisted"

echo "relay-supervisor tests: PASS"
