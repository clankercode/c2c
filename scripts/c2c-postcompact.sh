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

# Resolve repo root by trying multiple strategies, in order:
#   1. SCRIPT_DIR/.. (works when script is in repo's scripts/ dir)
#   2. CWD (Claude Code spawns the hook from the repo root)
# We deliberately do NOT fall back to SCRIPT_DIR itself — that yields
# the wrong root when the script is symlinked/copied to ~/.claude/hooks/
# (where there's no .git), and the OCaml hook would then accept it as
# a directory and fail to find the real findings/memory/worktrees.
SCRIPT_DIR="$(dirname "$0")"
detect_repo_root() {
    local candidate
    # 1. SCRIPT_DIR-relative (script lives in <repo>/scripts/).
    candidate="$(cd "$SCRIPT_DIR" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null)"
    if [ -n "$candidate" ] && [ -d "$candidate/.git" -o -f "$candidate/.git" ]; then
        printf '%s' "$candidate"
        return 0
    fi
    # 2. CWD-relative (Claude Code runs the hook from the repo root).
    candidate="$(git rev-parse --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null)"
    if [ -n "$candidate" ] && [ -d "$candidate/.git" -o -f "$candidate/.git" ]; then
        printf '%s' "$candidate"
        return 0
    fi
    return 1
}
REPO_ROOT="$(detect_repo_root || true)"

if command -v c2c >/dev/null 2>&1; then
    c2c clear-compact 2>/dev/null
fi

# Emit the post-compact context block. Try installed binary first, fall
# back to dev-tree _build path. Only set C2C_REPO_ROOT if we resolved a
# real repo root (lets the OCaml hook's own `repo_root ()` fall back to
# `git rev-parse` from CWD if our detection failed). If neither binary
# is available, sleep briefly (avoid Node ECHILD race) and exit silently.
run_hook() {
    local bin="$1"
    if [ -n "$REPO_ROOT" ]; then
        C2C_REPO_ROOT="$REPO_ROOT" "$bin"
    else
        "$bin"
    fi
}
if command -v c2c-post-compact-hook >/dev/null 2>&1; then
    run_hook c2c-post-compact-hook
elif [ -n "$REPO_ROOT" ] && [ -x "$REPO_ROOT/_build/default/ocaml/tools/c2c_post_compact_hook.exe" ]; then
    run_hook "$REPO_ROOT/_build/default/ocaml/tools/c2c_post_compact_hook.exe"
else
    sleep 0.05
fi
exit 0
