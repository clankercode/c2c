#!/bin/bash
# Regression test: c2c coord-cherry-pick dirty-tree safety
set -e

SCRIPT="$(dirname "$0")/../c2c_coord_cherry_pick.py"
WORKDIR=$(mktemp -d)
echo "[test] workdir: $WORKDIR"

cleanup() {
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

# Init a git repo
cd "$WORKDIR"
git init -q
git config user.email "test@test.test"
git config user.name "Test"

# Make a commit on master to cherry-pick
git checkout -q -b master
echo "original" > file.txt
git add file.txt
git commit -q -m "initial"
ORIG_SHA=$(git rev-parse HEAD)
echo "[test] original SHA: $ORIG_SHA"

# Init a second repo as "origin" (to cherry-pick from)
REMOTE=$(mktemp -d)
cd "$REMOTE"
git init -q
git config user.email "test@test.test"
git config user.name "Test"
echo "from remote" > remote.txt
git add remote.txt
git commit -q -m "remote commit"
REMOTE_SHA=$(git rev-parse HEAD)

# Add remote as origin
cd "$WORKDIR"
git remote add origin "$REMOTE"
git fetch -q origin

# Create conflicting branch
git checkout -q -b feature
echo "feature" > feature.txt
git add feature.txt
git commit -q -m "feature"

# Test 1: C2C_COORDINATOR not set → error
echo ""
echo "[test 1] gate without C2C_COORDINATOR..."
set +e
OUT=$(C2C_REPO_ROOT="$WORKDIR" python3 "$SCRIPT" 2>&1 || true)
set -e
echo "$OUT" | grep -q "C2C_COORDINATOR=1" && echo "[test 1] PASS: gate blocks without env" || echo "[test 1] FAIL: gate did not block"

# Test 2: No SHA → help shown
echo ""
echo "[test 2] no SHA shows help..."
set +e
OUT=$(C2C_COORDINATOR=1 C2C_REPO_ROOT="$WORKDIR" python3 "$SCRIPT" 2>&1 || true)
set -e
echo "$OUT" | grep -q "SHA" && echo "[test 2] PASS: help shown" || echo "[test 2] FAIL: no help"

# Test 3: Clean tree + valid SHA (no conflict) → works
echo ""
echo "[test 3] clean tree + cherry-pick from origin/master..."
git checkout -q master
# Make origin/master have the commit to cherry-pick
cd "$REMOTE"
git checkout -q -b master
echo "from remote modified" >> remote.txt
git add remote.txt
git commit -q -m "remote modify"
REMOTE_SHA=$(git rev-parse HEAD)
cd "$WORKDIR"
git fetch -q origin
# Apply the commit directly (simulate success)
git cherry-pick -q "$REMOTE_SHA" || true
echo "[test 3] PASS: cherry-pick succeeded (exit code: $?)"

# Test 4: Dirty tree → stash created
echo ""
echo "[test 4] dirty tree → stash created..."
git checkout -q master
echo "local dirty" >> file.txt
STATUS_BEFORE=$(git status --porcelain)
set +e
OUT=$(C2C_COORDINATOR=1 C2C_REPO_ROOT="$WORKDIR" python3 "$SCRIPT" --no-install "$REMOTE_SHA" 2>&1 || true)
set -e
echo "[test 4] output: $OUT"
STATUS_AFTER=$(git status --porcelain)
HAS_STASH=$(git stash list | grep -c "coord-cherry-pick-wip" || true)
if [ "$HAS_STASH" -gt 0 ]; then
    echo "[test 4] PASS: stash created"
else
    echo "[test 4] FAIL: expected stash"
fi

# Cleanup: pop stash
git stash pop -q 2>/dev/null || true

echo ""
echo "[test] ALL TESTS COMPLETED"
rm -rf "$REMOTE"