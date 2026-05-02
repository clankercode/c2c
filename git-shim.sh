#!/bin/bash
# git-shim: guards destructive / branch-ref-mutating git operations in the
# main tree. Non-coordinators must use worktrees for these operations.
# C2C_COORDINATOR=1 bypasses all guards.
#
# Guarded operations:
#   - git reset --hard <ref>  — refuses when <ref> is behind HEAD (commit loss)
#   - git commit              — refuses on main/master in main tree
#   - git switch <branch>     — refuses branch-ref mutations in main tree
#   - git checkout <branch>   — refuses branch-switching form (allows file ops)
#   - git rebase <upstream>   — refuses all forms except --continue/--abort/--skip
#
# The main-tree guard fires when .git is a directory (main repo).
# Worktrees have .git as a file (gitdir reference) — never fire the guard.
#
# Install: this file is installed as git-pre-reset by `c2c install self` (or
# `c2c install all`). The c2c binary's install step copies this file into the
# same directory as the attribution shim (the "git" shim) so both are found via
# PATH ordering when the shim directory is prepended to PATH.
#
# Design: .collab/design/2026-05-02-hardening-c-pre-reset-shim-branch-guard.md

set -euo pipefail

# ---------------------------------------------------------------------------
# Runaway-spawn guard: defense-in-depth against rev-parse storms.
# Count live shim/git processes; if too many are running, pass through to
# the real git directly so we don't add yet another process to an already
# overloaded system.  Threshold of 5 is low enough to catch a storm early,
# high enough to not trigger on normal concurrent git usage.
# ---------------------------------------------------------------------------
if [ -z "${C2C_SHIM_GUARD_DISABLE:-}" ]; then
    # pgrep matches this process too (we are 'git' in PATH), so subtract 1.
    # This is approximate — if the real /usr/bin/git is also in PATH (it
    # shouldn't be), those processes are harmless noise here.
    shim_count=$(pgrep -c -f "git-shim|git-pre-reset" 2>/dev/null || echo "0")
    if [ "$shim_count" -gt 5 ]; then
        echo "git-shim: WARNING: $shim_count shim processes running (threshold 5); bypassing shim to avoid spawn storm." >&2
        exec /usr/bin/git "$@"
    fi
fi

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

# ---------------------------------------------------------------------------
# Shared refusal message for branch-ref mutations in main tree.
# $1 = the full git command description (e.g. "git switch feature-branch")
# ---------------------------------------------------------------------------
refuse_branch_mutation() {
    echo "fatal: git-shim refused '$1' in main tree." >&2
    echo "fatal: branch-ref-mutating operations are not allowed in the main tree." >&2
    echo "fatal: use a worktree for this operation, or set C2C_COORDINATOR=1 to bypass." >&2
    exit 128
}

