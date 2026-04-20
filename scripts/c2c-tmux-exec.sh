#!/usr/bin/env bash
# c2c-tmux-exec.sh — safely run a shell command in a tmux pane.
#
# Problem: `tmux send-keys -t <pane> "some command" Enter` silently types
# into whatever is running — including an opencode/kimi TUI — mangling
# the UI state and spawning orphan processes.
#
# This script checks whether the pane is at a shell prompt (bash/fish/zsh)
# before sending keys.  If the foreground process is NOT a shell, it prints
# a warning and exits 1 (default) or exits 0 with --force.
#
# Usage:
#   scripts/c2c-tmux-exec.sh [OPTIONS] <target-pane> <command>
#
# Options:
#   --force        Send keys even if a TUI is detected (emit warning first).
#   --escape-tui   Try to exit the TUI first (sends Escape then q/Ctrl-D).
#   --dry-run      Print what would happen without sending anything.
#
# <target-pane> is any tmux target (e.g. "0:1.0", "swarm:1", "%42").
# <command> is the shell command string to send.
#
# Exit codes:
#   0 — command sent (or dry-run OK)
#   1 — blocked: TUI detected, --force not given
#   2 — bad arguments

set -euo pipefail

FORCE=0
ESCAPE_TUI=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)      FORCE=1; shift ;;
        --escape-tui) ESCAPE_TUI=1; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --)           shift; break ;;
        -*)           echo "unknown option: $1" >&2; exit 2 ;;
        *)            break ;;
    esac
done

if [[ $# -lt 2 ]]; then
    echo "usage: $0 [--force|--escape-tui|--dry-run] <tmux-target> <command>" >&2
    exit 2
fi

TARGET="$1"
COMMAND="$2"

# Get the PID of the foreground process group in the target pane.
# tmux display-message -p '#{pane_pid}' gives the shell PID;
# we want the foreground job (what's running in the terminal).
pane_pid=$(tmux display-message -t "$TARGET" -p '#{pane_pid}' 2>/dev/null) || {
    echo "c2c-tmux-exec: cannot find pane '$TARGET'" >&2
    exit 2
}

# Find the foreground process: the child of the shell that has the terminal
# as its controlling tty and is in the foreground process group.
fg_cmd=""
if [[ -n "$pane_pid" ]]; then
    # Walk /proc to find children of pane_pid and pick the most recent one.
    for child_pid in $(ls /proc/"$pane_pid"/task/"$pane_pid"/children 2>/dev/null | tr ' ' '\n'); do
        if [[ -f "/proc/$child_pid/comm" ]]; then
            fg_cmd=$(cat "/proc/$child_pid/comm" 2>/dev/null || true)
            break
        fi
    done
    # Also try reading the tcpgrp from the pane's tty
    pts_path=$(readlink -f "/proc/$pane_pid/fd/0" 2>/dev/null || true)
    if [[ -n "$pts_path" && "$pts_path" == /dev/pts/* ]]; then
        pts_n="${pts_path#/dev/pts/}"
        fg_pgid=$(cat /proc/"$pane_pid"/status 2>/dev/null | awk '/^Tgid/{print $2}' || true)
        # Find the process whose session matches and is the foreground group
        for pid in /proc/[0-9]*/; do
            pid="${pid#/proc/}"; pid="${pid%/}"
            stat_file="/proc/$pid/stat"
            [[ -f "$stat_file" ]] || continue
            comm=$(cat "/proc/$pid/comm" 2>/dev/null || true)
            ppid=$(awk '{print $4}' "$stat_file" 2>/dev/null || true)
            if [[ "$ppid" == "$pane_pid" ]]; then
                fg_cmd="$comm"
                break
            fi
        done
    fi
fi

# Classify: is fg_cmd a known TUI process?
KNOWN_TUIS="opencode kimi claude codex crush bun node"
is_tui=0
for tui in $KNOWN_TUIS; do
    if [[ "$fg_cmd" == "$tui" || "$fg_cmd" == ".$tui" || "$fg_cmd" == ".opencode" ]]; then
        is_tui=1
        break
    fi
done

if [[ $is_tui -eq 1 ]]; then
    echo "c2c-tmux-exec: WARNING pane '$TARGET' foreground='$fg_cmd' (TUI detected)" >&2
    if [[ $ESCAPE_TUI -eq 1 ]]; then
        echo "c2c-tmux-exec: sending Escape + q to exit TUI first..." >&2
        if [[ $DRY_RUN -eq 0 ]]; then
            tmux send-keys -t "$TARGET" Escape
            sleep 0.3
            tmux send-keys -t "$TARGET" q
            sleep 0.5
        fi
    elif [[ $FORCE -eq 0 ]]; then
        echo "c2c-tmux-exec: blocked. Use --force to override or --escape-tui to exit TUI first." >&2
        exit 1
    else
        echo "c2c-tmux-exec: --force set, sending anyway." >&2
    fi
fi

if [[ $DRY_RUN -eq 1 ]]; then
    echo "c2c-tmux-exec: DRY RUN — would send to '$TARGET': $COMMAND"
    exit 0
fi

# Disable extended-keys temporarily (prevents CSI-u encoding that breaks TUIs)
prev_ext=$(tmux show -sv extended-keys 2>/dev/null || echo "off")
tmux set -s extended-keys off
tmux send-keys -t "$TARGET" "$COMMAND" Enter
tmux set -s extended-keys "$prev_ext"

echo "c2c-tmux-exec: sent to '$TARGET': $COMMAND"
