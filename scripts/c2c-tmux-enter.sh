#!/usr/bin/env bash
# c2c-tmux-enter.sh — send a submit Enter to a tmux pane even when the
# user's tmux has `set -s extended-keys on`.
#
# With extended-keys on, `tmux send-keys Enter` encodes as CSI-u
# (`^[[27;5;109~`) which Claude Code's TUI treats as Ctrl+Shift+M, not
# Enter. See
# .collab/findings/2026-04-19T06-22-47Z-opus-host-tmux-extended-keys-eats-enter.md
#
# Usage:
#   scripts/c2c-tmux-enter.sh <target>
#
# <target> is any tmux target-pane (session name, window, pane id).

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 <tmux-target>" >&2
    exit 2
fi

target="$1"

prev=$(tmux show -sv extended-keys 2>/dev/null || echo "off")
tmux set -s extended-keys off
tmux send-keys -t "$target" Enter
tmux set -s extended-keys "$prev"
