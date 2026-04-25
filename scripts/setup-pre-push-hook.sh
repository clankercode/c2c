#!/usr/bin/env bash
# setup-pre-push-hook.sh — installs the pre-push hook to .git/hooks/
#
# Usage: ./scripts/setup-pre-push-hook.sh [--force]
#
# The hook restricts pushes to origin/master unless C2C_COORDINATOR=1 is set.
# This enforces the coordinator-only push policy for the shared dev tree.
#
# --force: overwrite existing pre-push hook without prompting

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK_SOURCE="$REPO_ROOT/scripts/git-hooks/pre-push"
HOOK_TARGET="$REPO_ROOT/.git/hooks/pre-push"

if [[ ! -f "$HOOK_SOURCE" ]]; then
  echo "error: pre-push hook not found at $HOOK_SOURCE" >&2
  exit 1
fi

if [[ -f "$HOOK_TARGET" ]] && [[ "${1:-}" != "--force" ]]; then
  echo "pre-push hook already installed. Use --force to overwrite." >&2
  echo "Current hook:" >&2
  head -5 "$HOOK_TARGET" >&2
  exit 1
fi

# Backup existing hook
if [[ -f "$HOOK_TARGET" ]]; then
  cp "$HOOK_TARGET" "$HOOK_TARGET.bak.$(date +%Y%m%d%H%M%S)"
  echo "Backed up existing hook to $HOOK_TARGET.bak.*"
fi

cp "$HOOK_SOURCE" "$HOOK_TARGET"
chmod +x "$HOOK_TARGET"

echo "Installed pre-push hook to $HOOK_TARGET"
echo "Pushing to origin/master now requires C2C_COORDINATOR=1"
