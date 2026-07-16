#!/bin/sh
# Persistent relay lifecycle + hang diagnostics for Railway/OCI (B219).
#
# This process intentionally remains separate from the relay child.  That lets
# it record a native child exit, and lets the next container distinguish such
# an exit from a whole-container/SIGKILL disappearance via [active-run].
set -u
umask 077

if [ "$#" -eq 0 ]; then
    echo "usage: c2c-relay-supervisor COMMAND [ARG ...]" >&2
    exit 64
fi

timestamp() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

safe_id() {
    printf '%s' "$1" | LC_ALL=C tr -cd 'A-Za-z0-9._:-'
}

default_diag_root=${C2C_RELAY_PERSIST_DIR:-/data}
DIAG_DIR=${C2C_RELAY_DIAG_DIR:-"$default_diag_root/relay-diagnostics"}
# A prior compromised/unprivileged process may have precreated the well-known
# name. Remove a symlink before any root operation can dereference it. In the
# production layout the sticky root-owned /data parent prevents replacement
# once this supervisor has created the root-owned directory.
if [ -L "$DIAG_DIR" ] && ! rm -f "$DIAG_DIR" 2>/dev/null; then
    DIAG_DIR="${TMPDIR:-/tmp}/c2c-relay-diagnostics-$$"
fi
if ! mkdir -p "$DIAG_DIR" 2>/dev/null; then
    DIAG_DIR="${TMPDIR:-/tmp}/c2c-relay-diagnostics-$$"
    mkdir -p "$DIAG_DIR"
    echo "[relay-supervisor] warning: persistent diagnostics unavailable; using $DIAG_DIR" >&2
