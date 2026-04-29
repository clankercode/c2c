#!/bin/bash
# git-shim: refuses git reset --hard <ref> in main tree when it would lose commits
#
# Install: add this dir to PATH, BEFORE the real git.
# The shim detects "git reset --hard <target>" and checks whether <target>
# is strictly behind HEAD. If so, it refuses unless C2C_COORDINATOR=1.
#
# The main-tree guard fires when the resolved cwd equals the main repo root.
# All other directories (feature worktrees, subdirs) pass through unchanged.
#
# Usage: install via `c2c install git-shim` or manually add to PATH.

set -euo pipefail

MAIN_TREE="${C2C_GIT_SHIM_MAIN_TREE:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
COORDINATOR="${C2C_COORDINATOR:-0}"

# Resolve to physical path (resolve symlinks, remove trailing slash)
realpath_cwd() {
    local cwd resolved
    cwd="$(pwd -P)"
    cwd="${cwd%/}"
    echo "$cwd"
}

is_main_tree() {
    local cwd
    cwd="$(realpath_cwd)"
    local mt="${MAIN_TREE%/}"
    [ -n "$mt" ] && [ "$cwd" = "$mt" ]
}

# Check whether <target> is strictly behind HEAD (target is an ancestor of HEAD).
# git rev-list --right-only <target>..HEAD = commits in HEAD not reachable from target
# = commits that would be lost by "git reset --hard <target>".
# Non-zero count means target is behind HEAD → reset would discard commits.
target_behind_head() {
    local target="$1"
    local count
    count=$(git rev-list --count --right-only "$target..HEAD" 2>/dev/null || echo "0")
    [ "$count" -gt 0 ]
}

# Echo the target if reset --hard would lose commits, else echo empty.
check_reset_hard() {
    local target="$1"
    # No target = HEAD (no-op, always safe)
    [ -z "$target" ] && return 1
    # A ref that is behind HEAD is dangerous in the main tree
    target_behind_head "$target"
}

main() {
    # Pass through all non-reset commands unchanged
    if [ "$1" != "reset" ]; then
        exec /usr/bin/git "$@"
    fi

    # "git reset" — check for --hard
    local target=""
    local saw_hard=false
    local saw_double_hyphen=false

    shift  # consume "reset"
    while [ $# -gt 0 ]; do
        case "$1" in
            --hard)
                saw_hard=true
                ;;
            --)
                saw_double_hyphen=true
                ;;
            -*)
                # Ignore other flags (--soft, --mixed, -q, etc.)
                ;;
            *)
                if [ -z "$target" ]; then
                    target="$1"
                fi
                ;;
        esac
        shift
    done

    if [ "$saw_hard" != "true" ]; then
        # Not --hard; let git handle it (pass through full arg list including reset)
        exec /usr/bin/git reset "$@"
    fi

    # Interception point: git reset --hard <target>
    if is_main_tree && [ "$COORDINATOR" != "1" ]; then
        if check_reset_hard "$target"; then
            echo "fatal: git-shim refused 'git reset --hard $target' in main tree." >&2
            echo "fatal: this would discard commits ahead of '$target'." >&2
            echo "fatal: if you are a coordinator and intended to do this, set C2C_COORDINATOR=1 in your environment." >&2
            echo "fatal: (this guard is here to prevent accidental 'git reset --hard origin/master' mid-cherry-pick)" >&2
            exit 128
        fi
    fi

    if [ -n "$target" ]; then
        exec /usr/bin/git reset --hard "$target"
    else
        exec /usr/bin/git reset --hard
    fi
}

main "$@"