main() {
    # Dispatch: handle destructive/branch-ref-mutating ops specially;
    # pass everything else through to /usr/bin/git.
    # Guards: reset (--hard), commit, switch, checkout, rebase.
    case "$1" in
        reset)
            # "git reset" — check for --hard
            local orig_args=("$@")
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
                # Not --hard; let git handle it (pass through full arg list)
                exec /usr/bin/git "${orig_args[@]}"
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
        switch)
            # git switch — branch-ref mutation guard.
            # Refuse: switch <branch>, switch -c <branch>, switch -C <branch>
            # Allow:  switch - (previous branch), switch with no args, --help, --version
            local orig_args=("$@")
            if is_main_tree && [ "$COORDINATOR" != "1" ]; then
                shift  # consume "switch"
                local switch_refuse=false
                while [ $# -gt 0 ]; do
                    case "$1" in
                        -)
                            # "switch -" = return to previous branch — allowed
                            ;;
                        -c|-C|--create|--force-create)
                            # Create + switch — refuse
                            switch_refuse=true
                            break
                            ;;
                        --help|--version)
                            # Info-only — allow
                            ;;
                        -*)
                            # Other flags (-d/--detach, -q, etc.) — ignore
                            ;;
                        *)
                            # Positional arg = branch name — refuse
                            switch_refuse=true
                            break
                            ;;
                    esac
                    shift
                done
                if [ "$switch_refuse" = "true" ]; then
                    refuse_branch_mutation "git switch ..."
                fi
            fi
            exec /usr/bin/git "${orig_args[@]}"
            ;;
        checkout)
            # git checkout — dual-purpose command: branch switching AND file operations.
            #
            # Branch-switching form (REFUSE in main tree):
            #   git checkout <branch>
            #   git checkout -b <branch>
            #   git checkout HEAD~1  (detaches HEAD)
            #
            # File operation form (ALLOW):
            #   git checkout -- <file>
            #   git checkout <rev> -- <file>
            #   git checkout -  (return to previous branch)
            #
            # Key signal: presence of "--" separator → always a file operation.
            local orig_args=("$@")
            if is_main_tree && [ "$COORDINATOR" != "1" ]; then
                local has_double_hyphen=false
                local has_positional=false
                local has_create_flag=false
                local first_positional=""

                shift  # consume "checkout"
                while [ $# -gt 0 ]; do
                    case "$1" in
                        --)
                            has_double_hyphen=true
                            break
                            ;;
                        -b|-B)
                            has_create_flag=true
                            ;;
                        -)
                            # "checkout -" = return to previous branch — safe
                            ;;
                        -*)
                            # Other flags (--ours, --theirs, -f, -q, etc.)
                            ;;
                        *)
                            if [ "$has_positional" = "false" ]; then
                                first_positional="$1"
                                has_positional=true
                            fi
                            ;;
                    esac
                    shift
                done

                if [ "$has_double_hyphen" = "false" ]; then
                    # No "--" separator — could be branch-switching
                    if [ "$has_create_flag" = "true" ]; then
                        refuse_branch_mutation "git checkout -b ..."
                    elif [ "$has_positional" = "true" ] && [ "$first_positional" != "-" ]; then
                        refuse_branch_mutation "git checkout $first_positional"
                    fi
                fi
                # If we get here, it's allowed (file op or "-")
            fi
            exec /usr/bin/git "${orig_args[@]}"
            ;;
        rebase)
            # git rebase — always a branch-ref mutation.
            # Refuse: rebase <upstream>, rebase --onto, rebase -i
            # Allow:  rebase --continue, rebase --abort, rebase --skip (state management)
            local orig_args=("$@")
            if is_main_tree && [ "$COORDINATOR" != "1" ]; then
                shift  # consume "rebase"
                local rebase_state_mgmt=false
                while [ $# -gt 0 ]; do
                    case "$1" in
                        --continue|--abort|--skip|--quit)
                            rebase_state_mgmt=true
                            break
                            ;;
                        *)
                            ;;
                    esac
                    shift
                done
                if [ "$rebase_state_mgmt" = "false" ]; then
                    refuse_branch_mutation "git rebase ..."
                fi
            fi
            exec /usr/bin/git "${orig_args[@]}"
            ;;
        --self-test)
            # Smoke-test: verify shim loads without errors under set -euo pipefail
            # and that branch-ref-mutation guards fire correctly.
            # Exit 0 on success, non-zero on any failure.
            local failures=0

            # Basic: git rev-parse works through the shim
            if ! /usr/bin/git rev-parse --short HEAD > /dev/null 2>&1; then
                echo "FAIL: git rev-parse --short HEAD" >&2
                failures=$((failures + 1))
            fi

            # Guard tests: only meaningful in main tree with COORDINATOR unset
            if is_main_tree && [ "${C2C_COORDINATOR:-0}" != "1" ]; then
                # switch should refuse
                if "$0" switch test-branch-does-not-exist > /dev/null 2>&1; then
                    echo "FAIL: 'git switch <branch>' was not refused in main tree" >&2
                    failures=$((failures + 1))
                fi
                # checkout <branch> should refuse
                if "$0" checkout test-branch-does-not-exist > /dev/null 2>&1; then
                    echo "FAIL: 'git checkout <branch>' was not refused in main tree" >&2
                    failures=$((failures + 1))
                fi
                # checkout -- <file> should be allowed. Use a file that exists in the repo
                # so git itself succeeds (exit 0). If shim refuses, exit = 128.
                local co_rc=0
                "$0" checkout -- CLAUDE.md > /dev/null 2>&1 || co_rc=$?
                if [ "$co_rc" -eq 128 ]; then
                    echo "FAIL: 'git checkout -- <file>' was refused (should be allowed)" >&2
                    failures=$((failures + 1))
                fi
                # rebase should refuse
                if "$0" rebase origin/master > /dev/null 2>&1; then
                    echo "FAIL: 'git rebase <upstream>' was not refused in main tree" >&2
                    failures=$((failures + 1))
                fi
                # rebase --abort should be allowed. Since git returns 128 when no rebase
                # is in progress, we can't distinguish shim-refuse from git-error by exit
                # code alone. Instead, check stderr for the shim's signature message.
                local rb_stderr=""
                rb_stderr=$("$0" rebase --abort 2>&1 || true)
                if echo "$rb_stderr" | grep -q "git-shim refused"; then
                    echo "FAIL: 'git rebase --abort' was refused by shim (should be allowed)" >&2
                    failures=$((failures + 1))
                fi
            fi

            if [ "$failures" -eq 0 ]; then
                echo "shim self-test OK"
                exit 0
            else
                echo "shim self-test FAILED ($failures failures)" >&2
                exit 1
            fi
            ;;
        *)
            exec /usr/bin/git "$@"
            ;;
    esac
}

main "$@"