fi
# Keep lifecycle/reaper metadata root-owned. The relay child gets write access
# only to the cores subdirectory; mode 0711 lets it traverse the parent without
# listing or replacing root metadata.
diag_parent=${DIAG_DIR%/*}
[ "$diag_parent" = "$DIAG_DIR" ] && diag_parent=.
core_owner_reference=$default_diag_root
[ -e "$core_owner_reference" ] || core_owner_reference=$diag_parent
core_owner=${C2C_RELAY_CORE_OWNER:-}
chown 0:0 "$DIAG_DIR" 2>/dev/null || true
chmod 0711 "$DIAG_DIR" 2>/dev/null || true

CORE_DIR="$DIAG_DIR/cores"
mkdir -p "$CORE_DIR" 2>/dev/null || true
if [ -n "$core_owner" ]; then
    chown "$core_owner" "$CORE_DIR" 2>/dev/null || true
else
    chown --reference="$core_owner_reference" "$CORE_DIR" 2>/dev/null || true
fi
chmod 0700 "$CORE_DIR" 2>/dev/null || true

LIFECYCLE_LOG="$DIAG_DIR/lifecycle.jsonl"
ACTIVE_RUN="$DIAG_DIR/active-run"
# The directory is no longer child-writable, so removing pre-lockdown symlinks
# and stale helper metadata here closes first-start and PID-reuse attacks.
[ -L "$LIFECYCLE_LOG" ] && rm -f "$LIFECYCLE_LOG"
[ -L "$ACTIVE_RUN" ] && rm -f "$ACTIVE_RUN"
rm -f "$DIAG_DIR"/active-run.tmp.* "$DIAG_DIR"/child-pid-* \
    "$DIAG_DIR"/child-status-* 2>/dev/null || true
if ! : >>"$LIFECYCLE_LOG" 2>/dev/null; then
    DIAG_DIR="${TMPDIR:-/tmp}/c2c-relay-diagnostics-$$"
    mkdir -p "$DIAG_DIR"
    chown 0:0 "$DIAG_DIR" 2>/dev/null || true
    chmod 0711 "$DIAG_DIR" 2>/dev/null || true
    LIFECYCLE_LOG="$DIAG_DIR/lifecycle.jsonl"
    ACTIVE_RUN="$DIAG_DIR/active-run"
    CORE_DIR="$DIAG_DIR/cores"
    mkdir -p "$CORE_DIR" 2>/dev/null || true
    if [ -n "$core_owner" ]; then
        chown "$core_owner" "$CORE_DIR" 2>/dev/null || true
    else
        chown --reference="$core_owner_reference" "$CORE_DIR" 2>/dev/null || true
    fi
    chmod 0700 "$CORE_DIR" 2>/dev/null || true
    [ -L "$LIFECYCLE_LOG" ] && rm -f "$LIFECYCLE_LOG"
    [ -L "$ACTIVE_RUN" ] && rm -f "$ACTIVE_RUN"
    rm -f "$DIAG_DIR"/active-run.tmp.* "$DIAG_DIR"/child-pid-* \
        "$DIAG_DIR"/child-status-* 2>/dev/null || true
    : >>"$LIFECYCLE_LOG"
    echo "[relay-supervisor] warning: persistent diagnostics not writable; using $DIAG_DIR" >&2
fi
chown 0:0 "$LIFECYCLE_LOG" 2>/dev/null || true
chmod 0600 "$LIFECYCLE_LOG" 2>/dev/null || true

# A killed health monitor may leave an incomplete atomic-write temp. They are
# never evidence and must not accumulate outside completed-capture retention.
rm -f "$DIAG_DIR"/health-failure-*.txt.tmp.* 2>/dev/null || true

# Bound the durable ledger without losing the immediately previous lifecycle.
log_bytes=$(wc -c <"$LIFECYCLE_LOG" 2>/dev/null || printf '0')
case "$log_bytes" in
    ''|*[!0-9]*) log_bytes=0 ;;
esac
if [ "$log_bytes" -gt 1048576 ]; then
    rm -f "$LIFECYCLE_LOG.previous" 2>/dev/null || true
    if mv "$LIFECYCLE_LOG" "$LIFECYCLE_LOG.previous" 2>/dev/null; then
        : >"$LIFECYCLE_LOG" 2>/dev/null || true
    else
        echo "[relay-supervisor] warning: diagnostic ledger rotation failed" >&2
    fi
fi

if [ -r /proc/sys/kernel/random/uuid ]; then
    RUN_ID=$(safe_id "$(cat /proc/sys/kernel/random/uuid)")
else
    RUN_ID=$(safe_id "$(date -u +%Y%m%dT%H%M%SZ)-$$")
fi
DEPLOYMENT_ID=$(safe_id "${RAILWAY_DEPLOYMENT_ID:-unknown}")

durable_sync() {
    path=$1
    sync -d "$path" 2>/dev/null || sync "$path" 2>/dev/null || true
}

log_write_warning() {
    echo "[relay-supervisor] warning: diagnostic ledger write failed" >&2
}

emit_event() {
    event=$1
    if printf '{"ts":"%s","event":"%s","run_id":"%s","deployment_id":"%s"}\n' \
            "$(timestamp)" "$event" "$RUN_ID" "$DEPLOYMENT_ID" \
            >>"$LIFECYCLE_LOG" 2>/dev/null; then
        durable_sync "$LIFECYCLE_LOG"
    else
        log_write_warning
    fi
    printf '[relay-supervisor] %s run=%s deployment=%s\n' \
        "$event" "$RUN_ID" "$DEPLOYMENT_ID" >&2
}

emit_string_event() {
    event=$1
    key=$2
    value=$(safe_id "$3")
    if printf '{"ts":"%s","event":"%s","run_id":"%s","deployment_id":"%s","%s":"%s"}\n' \
            "$(timestamp)" "$event" "$RUN_ID" "$DEPLOYMENT_ID" \
            "$key" "$value" >>"$LIFECYCLE_LOG" 2>/dev/null; then
        durable_sync "$LIFECYCLE_LOG"
    else
        log_write_warning
    fi
    printf '[relay-supervisor] %s run=%s %s=%s\n' \
        "$event" "$RUN_ID" "$key" "$value" >&2
}

emit_status_event() {
    event=$1
    status=$2
    if printf '{"ts":"%s","event":"%s","run_id":"%s","deployment_id":"%s","status":%s}\n' \
            "$(timestamp)" "$event" "$RUN_ID" "$DEPLOYMENT_ID" \
            "$status" >>"$LIFECYCLE_LOG" 2>/dev/null; then
        durable_sync "$LIFECYCLE_LOG"
    else
        log_write_warning
    fi
    printf '[relay-supervisor] %s run=%s status=%s\n' \
        "$event" "$RUN_ID" "$status" >&2
}

if [ -s "$ACTIVE_RUN" ]; then
    previous_run=$(safe_id "$(sed -n '1p' "$ACTIVE_RUN" 2>/dev/null || true)")
    if [ -n "$previous_run" ]; then
        emit_string_event previous_run_unclean previous_run_id "$previous_run"
    fi
fi
if printf '%s\n' "$RUN_ID" >"$ACTIVE_RUN.tmp.$$" 2>/dev/null \
        && mv "$ACTIVE_RUN.tmp.$$" "$ACTIVE_RUN" 2>/dev/null; then
    durable_sync "$ACTIVE_RUN"
    durable_sync "$DIAG_DIR"
else
    rm -f "$ACTIVE_RUN.tmp.$$" 2>/dev/null || true
    echo "[relay-supervisor] warning: active-run marker write failed" >&2
fi
emit_event supervisor_start

child_pid=''
worker_pid=''
monitor_pid=''
pending_supervisor_signal=''

handle_signal() {
    signal=$1
    emit_string_event supervisor_signal signal "$signal"
    if [ -n "$worker_pid" ] && kill -0 "$worker_pid" 2>/dev/null; then
        kill -"$signal" "$worker_pid" 2>/dev/null || true
    else
        pending_supervisor_signal=$signal
    fi
}
trap 'handle_signal TERM' TERM
trap 'handle_signal INT' INT
trap 'handle_signal HUP' HUP

prune_captures() {
    max=${C2C_RELAY_DIAG_KEEP:-10}
    case "$max" in
        ''|*[!0-9]*) max=10 ;;
    esac
    count=0
    # Filenames are generated by this script and cannot contain whitespace.
    for path in $(ls -1t "$DIAG_DIR"/health-failure-*.txt 2>/dev/null || true); do
        count=$((count + 1))
        if [ "$count" -gt "$max" ]; then
            rm -f "$path"
        fi
    done
}

prune_cores() {
    count=0
    for path in $(ls -1t "$CORE_DIR"/core* 2>/dev/null || true); do
        count=$((count + 1))
        if [ "$count" -gt 2 ]; then
            rm -f "$path"
        fi
    done
}

dump_file() {
    label=$1
    path=$2
    printf '[%s]\n' "$label"
    if [ -r "$path" ]; then
        if command -v timeout >/dev/null 2>&1; then
            timeout 2 cat "$path" 2>&1 || true
        else
            cat "$path" 2>&1 || true
        fi
    else
        echo "unavailable"
    fi
}

capture_health_failure() {
    failures=$1
    file_stamp=$(date -u +%Y%m%dT%H%M%SZ)
    capture="$DIAG_DIR/health-failure-$file_stamp-$RUN_ID.txt"
    tmp="$capture.tmp.$$"
    if {
        echo "[metadata]"
        echo "timestamp=$(timestamp)"
        echo "run_id=$RUN_ID"
        echo "deployment_id=$DEPLOYMENT_ID"
        echo "child_pid=$child_pid"
        echo "consecutive_health_failures=$failures"
        echo "note=command line and environment intentionally omitted to avoid secret capture"
        dump_file child-status "/proc/$child_pid/status"
        dump_file child-limits "/proc/$child_pid/limits"
        dump_file child-io "/proc/$child_pid/io"
        echo "[child-fd-count]"
        ls -1 "/proc/$child_pid/fd" 2>/dev/null | wc -l || true
        echo "[child-fds-first-512]"
        ls -l "/proc/$child_pid/fd" 2>&1 | head -n 512 || true
        for task_dir in /proc/"$child_pid"/task/*; do
            [ -d "$task_dir" ] || continue
            tid=${task_dir##*/}
            dump_file "task-$tid-status" "$task_dir/status"
            dump_file "task-$tid-wchan" "$task_dir/wchan"
            dump_file "task-$tid-stack" "$task_dir/stack"
        done
        dump_file cgroup-memory.events /sys/fs/cgroup/memory.events
        dump_file cgroup-memory.current /sys/fs/cgroup/memory.current
        dump_file cgroup-memory.max /sys/fs/cgroup/memory.max
        dump_file cgroup-pids.current /sys/fs/cgroup/pids.current
        dump_file cgroup-pids.max /sys/fs/cgroup/pids.max
        dump_file cgroup-cpu.pressure /sys/fs/cgroup/cpu.pressure
        dump_file cgroup-memory.pressure /sys/fs/cgroup/memory.pressure
        dump_file cgroup-io.pressure /sys/fs/cgroup/io.pressure
        dump_file kernel-core_pattern /proc/sys/kernel/core_pattern
    } >"$tmp" 2>&1 && mv "$tmp" "$capture" 2>/dev/null; then
        durable_sync "$capture"
        durable_sync "$DIAG_DIR"
        prune_captures
        emit_string_event health_failure_capture file "${capture##*/}"
    else
        rm -f "$tmp" 2>/dev/null || true
        emit_event health_failure_capture_failed
    fi
}

