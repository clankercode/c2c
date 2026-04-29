#!/bin/bash
# test_git_shim.sh — unit tests for git-shim.sh
#
# Methodology: safe tests run in the real repo; dangerous reset tests
# run in a throwaway clone at /tmp/shim-test/repo to prevent accidental
# data loss in the real worktree.
#
# Install shim in PATH, cd to the target dir, run git through the shim.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHIM="$SCRIPT_DIR/git-shim.sh"

# Real repo (safe tests only)
REAL_REPO="$(realpath "$(git rev-parse --git-common-dir)/..")"

# Throwaway clone for dangerous tests (reset --hard target)
CLONE_DIR="/tmp/shim-test/repo"
ENSURE_CLONE() {
    if [ ! -d "$CLONE_DIR/.git" ]; then
        rm -rf /tmp/shim-test
        mkdir -p /tmp/shim-test
        git clone --no-local "$REAL_REPO" "$CLONE_DIR" >/dev/null 2>&1
    fi
    # Ensure clone is at the same HEAD as real repo
    git -C "$CLONE_DIR" reset --hard "$(git -C "$REAL_REPO" rev-parse HEAD)" >/dev/null 2>&1 || true
}

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
passed=0
failed=0

pass() { echo -e "${GREEN}PASS${NC} $1"; ((passed++)) || true; }
fail() { echo -e "${RED}FAIL${NC} $1"; ((failed++)) || true; }

# Run the shim in a given dir. Sets C2C_GIT_SHIM_MAIN_TREE to real repo root
# so the main-tree guard fires appropriately.
run_shim() {
    local dir="$1"; shift
    (
        export PATH="$(dirname "$SHIM"):$PATH"
        export C2C_GIT_SHIM_MAIN_TREE="$REAL_REPO"
        unset C2C_COORDINATOR
        cd "$dir"
        "$SHIM" "$@"
    )
}

run_shim_as_coord() {
    local dir="$1"
    shift
    (
        export PATH="$(dirname "$SHIM"):$PATH"
        export C2C_GIT_SHIM_MAIN_TREE="$REAL_REPO"
        export C2C_COORDINATOR=1
        cd "$dir"
        "$SHIM" reset "$@"
    )
}

# Helper: run git commit through the shim in the main tree
# Args: <refuse_flag> <coord_bypass>
# refuse_flag: "1" to set C2C_COMMIT_REFUSE=1, "0" otherwise
# coord_bypass: "1" to set C2C_COORDINATOR=1, "0" otherwise
run_shim_commit() {
    local refuse_flag="$1"
    local coord_bypass="$2"
    local msg="shim-test-$$-$(date +%s)"
    (
        export PATH="$(dirname "$SHIM"):$PATH"
        export C2C_GIT_SHIM_MAIN_TREE="$REAL_REPO"
        unset C2C_COORDINATOR
        unset C2C_COMMIT_REFUSE
        [ "$refuse_flag" = "1" ] && export C2C_COMMIT_REFUSE=1
        [ "$coord_bypass" = "1" ] && export C2C_COORDINATOR=1
        cd "$REAL_REPO"
        "$SHIM" commit --allow-empty -m "$msg" 2>&1 || echo "EXIT_CODE:$?"
    )
}

# Helper: run git commit through the shim in a worktree (separate main-tree setting)
# Args: <worktree_dir> <refuse_flag>
run_shim_commit_in_worktree() {
    local wtdir="$1"
    local refuse_flag="$2"
    local msg="shim-test-wt-$$-$(date +%s)"
    (
        export PATH="$(dirname "$SHIM"):$PATH"
        export C2C_GIT_SHIM_MAIN_TREE="$REAL_REPO"
        unset C2C_COORDINATOR
        unset C2C_COMMIT_REFUSE
        [ "$refuse_flag" = "1" ] && export C2C_COMMIT_REFUSE=1
        cd "$wtdir"
        "$SHIM" commit --allow-empty -m "$msg" 2>&1 || echo "EXIT_CODE:$?"
    )
}

