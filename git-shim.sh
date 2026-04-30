#!/bin/bash
# git-shim: refuses git reset --hard <ref> in main tree when it would lose commits;
# refuses git commit on main/master branches by default (Pattern 16).
# C2C_COORDINATOR=1 bypasses. C2C_COMMIT_REFUSE=0 restores warn-only.
#
# Install: add this dir to PATH, BEFORE the real git.
# The shim detects "git reset --hard <target>" and checks whether <target>
# is strictly behind HEAD. If so, it refuses unless C2C_COORDINATOR=1.
# For git commit, it warns (or refuses with C2C_COMMIT_REFUSE=1) when
# running in the main tree (cwd = main repo root) unless C2C_COORDINATOR=1.
#
# The main-tree guard fires when cwd equals the main repo root AND
# GIT_WORK_TREE is not set (git sets GIT_WORK_TREE when inside a worktree,
# so this distinguishes main-repo-root-on-worktree-branch from true worktree).
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

# Returns 0 (true) if we are inside a git worktree (GIT_WORK_TREE is set
# by git itself when the git command runs inside a worktree). This replaces
# the previous heuristic that checked the branch name — that heuristic
# fails when cwd is the main repo root but HEAD points to a worktree branch
# (the worktree's HEAD symref is active in the main repo's .git directory).
is_worktree_branch() {
    # GIT_WORK_TREE is set by git when operating inside a worktree.
    # In the main repo it is always empty/unset.
    [ -n "${GIT_WORK_TREE:-}" ]
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
    # Dispatch: handle reset and commit specially; pass everything else through.
    case "$1" in
        reset)
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
            ;;
        commit)
            # git commit — refuse on main/master branches in main tree by default.
            # Non-coordinators must use worktrees for commits.
            # C2C_COORDINATOR=1 bypasses entirely.
            # C2C_COMMIT_REFUSE=0 restores the old warn-only behavior (not recommended).
            if is_main_tree && [ "$COORDINATOR" != "1" ]; then
                if ! is_worktree_branch; then
                    if [ "${C2C_COMMIT_REFUSE:-1}" = "1" ]; then
                        echo "fatal: git-shim refused 'git commit' on main/master branch." >&2
                        echo "fatal: non-coordinators must use worktrees for commits." >&2
                        echo "fatal: set C2C_COORDINATOR=1 to bypass (coordinators only)." >&2
                        echo "fatal: set C2C_COMMIT_REFUSE=0 to warn only (not recommended)." >&2
                        exit 128
                    else
                        echo "WARNING: committing directly to main/master branch." >&2
                        echo "WARNING: non-coordinators should use worktrees for commits." >&2
                        echo "WARNING: set C2C_COORDINATOR=1 to bypass, C2C_COMMIT_REFUSE=1 to refuse." >&2
                    fi
                fi
            fi
            exec /usr/bin/git "$@"
            ;;
        *)
            exec /usr/bin/git "$@"
            ;;
    esac
}

main "$@"
