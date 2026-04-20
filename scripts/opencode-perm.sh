#!/usr/bin/env bash
# opencode-perm.sh — dismiss an OpenCode permission dialog via tmux.
#
# The permission dialog shows three buttons in this order:
#   [Allow once]  [Allow always]  [Reject]
# The first button is focused by default; navigate with arrow keys + Enter.
#
# Usage:
#   scripts/opencode-perm.sh [OPTIONS] <tmux-pane> <action>
#
#   <action>  : allow-once | allow-always | reject
#
# Options:
#   --dry-run      Print what would be sent without sending anything.
#   --no-check     Skip the dialog-presence check (fire keys blindly).
#   --wait N       Wait up to N seconds for the dialog to appear (default: 0).
#
# Exit codes:
#   0 — keys sent (or dry-run OK)
#   1 — dialog not detected (use --no-check to override)
#   2 — bad arguments
#
# Examples:
#   scripts/opencode-perm.sh 0:1.0 allow-once
#   scripts/opencode-perm.sh swarm:1 allow-always --dry-run
#   scripts/opencode-perm.sh %42 reject

set -euo pipefail

DRY_RUN=0
NO_CHECK=0
WAIT_SECS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=1; shift ;;
        --no-check)  NO_CHECK=1; shift ;;
        --wait)      WAIT_SECS="$2"; shift 2 ;;
        --)          shift; break ;;
        -*)          echo "unknown option: $1" >&2; exit 2 ;;
        *)           break ;;
    esac
done

if [[ $# -lt 2 ]]; then
    echo "usage: $0 [--dry-run] [--no-check] [--wait N] <tmux-pane> <allow-once|allow-always|reject>" >&2
    exit 2
fi

TARGET="$1"
ACTION="$2"

case "$ACTION" in
    allow-once)   ARROW_COUNT=0 ;;
    allow-always) ARROW_COUNT=1 ;;
    reject)       ARROW_COUNT=2 ;;
    *)
        echo "opencode-perm: unknown action '$ACTION'. Use: allow-once, allow-always, reject" >&2
        exit 2
        ;;
esac

# Verify the pane exists.
tmux display-message -t "$TARGET" -p '#{pane_id}' >/dev/null 2>&1 || {
    echo "opencode-perm: cannot find pane '$TARGET'" >&2
    exit 2
}

# --- dialog detection -------------------------------------------------------
# Grep the captured pane for OpenCode's permission dialog text.
pane_has_dialog() {
    tmux capture-pane -t "$TARGET" -p 2>/dev/null \
        | grep -qiE "Permission required|Allow once|Allow always|Do you want to allow"
}

if [[ $NO_CHECK -eq 0 ]]; then
    found=0
    if [[ $WAIT_SECS -gt 0 ]]; then
        deadline=$(( $(date +%s) + WAIT_SECS ))
        while [[ $(date +%s) -lt $deadline ]]; do
            if pane_has_dialog; then found=1; break; fi
            sleep 0.5
        done
    else
        pane_has_dialog && found=1
    fi

    if [[ $found -eq 0 ]]; then
        echo "opencode-perm: no permission dialog detected in pane '$TARGET'." >&2
        echo "  Use --no-check to send keys anyway, or --wait N to poll for the dialog." >&2
        exit 1
    fi
fi

# --- send keys ---------------------------------------------------------------
if [[ $DRY_RUN -eq 1 ]]; then
    if [[ $ARROW_COUNT -gt 0 ]]; then
        echo "opencode-perm: DRY RUN — would send Right x$ARROW_COUNT + Enter to '$TARGET' ($ACTION)"
    else
        echo "opencode-perm: DRY RUN — would send Enter to '$TARGET' ($ACTION)"
    fi
    exit 0
fi

# Disable extended-keys so arrow-key CSI sequences are standard.
prev_ext=$(tmux show -sv extended-keys 2>/dev/null || echo "off")
tmux set -s extended-keys off

for (( i=0; i<ARROW_COUNT; i++ )); do
    tmux send-keys -t "$TARGET" Right
    sleep 0.05
done
tmux send-keys -t "$TARGET" Enter

tmux set -s extended-keys "$prev_ext"

echo "opencode-perm: sent '$ACTION' to pane '$TARGET'"