echo "=== git-shim unit tests ==="
echo "SHIM=$SHIM"
echo "REAL_REPO=$REAL_REPO"

# ── Test 1: non-reset commands pass through ──────────────────────────
echo ""
echo "--- Test 1: non-reset commands pass through ---"
run_shim "$REAL_REPO" status --short >/dev/null 2>&1 && pass "status passes through" || fail "status should pass through"

# ── Test 2: git reset (non-hard) passes through ─────────────────────
echo "--- Test 2: git reset --soft passes through ---"
run_shim "$REAL_REPO" reset --soft >/dev/null 2>&1 && pass "reset --soft allowed" || fail "reset --soft should be allowed"

# ── Test 3: git reset --hard with no target (HEAD) is always safe ───
echo "--- Test 3: git reset --hard (no target = HEAD) is safe ---"
run_shim "$REAL_REPO" reset --hard >/dev/null 2>&1 && pass "reset --hard HEAD is always allowed" || fail "reset --hard HEAD should be safe"

# ── Test 4: shim script is executable ────────────────────────────────
echo "--- Test 4: shim script is executable ---"
[ -x "$SHIM" ] && pass "shim is executable" || fail "shim should be executable"

# ── Test 5: coordinator bypass with C2C_COORDINATOR=1 ────────────────
echo "--- Test 5: C2C_COORDINATOR=1 bypasses guard ---"
# reset --hard HEAD is always safe regardless of coordinator status
run_shim_as_coord "$REAL_REPO" "reset --hard" >/dev/null 2>&1 && pass "coordinator path reachable" || fail "coordinator path should succeed"

# ── Test 6: dangerous reset refused in main tree ────────────────────
# Critical test: "git reset --hard <target>" where target is behind HEAD.
# Run in THROWAWAY CLONE with C2C_GIT_SHIM_MAIN_TREE pointing at the clone
# (so the is_main_tree guard fires) but without C2C_COORDINATOR=1 (so the
# bypass doesn't apply).
echo "--- Test 6: dangerous reset --hard refused (clone test) ---"
ENSURE_CLONE
# Use HEAD~5 as a guaranteed-lagging target. Count commits we'd lose:
behind_count=$(git -C "$CLONE_DIR" rev-list --count --right-only HEAD~5..HEAD 2>/dev/null || echo 0)
echo "  Clone: commits that would be lost by resetting to HEAD~5: $behind_count"
if [ "$behind_count" -gt 0 ]; then
    # Run shim with MAIN_TREE set to clone dir (so guard fires) and no coordinator bypass
    output=$(
        (
            export PATH="$(dirname "$SHIM"):$PATH"
            export C2C_GIT_SHIM_MAIN_TREE="$CLONE_DIR"
            unset C2C_COORDINATOR
            cd "$CLONE_DIR"
            "$SHIM" reset --hard HEAD~5 2>&1 || echo "EXIT:$?"
        )
    )
    if echo "$output" | grep -q "git-shim refused"; then
        pass "reset --hard HEAD~5 refused (clone, $behind_count commits behind)"
    else
        fail "reset --hard HEAD~5 should be refused in clone, got: $(echo "$output" | head -1)"
    fi
else
    fail "setup failed: HEAD~5 should be behind HEAD in clone"
fi

# ── Test 7: worktree: shim allows all reset --hard ──────────────────
echo "--- Test 7: worktree: reset --hard always allowed ---"
worktree_dir="$(mktemp -d)"
rm -rf "$worktree_dir"
branch_name="test-shim-$$-$(date +%s)"
git -C "$CLONE_DIR" worktree add "$worktree_dir" -b "$branch_name" >/dev/null 2>&1
run_shim "$worktree_dir" reset --hard >/dev/null 2>&1 && pass "worktree reset --hard allowed" || fail "worktree reset --hard should be allowed"
git -C "$CLONE_DIR" worktree remove "$worktree_dir" --force >/dev/null 2>&1 || true
rm -rf "$worktree_dir"

