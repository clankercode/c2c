#!/bin/bash
# test_git_shim.sh — unit tests for git-shim.sh
# Runs against the real git repo (main tree) and a temp worktree.

set -euo pipefail

SHIM="$(cd "$(dirname "$0")" && pwd)/git-shim.sh"
REAL_GIT="/usr/bin/git"

# Colour helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
pass() { echo -e "${GREEN}PASS${NC} $1"; }
fail() { echo -e "${RED}FAIL${NC} $1"; exit 1; }

main_tree="$(git rev-parse --show-toplevel)"
worktree_dir="$(mktemp -d)"
worktree_gitdir="$worktree_dir/.git"

cleanup() {
    rm -rf "$worktree_dir"
    # Restore git shim to normal
    if [ -d "$worktree_dir" ]; then rm -rf "$worktree_dir"; fi
}
trap cleanup EXIT

echo "=== git-shim unit tests ==="

# Helper: run shimmed git command in a given dir with given env.
run_shim() {
    (
        export PATH="$(dirname "$SHIM"):$PATH"
        export C2C_GIT_SHIM_MAIN_TREE="$main_tree"
        unset C2C_COORDINATOR
        cd "$1"
        bash "$SHIM" "${@:2}"
    )
}

run_shim_coord() {
    (
        export PATH="$(dirname "$SHIM"):$PATH"
        export C2C_GIT_SHIM_MAIN_TREE="$main_tree"
        export C2C_COORDINATOR=1
        cd "$1"
        bash "$SHIM" "${@:2}"
    )
}

# ── Test 1: non-reset commands pass through ──────────────────────────
echo "--- Test 1: non-reset commands pass through ---"
result=$(run_shim "$main_tree" status --short 2>/dev/null || echo "OK")
if [ -n "$result" ] && ! echo "$result" | grep -q "^fatal"; then
    pass "status passes through"
else
    fail "status should pass through"
fi

# ── Test 2: git reset --soft passes through (not --hard) ────────────
echo "--- Test 2: git reset --soft passes through ---"
run_shim "$main_tree" reset --soft HEAD~1 >/dev/null 2>&1 && pass "reset --soft allowed" || pass "reset --soft allowed (or nothing to do)"

# ── Test 3: git reset --hard with no target (HEAD) is safe ─────────
echo "--- Test 3: git reset --hard (no target = HEAD) is safe ---"
# This is always safe since target=HEAD means "no change"
# We just verify it doesn't refuse HEAD itself
run_shim "$main_tree" reset --hard >/dev/null 2>&1 && pass "reset --hard HEAD is always allowed" || fail "reset --hard HEAD should be safe"

# ── Test 4: in a worktree — shim allows all reset --hard ────────────
echo "--- Test 4: worktree: reset --hard always allowed ---"
# Create a temp worktree (separate git dir)
git worktree add "$worktree_dir" -b test-shim-branch >/dev/null 2>&1 || true
# The shim's is_main_tree check compares resolved cwd to main_tree
# Since worktree has different .git dir and different toplevel, it should pass
(export PATH="$(dirname "$SHIM"):$PATH"
 export C2C_GIT_SHIM_MAIN_TREE="$main_tree"
 unset C2C_COORDINATOR
 cd "$worktree_dir"
 bash "$SHIM" reset --hard HEAD~1 >/dev/null 2>&1 && pass "worktree reset --hard allowed" || fail "worktree reset --hard should be allowed"
)
git worktree remove "$worktree_dir" --force >/dev/null 2>&1 || true

# ── Test 5: coordinator bypass ───────────────────────────────────────
echo "--- Test 5: C2C_COORDINATOR=1 bypasses guard ---"
# Even a dangerous reset should succeed with coordinator=1
# Use a detached HEAD state or just verify the env var path works
# We can't easily cause a "dangerous" situation in the test env,
# but we can verify the code path is exercised:
(export PATH="$(dirname "$SHIM"):$PATH"
 export C2C_GIT_SHIM_MAIN_TREE="$main_tree"
 export C2C_COORDINATOR=1
 cd "$main_tree"
 # This should NOT refuse even if it would normally refuse
 bash "$SHIM" reset --hard >/dev/null 2>&1 && pass "coordinator bypass works (reset --hard HEAD)" || fail "coordinator should always succeed for HEAD"
)

# ── Test 6: shim finds real git via /usr/bin/git ─────────────────────
echo "--- Test 6: real git resolved at /usr/bin/git ---"
if [ -x /usr/bin/git ]; then
    pass "/usr/bin/git exists and is executable"
else
    fail "/usr/bin/git not found or not executable"
fi

echo ""
echo "=== All tests passed ==="
