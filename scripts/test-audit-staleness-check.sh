#!/usr/bin/env bash
# test-audit-staleness-check.sh — smoke test for audit-staleness-check.sh
#
# Builds a throwaway git repo with five orphan commits in known states:
#   1. ancestor of BASE                        → ALREADY_LANDED
#   2. cherry-picked with `-x`                 → LANDED_VIA_CHERRY_PICK_TRAILER
#   3. cherry-picked plain (subject preserved) → LANDED_VIA_CHERRY_PICK
#   4. cherry-picked + subject rewritten       → LANDED_VIA_PATCH_ID
#   5. genuinely orphan                        → NOT_YET_LANDED
# then runs the staleness checker (in --json) and asserts each detection.
#
# Exits 0 on PASS, 1 on FAIL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$SCRIPT_DIR/audit-staleness-check.sh"

if [[ ! -x "$CHECKER" ]]; then
  echo "FAIL: $CHECKER not executable" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed (required for assertions)" >&2
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cd "$tmp"
git init -q -b main >/dev/null
git config user.email "test@example.com"
git config user.name "test"
git commit -q --allow-empty -m "root"

# (1) ancestor case: a real commit on main — so the SHA itself is in BASE history.
echo a > a.txt && git add a.txt && git commit -q -m "main-1: real ancestor"
sha_ancestor=$(git rev-parse HEAD)

# ── orphan branch with four cherry-pick-candidate commits ───────────────────
git checkout -q -b orphan
echo b > b.txt && git add b.txt && git commit -q -m "orphan-2: -x trailer case"
sha_trailer=$(git rev-parse HEAD)

echo c > c.txt && git add c.txt && git commit -q -m "orphan-3: subject-grep case"
sha_subject=$(git rev-parse HEAD)

echo d > d.txt && git add d.txt && git commit -q -m "orphan-4: patch-id case"
sha_patchid=$(git rev-parse HEAD)

echo e > e.txt && git add e.txt && git commit -q -m "orphan-5: genuinely orphan"
sha_orphan=$(git rev-parse HEAD)

# ── back on main: stage cherry-picks in different shapes ────────────────────
git checkout -q main

# (2) -x trailer: `git cherry-pick -x` appends "(cherry picked from commit <SHA>)"
git cherry-pick -x "$sha_trailer" >/dev/null
landed_trailer=$(git rev-parse HEAD)

# (3) subject-grep: plain cherry-pick (no -x), preserves subject only
git cherry-pick "$sha_subject" >/dev/null
landed_subject=$(git rev-parse HEAD)

# (4) patch-id: cherry-pick then amend with a different subject
git cherry-pick "$sha_patchid" >/dev/null
git commit -q --amend -m "totally-different-subject for patch-id detection"
landed_patchid=$(git rev-parse HEAD)

# Now: BASE = main, orphan SHAs sha_ancestor (literal ancestor of main),
# sha_trailer (cherry-picked w/ -x), sha_subject (cherry-picked plain),
# sha_patchid (cherry-picked + subject-rewritten), sha_orphan (never landed).
# Step (1) above made sha_ancestor an actual ancestor of main, so
# audit-staleness-check should report ALREADY_LANDED for it.

# ── audit doc with all five SHAs ─────────────────────────────────────────────
audit_doc="$tmp/audit.md"
cat > "$audit_doc" <<EOF
# Audit doc — staleness test fixture

References:
- $sha_ancestor  (should be ALREADY_LANDED)
- $sha_trailer   (should be LANDED_VIA_CHERRY_PICK_TRAILER)
- $sha_subject   (should be LANDED_VIA_CHERRY_PICK)
- $sha_patchid   (should be LANDED_VIA_PATCH_ID)
- $sha_orphan    (should be NOT_YET_LANDED)
EOF

# ── run checker, capture JSON ────────────────────────────────────────────────
# Allow non-zero exit (stale==true is expected); capture stdout regardless.
set +e
output=$(AUDIT_BASE=main "$CHECKER" --json "$audit_doc")
rc=$?
set -e

if [[ $rc -ne 1 ]]; then
  echo "FAIL: checker should exit 1 (stale refs detected); got rc=$rc" >&2
  echo "Output: $output" >&2
  exit 1
fi

# Helper: extract status for a given SHA
get_status() {
  local sha="$1"
  echo "$output" | jq -r --arg s "$sha" '.shas[] | select(.sha==$s) | .status'
}

assert_status() {
  local sha="$1"; local want="$2"; local label="$3"
  local got
  got=$(get_status "$sha")
  if [[ "$got" != "$want" ]]; then
    echo "FAIL [$label]: sha=$sha want=$want got=$got" >&2
    echo "Full output:" >&2
    echo "$output" | jq . >&2
    exit 1
  fi
  echo "  PASS [$label]: $sha → $got"
}

echo "=== test-audit-staleness-check.sh ==="
assert_status "$sha_ancestor" "ALREADY_LANDED"                  "ancestor"
assert_status "$sha_trailer"  "LANDED_VIA_CHERRY_PICK_TRAILER"  "-x trailer"
assert_status "$sha_subject"  "LANDED_VIA_CHERRY_PICK"          "subject-grep"
assert_status "$sha_patchid"  "LANDED_VIA_PATCH_ID"             "patch-id"
assert_status "$sha_orphan"   "NOT_YET_LANDED"                  "genuinely-orphan"

echo ""
echo "=== ALL PASS ==="
exit 0
