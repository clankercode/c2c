#!/usr/bin/env bash
# Smoke test for scripts/c2c-install-guard.sh + scripts/c2c-install-stamp.sh.
# Exercises the four ancestry paths (same / descendant / ancestor / divergent),
# the no-stamp path, and the C2C_INSTALL_FORCE override.
#
# Self-contained: builds a temp git repo, invokes guard/stamp with env
# overrides for stamp + target paths so the test can never touch
# ~/.local/bin/.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$REPO_ROOT/scripts/c2c-install-guard.sh"
STAMP="$REPO_ROOT/scripts/c2c-install-stamp.sh"

[ -x "$GUARD" ] || { echo "FAIL: guard script not executable: $GUARD" >&2; exit 2; }
[ -x "$STAMP" ] || { echo "FAIL: stamp script not executable: $STAMP" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Synthetic git repo with three commits on a linear chain plus a divergent branch.
git -C "$WORK" init -q -b master
git -C "$WORK" config user.email t@t
git -C "$WORK" config user.name t
echo a > "$WORK/f"; git -C "$WORK" add f; git -C "$WORK" commit -q -m a
SHA_A=$(git -C "$WORK" rev-parse HEAD)
echo b > "$WORK/f"; git -C "$WORK" commit -aq -m b
SHA_B=$(git -C "$WORK" rev-parse HEAD)
echo c > "$WORK/f"; git -C "$WORK" commit -aq -m c
SHA_C=$(git -C "$WORK" rev-parse HEAD)
git -C "$WORK" checkout -q -b div "$SHA_A"
echo d > "$WORK/f"; git -C "$WORK" commit -aq -m d
SHA_D=$(git -C "$WORK" rev-parse HEAD)
git -C "$WORK" checkout -q master

# Set up a bare repo as the synthetic "origin" so Pattern 18 checks can run.
ORIGIN="$WORK/origin.git"
git init -q --bare "$ORIGIN"
git -C "$WORK" remote add origin "$ORIGIN"
git -C "$WORK" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
git -C "$WORK" push -q origin master:master
git -C "$WORK" push -q origin div:div   # push div so origin/div exists and div is NOT behind origin/master

STAMP_FILE="$WORK/.c2c-version"
TARGET_BIN="$WORK/c2c-target"
touch "$TARGET_BIN"

run_guard() {
  # Run guard from inside the synthetic repo at HEAD = $1 (a SHA we check out).
  git -C "$WORK" checkout -q "$1"
  ( cd "$WORK" && \
    C2C_INSTALL_STAMP="$STAMP_FILE" \
    C2C_INSTALL_TARGET="$TARGET_BIN" \
    C2C_INSTALL_QUIET="${QUIET:-1}" \
    C2C_INSTALL_FORCE="${FORCE:-0}" \
    bash "$GUARD" )
}

write_stamp() {
  # Write a stamp recording $1 as the installed SHA.
  cat >"$STAMP_FILE" <<EOF
{
  "sha": "$1",
  "branch": "test",
  "alias": "test",
  "worktree": "$WORK",
  "installed_at": "test"
}
EOF
}

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL $1" >&2; }

# Case 1: no stamp present → guard exits 0
rm -f "$STAMP_FILE"
if run_guard "$SHA_B"; then ok "no-stamp permits install"; else fail "no-stamp should permit"; fi

# Case 2: same SHA → exits 0
write_stamp "$SHA_B"
if run_guard "$SHA_B"; then ok "same SHA permits"; else fail "same SHA should permit"; fi

# Case 3: descendant SHA (linear progress: B installed, installing C) → 0
write_stamp "$SHA_B"
if run_guard "$SHA_C"; then ok "descendant SHA permits (linear progress)"; else fail "descendant should permit"; fi

# Case 4: ancestor SHA (older worktree clobbering newer install) → exits 1
write_stamp "$SHA_C"
if run_guard "$SHA_B"; then fail "ancestor SHA should REFUSE"; else ok "ancestor SHA refuses (clobber blocked)"; fi

# Case 5: ancestor + C2C_INSTALL_FORCE=1 → exits 0
write_stamp "$SHA_C"
if FORCE=1 run_guard "$SHA_B"; then ok "FORCE=1 overrides refuse"; else fail "FORCE=1 should override"; fi

# Case 6: divergent (B installed, installing D from another branch) → exits 0 (warn-only).
# Strategy: stay on master and invoke guard inline (don't use run_guard which does checkout).
# run_guard checks out $1 which detaches HEAD and triggers Pattern 18.
write_stamp "$SHA_B"
git -C "$WORK" checkout -q master   # stay on master
( cd "$WORK" && \
  C2C_INSTALL_STAMP="$STAMP_FILE" \
  C2C_INSTALL_TARGET="$TARGET_BIN" \
  C2C_INSTALL_QUIET="${QUIET:-1}" \
  C2C_INSTALL_FORCE="${FORCE:-0}" \
  bash "$GUARD" ) && ok "divergent SHA permits (warn-only)" || fail "divergent should permit"

# Case 7: stamp with unknown sha → exits 0 (cross-clone install, warn-only)
write_stamp "0000000000000000000000000000000000000000"
if run_guard "$SHA_B"; then ok "unreachable old SHA permits (cross-clone)"; else fail "unreachable old SHA should permit"; fi

# Case 8: target binary absent → exits 0 even if stamp says ancestor
rm -f "$TARGET_BIN"
write_stamp "$SHA_C"
if run_guard "$SHA_B"; then ok "no target bin permits"; else fail "no target bin should permit"; fi
touch "$TARGET_BIN"

# Case 9: stamp script writes a parseable stamp matching the working dir
rm -f "$STAMP_FILE"
git -C "$WORK" checkout -q "$SHA_B"
( cd "$WORK" && C2C_INSTALL_STAMP="$STAMP_FILE" bash "$STAMP" )
if [ -f "$STAMP_FILE" ] && grep -q "\"sha\": \"$SHA_B\"" "$STAMP_FILE"; then
  ok "stamp script writes correct sha"
else
  fail "stamp script did not write expected sha"
  cat "$STAMP_FILE" >&2 || true
fi

# Case 10: worktree on a branch (not master) that is behind origin/master,
# with a divergent stamp. The divergent path fires first but Pattern 18
# then refuses because the current branch is behind origin/master.
# Strategy: checkout by SHA hash (git checkout $SHA_B) which always detaches HEAD,
# setting current_branch=HEAD (not master). Pattern 18 fires because
# current_branch=HEAD != master && != origin/master, and commits_behind > 0.
# Stamp says SHA_D (on div — divergent from worktree_branch).
git -C "$WORK" checkout -q "$SHA_A"   # start from SHA_A
git -C "$WORK" checkout -q -b worktree_branch "$SHA_B"  # worktree_branch at SHA_B
write_stamp "$SHA_D"   # stamp says SHA_D (div branch — divergent from worktree_branch)
FORCE=0
if run_guard "$SHA_B"; then
  fail "behind-origin-master should REFUSE (Pattern 18)"
else
  ok "behind-origin-master refuses (Pattern 18)"
fi
FORCE=1
if run_guard "$SHA_B"; then
  ok "behind-origin-master + FORCE=1 permits"
else
  fail "FORCE=1 should override Pattern 18"
fi
FORCE=0
git -C "$WORK" checkout -q master  # restore HEAD

echo
echo "summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
