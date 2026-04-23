#!/usr/bin/env bash
#
# dune-watchdog.sh — guard a dune command with a timeout watchdog.
#
# Usage: scripts/dune-watchdog.sh <timeout_secs> <cmd> [args...]
#
# If DUNE_WATCHDOG=0 is set, runs the command directly without watchdog.
# If DUNE_WATCHDOG_TIMEOUT is set, overrides <timeout_secs>.
# On timeout, prints an explanatory banner to stderr and exits 124.

set -euo pipefail

WATCHDOG_TIMEOUT="${DUNE_WATCHDOG_TIMEOUT:-${1:?usage: $0 <timeout_secs> <cmd> [args...]}}"

if [[ "$WATCHDOG_TIMEOUT" != "$1" ]]; then
    # DUNE_WATCHDOG_TIMEOUT was set, so timeout override takes precedence
    shift
else
    WATCHDOG_TIMEOUT="$1"
    shift
fi

CMD=("$@")

# Opt-out
if [[ "${DUNE_WATCHDOG:-}" == "0" ]]; then
    exec "${CMD[@]}"
fi

# Launch the command in a process group so we can kill the whole group
set -o monitor
trap 'kill -- -$$ 2>/dev/null || true' EXIT

"${CMD[@]}" &
CMD_PID=$!

# Sleep in background
sleep "$WATCHDOG_TIMEOUT" &
SLEEP_PID=$!

# Wait for whichever finishes first
wait -n -p WAIT_PID "$CMD_PID" "$SLEEP_PID" 2>/dev/null || true

if [[ "${WAIT_PID}" == "$SLEEP_PID" ]]; then
    # Sleep won — command is still running, watchdog fires
    kill -KILL -- -$$ 2>/dev/null || true
    wait "$CMD_PID" 2>/dev/null || true

    cat >&2 <<BANNER
==========================================================================
DUNE WATCHDOG: killed command after ${WATCHDOG_TIMEOUT} seconds.

dune may hang due to deadlock, remote opam mirror issues, or resource
exhaustion. This watchdog fires automatically to prevent indefinite blocks.

To DISABLE the watchdog for this call:
  DUNE_WATCHDOG=0 just <recipe>

To change the timeout (in seconds):
  DUNE_WATCHDOG_TIMEOUT=120 just <recipe>
==========================================================================
BANNER

    exit 124
fi

# Command won — pass through its exit code
exit $(wait "$CMD_PID")
