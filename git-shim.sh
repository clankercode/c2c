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
# The main-tree guard fires when .git is a directory (main repo).
# Worktrees have .git as a file (gitdir reference) — never fire the guard.
#
# Install: this file is installed as git-pre-reset by `c2c install self` (or
# `c2c install all`). The c2c binary's install step copies this file into the
# same directory as the attribution shim (the "git" shim) so both are found via
# PATH ordering when the shim directory is prepended to PATH.

set -euo pipefail

# Cache the MAIN_TREE computation to avoid re-spawning git on every shell load.
# The cache is invalidated if the current working directory changes (we're in a
# different repo) or if the temp file is missing.  This eliminates the per-shell
# git rev-parse that was adding ~1 call per git invocation when the shim is
# on PATH (e.g. every c2c list from opencode).
MAIN_TREE="$(
    if [ -n \"${C2C_GIT_SHIM_MAIN_TREE:-}\" ]; then
        echo \"${C2C_GIT_SHIM_MAIN_TREE}\"
    elif [ -d /tmp ] && [ -w /tmp ]; then
        # Canonical cache: store computed tree in a temp file, reuse if cwd matches.
        # Use cwd as key so moving between repos invalidates the cache.
        local cache_file=\"/tmp/c2c-git-shim-main-tree-$$
        local marker=\"MAIN_TREE_v1\"
        if [ -f \"$cache_file\" ]; then
            local cached_cwd line
            cached_cwd=\"$(tail -1 \"$cache_file\" 2>/dev/null)\" || true
            if [ \"$cached_cwd\" = \"$(pwd -P)\" ]; then
                head -1 \"$cache_file\" 2>/dev/null || true
                echo \"$(pwd -P)\" >> \"$cache_file\"
                exit 0
            fi
        fi
        local tree
        tree=\"$(git rev-parse --git-common-dir 2>/dev/null | xargs dirname || echo '')\"
        if [ -n \"$tree\" ]; then
            printf '%s\n%s\n' \"$tree\" \"$(pwd -P)\" > \"$cache_file\" 2>/dev/null || true
        fi
        echo \"$tree\"
    else
        git rev-parse --git-common-dir 2>/dev/null | xargs dirname || echo ''
    fi
)"
COORDINATOR="${C2C_COORDINATOR:-0}"

# Resolve to physical path (resolve symlinks, remove trailing slash)
realpath_cwd() {
    local cwd resolved
    cwd="$(pwd -P)"
    cwd="${cwd%/}"
    echo "$cwd"
}

is_main_tree() {
    # Main repo: .git is a directory. Worktree: .git is a file (gitdir reference).
    # This is git's own canonical worktree indicator.
    [ -d ".git" ]
}

# Returns 0 (true) if we are inside a git worktree. This replaces
# the old GIT_WORK_TREE heuristic which git does not set automatically.
is_worktree_branch() {
    # Worktree: .git is a file (gitdir reference). Main repo: .git is a directory.
    # This replaces the old GIT_WORK_TREE heuristic which git does not set automatically.
    [ -f ".git" ]
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
