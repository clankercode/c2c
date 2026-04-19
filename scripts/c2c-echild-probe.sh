#!/usr/bin/env bash
# c2c-echild-probe.sh — drive a fresh Claude Code session through a
# gauntlet of tool calls and grep the tmux transcript for any hook
# error signatures (ECHILD, waitpid, "hook error", etc.).
#
# Intended as the test loop for the ECHILD hook-race work. Run it,
# read the report. If new failure signatures show up, add them to
# PATTERNS below.
#
# Usage:
#   scripts/c2c-echild-probe.sh [--keep]
#     --keep   do not kill the tmux session on exit (for manual inspection)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
ENTER="$REPO_ROOT/scripts/c2c-tmux-enter.sh"
CAPTURE_DIR="$REPO_ROOT/.collab/echild-probe"
mkdir -p "$CAPTURE_DIR"
STAMP="$(date +%Y%m%dT%H%M%S)"
CAPTURE_FILE="$CAPTURE_DIR/capture-$STAMP.log"
SESSION="echild-probe-$$"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

cleanup() {
  if [ "$KEEP" -eq 0 ]; then
    tmux kill-session -t "$SESSION" 2>/dev/null || true
  else
    echo "==> Keeping tmux session: tmux attach -t $SESSION" >&2
  fi
}
trap cleanup EXIT

WORK_DIR="$(mktemp -d -t echild-probe-XXXXXX)"
# Give the probe access to c2c MCP server so we also exercise MCP tool
# paths (important: the matcher-narrow fix means PostToolUse should NOT
# fire for mcp__* tools; this confirms it in practice).
if [ -f "$REPO_ROOT/.mcp.json" ]; then
  cp "$REPO_ROOT/.mcp.json" "$WORK_DIR/.mcp.json"
fi
echo "==> work dir: $WORK_DIR"
echo "==> tmux session: $SESSION"
echo "==> capture: $CAPTURE_FILE"

tmux new-session -d -s "$SESSION" -x 220 -y 60 "cd $WORK_DIR && exec fish"
sleep 0.5

# Launch Claude. --dangerously-skip-permissions avoids mid-turn prompts;
# we are running throwaway tool calls in a tempdir. Use haiku for speed —
# hooks don't care which model answers.
MODEL="${C2C_ECHILD_MODEL:-claude-haiku-4-5-20251001}"
tmux send-keys -t "$SESSION" "claude --dangerously-skip-permissions --model $MODEL" Enter

echo "==> waiting for claude TUI..."
trust_dismissed=0
ready=0
for _ in $(seq 1 90); do
  sleep 1
  pane="$(tmux capture-pane -t "$SESSION" -p -S -200 || true)"
  if [ "$trust_dismissed" -eq 0 ] && printf '%s' "$pane" | grep -q 'trust this folder'; then
    "$ENTER" "$SESSION"
    trust_dismissed=1
    sleep 2
    continue
  fi
  if printf '%s' "$pane" | grep -qE 'bypass permissions on|shift\+tab to cycle|Type "/help|Welcome back'; then
    ready=1
    break
  fi
done
if [ "$ready" -eq 0 ]; then
  echo "FAIL: claude TUI did not come up in 90s" >&2
  tmux capture-pane -t "$SESSION" -p -S -200 > "$CAPTURE_FILE"
  exit 2
fi
sleep 2

send_prompt() {
  local prompt="$1"
  printf '%s' "$prompt" | tmux load-buffer -
  tmux paste-buffer -t "$SESSION"
  sleep 1
  "$ENTER" "$SESSION"
}

wait_idle() {
  local max="${1:-120}"
  local stable=0
  local prev=""
  for _ in $(seq 1 "$max"); do
    sleep 2
    local now
    now="$(tmux capture-pane -t "$SESSION" -p -S -200 || true)"
    if [ "$now" = "$prev" ]; then
      stable=$((stable + 1))
      [ $stable -ge 3 ] && return 0
    else
      stable=0
    fi
    prev="$now"
  done
}

PROMPT='Please perform these steps one at a time, each as its own tool call, and do not ask for permission: 1. Bash: ls /tmp | head -3. 2. Bash: echo hello-echild. 3. Write a file named probe.txt with contents "one two three". 4. Read probe.txt. 5. Edit probe.txt to replace "two" with "TWO". 6. Grep for TWO in probe.txt. 7. Glob for *.txt. 8. Call mcp__c2c__whoami. 9. Call mcp__c2c__list. 10. Call mcp__c2c__poll_inbox. After step 10, print DONE_PROBE and stop.'

echo "==> sending probe prompt"
send_prompt "$PROMPT"

echo "==> waiting for DONE_PROBE (or idle)..."
done=0
# up to ~10 minutes: 300 * 2s. DONE_PROBE appears once in the prompt
# itself (echoed back in the TUI), so require >=2 occurrences to count
# the model's own printing of it.
for i in $(seq 1 300); do
  sleep 2
  pane_now="$(tmux capture-pane -t "$SESSION" -p -S -5000 || true)"
  n_done="$(printf '%s' "$pane_now" | grep -c 'DONE_PROBE' || true)"
  if [ "${n_done:-0}" -ge 2 ]; then
    done=1
    break
  fi
  # Give up early if the session clearly errored out (e.g. API/session
  # limit). Look for common fatal banners in the pane.
  if printf '%s' "$pane_now" | grep -qE 'Session limit reached|API Error|Unhandled exception'; then
    echo "  (early-exit: fatal banner detected)"
    break
  fi
done
# Give trailing hooks / thinking indicators a moment to settle so any
# PostToolUse errors land in the scrollback.
sleep 5
[ "$done" -eq 0 ] && wait_idle 30

tmux capture-pane -t "$SESSION" -p -S -20000 > "$CAPTURE_FILE"
echo "==> done=$done, capture written ($(wc -l < "$CAPTURE_FILE") lines)"

PATTERNS=(
  '\bECHILD\b'
  'hook error'
  'Failed with non-blocking status code'
  '\bwaitpid\b'
  'PostToolUse:[A-Za-z_]+ hook error'
  'UserPromptSubmit.*hook error'
  '\bStop\b.*hook error'
  'PreCompact.*hook error'
  'Error occurred while executing hook command'
)

fail=0
echo ""
echo "==> pattern scan:"
for p in "${PATTERNS[@]}"; do
  hits="$(grep -nE "$p" "$CAPTURE_FILE" || true)"
  if [ -n "$hits" ]; then
    count="$(printf '%s\n' "$hits" | wc -l)"
    echo "  [FAIL] $p  ($count hits)"
    printf '%s\n' "$hits" | head -5 | sed 's/^/         /'
    fail=1
  else
    echo "  [ ok ] $p"
  fi
done

echo ""
if [ "$fail" -eq 0 ]; then
  echo "==> CLEAN: no known hook-error patterns matched."
  echo "==> capture saved at: $CAPTURE_FILE"
  echo "==> please review the capture manually to confirm nothing new."
  exit 0
else
  echo "==> FAIL: hook errors present. Full capture: $CAPTURE_FILE"
  exit 1
fi