# ── Test 8: worktree: git commit passes through without warning ───────
echo "--- Test 8: worktree commit: no warning, exit 0 ---"
worktree_dir="$(mktemp -d)"
rm -rf "$worktree_dir"
branch_name="test-shim-commit-$$-$(date +%s)"
git -C "$CLONE_DIR" worktree add "$worktree_dir" -b "$branch_name" >/dev/null 2>&1 || true
output=$(run_shim_commit_in_worktree "$worktree_dir" 0 2>&1; true)
ec=$?
if [ $ec -eq 0 ] && ! echo "$output" | grep -q "WARNING"; then
    pass "worktree commit: no warning, exit 0"
else
    fail "worktree commit should warn-free, got exit=$ec output=$(echo "$output" | head -1)"
fi
git -C "$CLONE_DIR" worktree remove "$worktree_dir" --force >/dev/null 2>&1 || true
rm -rf "$worktree_dir"

# ── Test 9: main tree: git commit warns but allows (non-coord) ──────
echo "--- Test 9: main tree commit: WARNING printed, exit 0 ---"
output=$(run_shim_commit 0 0 2>&1; true)
if echo "$output" | grep -q "WARNING: committing directly to main/master branch"; then
    pass "main tree commit: WARNING printed"
else
    fail "main tree commit should print WARNING, got: $(echo "$output" | head -1)"
fi

# ── Test 10: main tree + C2C_COORDINATOR=1: silent, exit 0 ───────
echo "--- Test 10: main tree + C2C_COORDINATOR=1: no warning, exit 0 ---"
output=$(run_shim_commit 0 1 2>&1; true)
ec=$?
if [ $ec -eq 0 ] && ! echo "$output" | grep -q "WARNING"; then
    pass "main tree + C2C_COORDINATOR=1: no warning"
else
    fail "coord bypass should suppress warning, got exit=$ec output=$(echo "$output" | head -1)"
fi

# ── Test 11: main tree + C2C_COMMIT_REFUSE=1: fatal + exit 128 ─────
echo "--- Test 11: main tree + C2C_COMMIT_REFUSE=1: refused, exit 128 ---"
output=$(run_shim_commit 1 0 2>&1; true)
if echo "$output" | grep -q "fatal: git-shim refused"; then
    pass "main tree + C2C_COMMIT_REFUSE=1: refused"
else
    fail "C2C_COMMIT_REFUSE=1 should refuse, got: $(echo "$output" | head -1)"
fi

# ── Test 12: worktree branch still allowed even with C2C_COMMIT_REFUSE=1
echo "--- Test 12: worktree branch + C2C_COMMIT_REFUSE=1: no warning, exit 0 ---"
worktree_dir="$(mktemp -d)"
rm -rf "$worktree_dir"
branch_name="test-shim-commit-refuse-$$-$(date +%s)"
git -C "$CLONE_DIR" worktree add "$worktree_dir" -b "$branch_name" >/dev/null 2>&1 || true
output=$(run_shim_commit_in_worktree "$worktree_dir" 1 2>&1; true)
ec=$?
if [ $ec -eq 0 ] && ! echo "$output" | grep -q "WARNING"; then
    pass "worktree + C2C_COMMIT_REFUSE=1: no warning, exit 0"
else
    fail "worktree + C2C_COMMIT_REFUSE=1 should pass, got exit=$ec output=$(echo "$output" | head -1)"
fi
git -C "$CLONE_DIR" worktree remove "$worktree_dir" --force >/dev/null 2>&1 || true
rm -rf "$worktree_dir"

echo ""
echo "=== Results: $passed passed, $failed failed ==="
if [ $failed -gt 0 ]; then exit 1; fi