HEALTH_URL=${C2C_RELAY_HEALTH_URL:-"http://127.0.0.1:${PORT:-7331}/health"}
HEALTH_INTERVAL=${C2C_RELAY_HEALTH_INTERVAL:-10}
HEALTH_TIMEOUT=${C2C_RELAY_HEALTH_TIMEOUT:-5}
HEALTH_FAILURE_THRESHOLD=${C2C_RELAY_HEALTH_FAILURE_THRESHOLD:-3}
case "$HEALTH_FAILURE_THRESHOLD" in
    ''|*[!0-9]*|0) HEALTH_FAILURE_THRESHOLD=3 ;;
esac

health_watch() {
    trap 'rm -f "$DIAG_DIR"/health-failure-*.txt.tmp.$$ 2>/dev/null || true; exit 0' \
        TERM INT HUP
    if ! command -v curl >/dev/null 2>&1; then
        emit_event health_monitor_unavailable
        return
    fi
    failures=0
    captured=0
    while kill -0 "$child_pid" 2>/dev/null; do
        sleep "$HEALTH_INTERVAL" || return
        if curl --fail --silent --show-error --output /dev/null \
                --max-time "$HEALTH_TIMEOUT" "$HEALTH_URL" 2>/dev/null; then
            if [ "$failures" -ge "$HEALTH_FAILURE_THRESHOLD" ]; then
                emit_event health_recovered
            fi
            failures=0
            captured=0
        else
            failures=$((failures + 1))
            if [ "$failures" -ge "$HEALTH_FAILURE_THRESHOLD" ] \
                    && [ "$captured" -eq 0 ]; then
                capture_health_failure "$failures"
                captured=1
            fi
        fi
    done
}

