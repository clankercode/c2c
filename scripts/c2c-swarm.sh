#!/usr/bin/env bash
# c2c-swarm.sh — operate on the c2c swarm of Claude Code tmux panes by ALIAS.
#
# The swarm lives in tmux, one pane per agent, each launched via
# `c2c start claude -n <alias>`. Pane indices drift across tmux restarts, so
# we resolve alias → pane by walking processes: pane_pid's child is usually
# a `c2c` wrapper whose argv contains `-n <alias>`.
#
# Commands:
#   list                 Show all swarm panes: alias, target, pane_pid, claude_pid, idle-hint
#   peek <alias> [N]     Print last N lines of that alias's pane (default 20)
#   peek-all [N]         Peek every alias
#   send <alias> <text>  Type <text> + Enter into that alias's pane
#                        Uses scripts/c2c-tmux-enter.sh for Enter (extended-keys safe)
#   send-raw <alias> <text>  Type <text> without a trailing Enter
#   keys <alias> <tmux-key>...  Forward raw tmux key tokens (Enter,
#                        Escape, Up, C-c, M-x, …). Use for dismissing
#                        dialogs, sending interrupts, navigating menus.
#   enter <alias>        Send the extended-keys-safe Enter by itself
#                        (same helper `send` uses). Handy after `send-raw`
#                        or for confirming a dialog.
#   follow <alias> [log] Start streaming pane to LOG (default /tmp/c2c-swarm-<alias>.log)
#   unfollow <alias>     Stop pipe-pane on that alias
#   grep <regex>         Grep scrollback across all swarm panes (ANSI stripped)
#   grep-echild          Convenience: grep -i echild across all swarm panes
#   restart <alias>      Send /exit to the pane, wait for it to return to shell,
#                        then relaunch `c2c start claude -n <alias>` in the same pane
#   whoami               Identify the pane this script is being called from (if tmux)
#
# Exit codes: 0 on success, 2 on usage error, 3 if alias not found, 1 otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTER_HELPER="${SCRIPT_DIR}/c2c-tmux-enter.sh"

usage() {
  sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

# ---------- alias ↔ pane resolution ----------

# Print one line per swarm pane: <target> <pane_pid> <claude_pid> <alias>
# target is "session:window.pane". Returns 0 even if empty.
_enumerate_swarm() {
  tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_pid}' 2>/dev/null | while read -r target pane_pid; do
    # walk one level down: pane's fg child
    child_pid=$(pgrep -P "$pane_pid" 2>/dev/null | head -1 || true)
    [ -z "$child_pid" ] && continue
    args=$(ps -p "$child_pid" -o args= 2>/dev/null || true)
    case "$args" in
      *"c2c start claude -n "*)
        alias=$(printf '%s\n' "$args" | sed -n 's/.*-n \([^ ]*\).*/\1/p')
        # resolve claude PID (child of the wrapper), best-effort
        claude_pid=$(pgrep -P "$child_pid" -x claude 2>/dev/null | head -1 || echo "-")
        printf '%s\t%s\t%s\t%s\n' "$target" "$pane_pid" "$claude_pid" "$alias"
        ;;
    esac
  done
}

# Resolve an alias to a tmux target. Exits 3 if not found.
_target_for_alias() {
  local want="$1"
  local line target pane_pid claude_pid alias
  while IFS=$'\t' read -r target pane_pid claude_pid alias; do
    if [ "$alias" = "$want" ]; then
      printf '%s' "$target"
      return 0
    fi
  done < <(_enumerate_swarm)
  echo "c2c-swarm: no alias '$want' found; try \`$0 list\`" >&2
  return 3
}

# ---------- commands ----------

cmd_list() {
  printf 'ALIAS\tTARGET\tPANE_PID\tCLAUDE_PID\tLAST_LINE\n'
  while IFS=$'\t' read -r target pane_pid claude_pid alias; do
    # Peek last non-empty line of the pane as a crude "idle/busy" hint
    last=$(tmux capture-pane -t "$target" -p 2>/dev/null | awk 'NF{last=$0} END{print last}' | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-60)
    printf '%s\t%s\t%s\t%s\t%s\n' "$alias" "$target" "$pane_pid" "$claude_pid" "$last"
  done < <(_enumerate_swarm) | column -t -s $'\t'
}

cmd_peek() {
  local alias="${1:?usage: peek <alias> [lines]}"
  local lines="${2:-20}"
  local target; target=$(_target_for_alias "$alias")
  tmux capture-pane -t "$target" -p | tail -n "$lines"
}

cmd_peek_all() {
  local lines="${1:-10}"
  while IFS=$'\t' read -r target pane_pid claude_pid alias; do
    printf '===== %s (%s) =====\n' "$alias" "$target"
    tmux capture-pane -t "$target" -p | tail -n "$lines"
    printf '\n'
  done < <(_enumerate_swarm)
}

cmd_send() {
  local alias="${1:?usage: send <alias> <text...>}"; shift
  local target; target=$(_target_for_alias "$alias")
  local text="$*"
  # literal text then extended-keys-safe Enter
  tmux send-keys -t "$target" -l "$text"
  "$ENTER_HELPER" "$target"
}

cmd_send_raw() {
  local alias="${1:?usage: send-raw <alias> <text...>}"; shift
  local target; target=$(_target_for_alias "$alias")
  tmux send-keys -t "$target" -l "$*"
}

# Forward raw tmux key names / special keys to a pane. No -l, so tokens
# like `Enter`, `Escape`, `Up`, `C-c`, `M-x` are interpreted by tmux.
# Useful for dismissing dialogs, navigating menus, sending interrupts.
cmd_keys() {
  local alias="${1:?usage: keys <alias> <tmux-key>...  (e.g. keys planner1 Enter, keys coder1 C-c)}"; shift
  local target; target=$(_target_for_alias "$alias")
  tmux send-keys -t "$target" "$@"
}

