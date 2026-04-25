#!/usr/bin/env bash
# c2c pre-commit hook — blocks direct-to-master unless C2C_COORDINATOR=1
set -euo pipefail

BRANCH=$(git symbolic-ref HEAD 2>/dev/null | sed 's|refs/heads/||') || true
PROTECTED="^(master|main)$"

if [[ "$BRANCH" =~ $PROTECTED ]] && [[ "${C2C_COORDINATOR:-}" != "1" ]]; then
  echo "[c2c hook] BLOCKED: direct-to-master commit detected." >&2
  echo "Target branch: $BRANCH" >&2
  echo "Set C2C_COORDINATOR=1 to bypass (coordinators only)." >&2
  exit 1
fi

# Bypass: append trailer to commit message file ($1 = commit message file path)
if [[ "${C2C_COORDINATOR:-}" == "1" ]]; then
  MSG_FILE="${1:-}"
  if [[ -n "$MSG_FILE" ]] && [[ -f "$MSG_FILE" ]]; then
    echo "Bypassed-pre-commit-hook: coordinator" >> "$MSG_FILE"
  fi
fi
# Fall through — commit proceeds normally