# Do not print or persist "$@": production argv may contain a relay token.
# A tiny waitpid helper preserves the distinction that POSIX shell [wait]
# loses between exit(139) and SIGSEGV. It also resets the SIGINT disposition
# that shells normally force to ignored for asynchronous children.
CHILD_REAPER=${C2C_RELAY_CHILD_REAPER:-/usr/local/bin/c2c-relay-child-reaper}
CHILD_PID_FILE="$DIAG_DIR/child-pid-$RUN_ID"
CHILD_STATUS_FILE="$DIAG_DIR/child-status-$RUN_ID"
rm -f "$CHILD_PID_FILE" "$CHILD_STATUS_FILE" 2>/dev/null || true
exact_wait_status=1

if [ ! -x "$CHILD_REAPER" ]; then
    exact_wait_status=0
    emit_event child_reaper_unavailable
    echo "[relay-supervisor] warning: exact wait-status helper unavailable" >&2
fi

# The container image enables bounded core capture and runs the child from the
# persistent diagnostic directory. Generic callers retain their cwd unless
# they explicitly opt in.
if [ "$exact_wait_status" -eq 1 ]; then
    if [ "${C2C_RELAY_CORE_CAPTURE:-0}" = 1 ]; then
        (
            cd "$CORE_DIR" || exit 70
            # POSIX leaves units implementation-defined; on Debian dash this
            # caps the core at 128 MiB (262144 x 512-byte blocks).
            ulimit -c 262144 2>/dev/null || true
            exec "$CHILD_REAPER" --pid-file "$CHILD_PID_FILE" \
                --status-file "$CHILD_STATUS_FILE" -- "$@"
        ) &
    else
        "$CHILD_REAPER" --pid-file "$CHILD_PID_FILE" \
            --status-file "$CHILD_STATUS_FILE" -- "$@" &
    fi
