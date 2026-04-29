#!/usr/bin/env bash
# scripts/coord-unmerged-watch.sh
#
# Coordinator's unmerged-branch detector. Walks all local branches, finds
# tips ahead of master, and emits ONE LINE per branch only when its tip
# CHANGES since the last run. State persisted in /tmp/.c2c-unmerged-state.
#
# Designed for Monitor loops:
#   while true; do scripts/coord-unmerged-watch.sh; sleep 60; done
# Each cherry-pick-eligible new tip fires exactly once.
#
# Usage:
#   coord-unmerged-watch.sh           # default state file
#   coord-unmerged-watch.sh --state /tmp/foo.state
#   coord-unmerged-watch.sh --reset   # wipe state, will emit everything next run
#   coord-unmerged-watch.sh --once    # one-shot dump, no state writes (debug)
#
# State file format: one `<branch> <tip-sha>` line per branch.
#
# Exit codes:
#   0 — ran successfully
#   1 — usage / git error

set -euo pipefail

STATE_FILE="${C2C_UNMERGED_STATE:-/tmp/.c2c-unmerged-state}"
ONCE=0
RESET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --state) shift; STATE_FILE="${1:-$STATE_FILE}" ;;
    --state=*) STATE_FILE="${1#--state=}" ;;
    --reset) RESET=1 ;;
    --once) ONCE=1 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "[coord-unmerged-watch] error: unknown arg '$1'" >&2; exit 1 ;;
  esac
  shift
done

git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "[coord-unmerged-watch] error: not in a git repo" >&2
  exit 1
}

if [ "$RESET" = "1" ]; then
  rm -f "$STATE_FILE"
  echo "[coord-unmerged-watch] state reset: $STATE_FILE"
  exit 0
fi

# Load prior state into associative array (bash 4+).
declare -A prior_tip
if [ -f "$STATE_FILE" ]; then
  while read -r b t; do
    [ -n "$b" ] && [ -n "$t" ] && prior_tip["$b"]="$t"
  done < "$STATE_FILE"
fi

# Build current state.
declare -A current_tip
declare -A current_subj
declare -A current_ahead

while IFS='|' read -r branch tip subj; do
  [ "$branch" = "master" ] && continue

  ahead="$(git log --oneline master..$branch 2>/dev/null | wc -l | tr -d ' ')"
  [ "$ahead" -eq 0 ] && continue

  current_tip["$branch"]="$tip"
  current_subj["$branch"]="$subj"
  current_ahead["$branch"]="$ahead"
done < <(git for-each-ref --format='%(refname:short)|%(objectname:short)|%(subject)' refs/heads/)

# Diff: emit branches whose tip changed (new branch, or advanced).
for branch in "${!current_tip[@]}"; do
  cur="${current_tip[$branch]}"
  prev="${prior_tip[$branch]:-NONE}"
  if [ "$cur" != "$prev" ]; then
    ahead="${current_ahead[$branch]}"
    subj="${current_subj[$branch]}"
    if [ "$prev" = "NONE" ]; then
      echo "[unmerged NEW] $branch ($ahead ahead, tip=$cur): $subj"
    else
      echo "[unmerged UPDATED] $branch (was=$prev, now=$cur, $ahead ahead): $subj"
    fi
  fi
done

# Persist current state (skip when --once).
if [ "$ONCE" = "0" ]; then
  : > "$STATE_FILE"
  for branch in "${!current_tip[@]}"; do
    echo "$branch ${current_tip[$branch]}" >> "$STATE_FILE"
  done
fi

exit 0
