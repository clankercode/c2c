#!/usr/bin/env bash
# tui-snapshot.sh — render a c2c TUI at specific terminal dimensions
# and print the captured screen.
#
# Usage:
#   scripts/tui-snapshot.sh [WIDTH] [HEIGHT] [-- COMMAND...] [--keys KEYS]
#
# Examples:
#   scripts/tui-snapshot.sh                    # default 80x24, `c2c install`, abort with n
#   scripts/tui-snapshot.sh 120 40             # 120x40 window
#   scripts/tui-snapshot.sh 80 24 --keys "c\ny\nn\ny\ny\ny\n"  # customize path
#   scripts/tui-snapshot.sh -- c2c install self --help
#
# Captures the pane after 0.8s so the TUI has time to render, then feeds
# input (default: "n\n" to abort). Uses tmux so the session actually has
# the requested dimensions.

set -euo pipefail

WIDTH=${1:-80}
HEIGHT=${2:-24}
shift 2 2>/dev/null || shift $# 2>/dev/null || true

# Handle when first args are already -- or --keys
if [[ "${WIDTH}" == "--" || "${WIDTH}" == "--keys" ]]; then
  WIDTH=80
  HEIGHT=24
  set -- "$WIDTH" "$HEIGHT" "$@"
  shift 2
fi

KEYS=$'n\n'
CMD=()

while [ $# -gt 0 ]; do
  case "$1" in
    --keys)
      KEYS="$2"
      shift 2
      ;;
    --)
      shift
      CMD=("$@")
      break
      ;;
    *)
      echo "tui-snapshot: unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [ ${#CMD[@]} -eq 0 ]; then
  CMD=(c2c install)
fi

SESSION="c2c-tui-$$-$RANDOM"

# Wrap the command with a sentinel + cat so the tmux session stays alive
# after the command exits (giving us time to capture the pane). The sentinel
# line marks the boundary between program output and our holding cat.
SENTINEL="__TUI_SNAPSHOT_DONE__"
QUOTED=""
for arg in "${CMD[@]}"; do
  QUOTED+=" $(printf '%q' "$arg")"
done
WRAPPED="{${QUOTED}; echo; echo ${SENTINEL}; cat > /dev/null; }"

tmux new-session -d -s "$SESSION" -x "$WIDTH" -y "$HEIGHT" "bash -c ${WRAPPED@Q}"

# Let the program render its initial prompt.
sleep 0.8

# Send the keystrokes. tmux -l sends literal text; we split on \n and
# translate each newline into Enter.
python3 - "$SESSION" "$KEYS" <<'PY'
import subprocess, sys
session, keys = sys.argv[1], sys.argv[2]
segments = keys.split('\n')
for i, seg in enumerate(segments):
    if seg:
        subprocess.run(["tmux", "send-keys", "-t", session, "-l", seg], check=True)
    if i < len(segments) - 1:
        subprocess.run(["tmux", "send-keys", "-t", session, "Enter"], check=True)
PY

# Wait for the TUI to finish painting its final frame.
sleep 0.5

# Capture the pane, trim at the sentinel so caller only sees program output.
tmux capture-pane -t "$SESSION" -p -J | awk -v s="$SENTINEL" '
  $0 == s { exit }
  { print }
'

tmux kill-session -t "$SESSION" 2>/dev/null || true