else
    if [ "${C2C_RELAY_CORE_CAPTURE:-0}" = 1 ]; then
        (
            cd "$CORE_DIR" || exit 70
            ulimit -c 262144 2>/dev/null || true
            exec "$@"
        ) &
    else
        "$@" &
    fi
fi
worker_pid=$!
if [ -n "$pending_supervisor_signal" ]; then
    kill -"$pending_supervisor_signal" "$worker_pid" 2>/dev/null || true
    pending_supervisor_signal=''
fi

if [ "$exact_wait_status" -eq 1 ]; then
    attempts=0
    while [ ! -s "$CHILD_PID_FILE" ] \
            && kill -0 "$worker_pid" 2>/dev/null \
            && [ "$attempts" -lt 250 ]; do
        sleep 0.02 || true
        attempts=$((attempts + 1))
    done
    child_pid=$(sed -n '1p' "$CHILD_PID_FILE" 2>/dev/null || true)
    case "$child_pid" in
        ''|*[!0-9]*)
            child_pid=$worker_pid
            emit_event child_pid_unavailable
            ;;
    esac
else
    child_pid=$worker_pid
fi
emit_string_event child_start child_pid "$child_pid"
health_watch &
monitor_pid=$!

status=0
while :; do
    wait "$worker_pid"
    status=$?
    if kill -0 "$worker_pid" 2>/dev/null; then
        # [wait] was interrupted by a trapped supervisor signal; the child is
        # still draining, so wait again for its real status.
        continue
    fi
    break
done

kill "$monitor_pid" 2>/dev/null || true
wait "$monitor_pid" 2>/dev/null || true

wait_kind=unavailable
wait_value=''
core_dumped=0
if [ "$exact_wait_status" -eq 1 ] && [ -r "$CHILD_STATUS_FILE" ]; then
    IFS=' ' read -r wait_kind wait_value core_dumped \
        <"$CHILD_STATUS_FILE" || true
fi

if [ "$wait_kind" = signal ]; then
    signal_number=$wait_value
    if printf '{"ts":"%s","event":"child_signaled","run_id":"%s","deployment_id":"%s","status":%s,"signal_number":%s,"core_dumped":%s}\n' \
            "$(timestamp)" "$RUN_ID" "$DEPLOYMENT_ID" "$status" \
            "$signal_number" "$core_dumped" >>"$LIFECYCLE_LOG" 2>/dev/null; then
        durable_sync "$LIFECYCLE_LOG"
    else
        log_write_warning
    fi
    printf '[relay-supervisor] child_signaled run=%s status=%s signal_number=%s core_dumped=%s\n' \
        "$RUN_ID" "$status" "$signal_number" "$core_dumped" >&2
    core_file=$(find "$CORE_DIR" -maxdepth 1 -type f -name 'core*' \
        -newer "$ACTIVE_RUN" -printf '%f\n' 2>/dev/null | head -n 1 || true)
    if [ -n "$core_file" ]; then
        durable_sync "$CORE_DIR/$core_file"
        emit_string_event core_file file "cores/$core_file"
        prune_cores
    elif [ "$core_dumped" = 1 ]; then
        emit_event core_file_missing
    fi
elif [ "$wait_kind" = exit ]; then
    emit_status_event child_exit "$wait_value"
else
    emit_status_event child_exit_ambiguous "$status"
fi

if [ -r "$ACTIVE_RUN" ] \
        && [ "$(sed -n '1p' "$ACTIVE_RUN" 2>/dev/null || true)" = "$RUN_ID" ]; then
    if rm -f "$ACTIVE_RUN" 2>/dev/null; then
        durable_sync "$DIAG_DIR"
    else
        echo "[relay-supervisor] warning: active-run marker cleanup failed" >&2
    fi
fi
rm -f "$CHILD_PID_FILE" "$CHILD_STATUS_FILE" 2>/dev/null || true
emit_status_event supervisor_exit "$status"
exit "$status"
