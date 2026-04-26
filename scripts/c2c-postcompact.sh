#!/bin/bash
# c2c-postcompact.sh — PostCompact hook for Claude Code.
#
# Fires after Claude Code context compaction completes. Two jobs:
#   1. Clear the compacting flag so senders stop getting compacting warnings.
#   2. Emit a <c2c-context kind="post-compact"> additionalContext block via
#      c2c-post-compact-hook (#317), giving the post-compact agent a fresh
#      pointer to in-flight slices, recent findings, fresh shared memory,
#      and the operational reflex reminder (channel-tag-reply trap, etc.).
#
# Required env vars (set by c2c start or the MCP server entry):
#   C2C_MCP_SESSION_ID   — broker session id
#   C2C_MCP_BROKER_ROOT  — absolute path to broker root dir
#
# IMPORTANT: do NOT use `exec` here. Claude Code's Node.js hook runner
# tracks the initially-spawned bash PID; exec'ing into a different
# binary surfaces ECHILD on subsequent tool calls. Run children as
# subprocesses and exit normally.

# Resolve repo root the same way the cold-boot hook does.
SCRIPT_DIR="$(dirname "$0")"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null || echo "$SCRIPT_DIR")"

if command -v c2c >/dev/null 2>&1; then
    c2c clear-compact 2>/dev/null
fi

# Emit the post-compact context block. Try installed binary first, fall
# back to dev-tree _build path. If neither is available, sleep briefly
# (avoid Node ECHILD race) and exit silently.
if command -v c2c-post-compact-hook >/dev/null 2>&1; then
    C2C_REPO_ROOT="$REPO_ROOT" c2c-post-compact-hook
elif [ -x "$REPO_ROOT/_build/default/ocaml/tools/c2c_post_compact_hook.exe" ]; then
    C2C_REPO_ROOT="$REPO_ROOT" "$REPO_ROOT/_build/default/ocaml/tools/c2c_post_compact_hook.exe"
else
    sleep 0.05
fi
exit 0