# Convenience: extended-keys-safe Enter (same helper `send` uses internally).
# Separate from `keys <alias> Enter` because Claude Code's TUI has a
# keybinding that treats raw tmux `Enter` differently from the helper's
# bracketed sequence in some modes.
cmd_enter() {
  local alias="${1:?usage: enter <alias>}"
  local target; target=$(_target_for_alias "$alias")
  "$ENTER_HELPER" "$target"
}

cmd_follow() {
  local alias="${1:?usage: follow <alias> [logfile]}"
  local logfile="${2:-/tmp/c2c-swarm-$alias.log}"
  local target; target=$(_target_for_alias "$alias")
  tmux pipe-pane -t "$target" -o "cat >> $logfile"
  printf 'streaming %s (%s) → %s\n' "$alias" "$target" "$logfile"
  printf 'stop with: %s unfollow %s\n' "$0" "$alias"
}

cmd_unfollow() {
  local alias="${1:?usage: unfollow <alias>}"
  local target; target=$(_target_for_alias "$alias")
  tmux pipe-pane -t "$target"
  printf 'stopped streaming %s\n' "$alias"
}

_grep_swarm() {
  # $1 = extra grep flag(s), $2 = pattern
  local flags="$1" pattern="$2"
  local hits=0
  while IFS=$'\t' read -r target pane_pid claude_pid alias; do
    local out
    out=$(tmux capture-pane -t "$target" -pS -2000 | sed 's/\x1b\[[0-9;]*m//g' | grep -nE $flags -- "$pattern" || true)
    if [ -n "$out" ]; then
      hits=$((hits+1))
      printf '===== %s (%s) =====\n' "$alias" "$target"
      printf '%s\n' "$out"
      printf '\n'
    fi
  done < <(_enumerate_swarm)
  [ "$hits" -eq 0 ] && echo "(no matches across swarm)" >&2
  return 0
}

cmd_grep() {
  local pattern="${1:?usage: grep <regex>}"
  _grep_swarm '' "$pattern"
}

cmd_grep_echild() {
  _grep_swarm '-i' 'echild'
}

cmd_restart() {
  local alias="${1:?usage: restart <alias>}"
  local target; target=$(_target_for_alias "$alias")
  echo "restarting $alias at $target …"
  # Claude Code responds to /exit slash command
  tmux send-keys -t "$target" -l '/exit'
  "$ENTER_HELPER" "$target"
  echo "sent /exit; waiting up to 30s for shell prompt to return…"
  # The shell-ready signal is the c2c-start wrapper's post-exit banner
  # ("resume via: c2c start …"). Waiting on a bare "❯" is unreliable
  # because Claude's "Background work is running" confirmation dialog
  # also renders "❯ 1. Exit anyway" in its last three lines. If we see
  # that dialog, press Enter to confirm option 1 (Exit anyway).
  local i=0 confirmed=0
  while [ $i -lt 60 ]; do
    local snap
    snap=$(tmux capture-pane -t "$target" -p | tail -15 | sed 's/\x1b\[[0-9;]*m//g')
    case "$snap" in
      *'resume via: c2c start'*)
        echo "shell prompt detected (c2c-start exit banner)"
        break
        ;;
      *'Background work is running'*|*'Exit anyway'*)
        if [ "$confirmed" -eq 0 ]; then
          echo "confirm-exit dialog detected; pressing Enter to confirm"
          "$ENTER_HELPER" "$target"
          confirmed=1
        fi
        ;;
    esac
    sleep 0.5
    i=$((i+1))
  done
  echo "relaunching: c2c start claude -n $alias"
  tmux send-keys -t "$target" -l "c2c start claude -n $alias"
  "$ENTER_HELPER" "$target"
  echo "done — give Claude Code a few seconds to boot"
}

cmd_whoami() {
  if [ -z "${TMUX:-}" ]; then
    echo "c2c-swarm: not running inside a tmux session" >&2
    return 1
  fi
  # Use -t "$TMUX_PANE" so we identify the *calling* pane, not the focused one.
  local my_pane; my_pane=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{session_name}:#{window_index}.#{pane_index}')
  while IFS=$'\t' read -r target pane_pid claude_pid alias; do
    if [ "$target" = "$my_pane" ]; then
      printf 'alias=%s target=%s pane_pid=%s claude_pid=%s\n' "$alias" "$target" "$pane_pid" "$claude_pid"
      return 0
    fi
  done < <(_enumerate_swarm)
  printf 'tmux pane=%s (not a swarm pane)\n' "$my_pane"
}

# ---------- dispatch ----------

cmd="${1:-}"; shift || true
case "$cmd" in
  list)          cmd_list "$@" ;;
  peek)          cmd_peek "$@" ;;
  peek-all)      cmd_peek_all "$@" ;;
  send)          cmd_send "$@" ;;
  send-raw)      cmd_send_raw "$@" ;;
  keys)          cmd_keys "$@" ;;
  enter)         cmd_enter "$@" ;;
  follow)        cmd_follow "$@" ;;
  unfollow)      cmd_unfollow "$@" ;;
  grep)          cmd_grep "$@" ;;
  grep-echild)   cmd_grep_echild "$@" ;;
  restart)       cmd_restart "$@" ;;
  whoami)        cmd_whoami "$@" ;;
  -h|--help|help|"") usage ;;
  *) echo "c2c-swarm: unknown command '$cmd'" >&2; usage ;;
esac
