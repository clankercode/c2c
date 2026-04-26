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

STAMP_FILE="$WORK/.c2c-version"
# Drift tests need a binary dir with all 4 binaries — point it at WORK/bin.
BIN_DIR="$WORK/bin"
mkdir -p "$BIN_DIR"
TARGET_BIN="$BIN_DIR/c2c"
touch "$TARGET_BIN"

run_guard() {
  # Run guard from inside the synthetic repo at HEAD = $1 (a SHA we check out).
  git -C "$WORK" checkout -q "$1"
  ( cd "$WORK" && \
    C2C_INSTALL_STAMP="$STAMP_FILE" \
    C2C_INSTALL_TARGET="$TARGET_BIN" \
    C2C_INSTALL_BIN_DIR="$BIN_DIR" \
    C2C_INSTALL_QUIET="${QUIET:-1}" \
    C2C_INSTALL_FORCE="${FORCE:-0}" \
    bash "$GUARD" )
}

run_guard_capture() {
  # Like run_guard but captures stderr and exits in the subshell.
  git -C "$WORK" checkout -q "$1"
  ( cd "$WORK" && \
    C2C_INSTALL_STAMP="$STAMP_FILE" \
    C2C_INSTALL_TARGET="$TARGET_BIN" \
    C2C_INSTALL_BIN_DIR="$BIN_DIR" \
    C2C_INSTALL_QUIET="${QUIET:-0}" \
    C2C_INSTALL_FORCE="${FORCE:-0}" \
    bash "$GUARD" 2>&1 )
}

write_stamp() {
  # Write a stamp recording $1 as the installed SHA (legacy format, no
  # binaries section). Used by ancestry-only test cases.
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

write_stamp_with_binaries() {
  # Write a stamp recording $1 as the installed SHA + per-binary sha256s
  # captured from $BIN_DIR. Used by drift test cases.
  local recorded_sha="$1"
  local c2c_h mcp_h hook_h cb_h
  c2c_h=$(sha256sum "$BIN_DIR/c2c"                  2>/dev/null | awk '{print $1}'); c2c_h="${c2c_h:-}"
  mcp_h=$(sha256sum "$BIN_DIR/c2c-mcp-server"       2>/dev/null | awk '{print $1}'); mcp_h="${mcp_h:-}"
  hook_h=$(sha256sum "$BIN_DIR/c2c-inbox-hook-ocaml" 2>/dev/null | awk '{print $1}'); hook_h="${hook_h:-}"
  cb_h=$(sha256sum "$BIN_DIR/c2c-cold-boot-hook"    2>/dev/null | awk '{print $1}'); cb_h="${cb_h:-}"
  cat >"$STAMP_FILE" <<EOF
{
  "sha": "$recorded_sha",
  "branch": "test",
  "alias": "test",
  "worktree": "$WORK",
  "installed_at": "test",
  "binaries": {
    "c2c": { "path": "$BIN_DIR/c2c", "sha256": "$c2c_h" },
    "c2c-mcp-server": { "path": "$BIN_DIR/c2c-mcp-server", "sha256": "$mcp_h" },
    "c2c-inbox-hook-ocaml": { "path": "$BIN_DIR/c2c-inbox-hook-ocaml", "sha256": "$hook_h" },
    "c2c-cold-boot-hook": { "path": "$BIN_DIR/c2c-cold-boot-hook", "sha256": "$cb_h" }
  }
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

# Case 6: divergent (B installed, installing D from another branch) → exits 0 (warn-only)
write_stamp "$SHA_B"
if run_guard "$SHA_D"; then ok "divergent SHA permits (warn-only)"; else fail "divergent should permit"; fi

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

# --- #322 drift detection cases ---
# Populate $BIN_DIR with all 4 binaries (distinct content per file) so the
# stamp has something to record.
echo "c2c-bin-v1"          > "$BIN_DIR/c2c"
echo "mcp-bin-v1"          > "$BIN_DIR/c2c-mcp-server"
echo "hook-bin-v1"         > "$BIN_DIR/c2c-inbox-hook-ocaml"
echo "cb-bin-v1"           > "$BIN_DIR/c2c-cold-boot-hook"

# Case 10: matched stamp + binaries → no drift, normal ancestry path runs
write_stamp_with_binaries "$SHA_B"
out=$(QUIET=0 run_guard_capture "$SHA_B" || true)
if echo "$out" | grep -q "DRIFT"; then
  fail "matched binaries should not trigger DRIFT log"
else
  ok "matched stamp/binaries → no drift warn"
fi

# Case 11: drifted c2c binary → DRIFT log + exit 0 (recover, not refuse)
write_stamp_with_binaries "$SHA_B"
echo "c2c-bin-v2-tampered" > "$BIN_DIR/c2c"  # change content → sha changes
out=$(QUIET=0 run_guard_capture "$SHA_B" || true)
if echo "$out" | grep -q "DRIFT: c2c stamp says"; then
  ok "drift on c2c logged with both shas"
else
  fail "drift on c2c not logged"
  echo "  output: $out" >&2
fi
if echo "$out" | grep -q "WARN: install-stamp drift detected"; then
  ok "drift summary warn fired"
else
  fail "drift summary warn missing"
fi
# Restore for subsequent cases
echo "c2c-bin-v1" > "$BIN_DIR/c2c"

# Case 12: drift takes precedence over ancestry refuse — stamp claims newer
# SHA AND binary drifted; should NOT exit 1 (would have on ancestry alone).
write_stamp_with_binaries "$SHA_C"
echo "c2c-bin-tampered-2" > "$BIN_DIR/c2c"
if run_guard "$SHA_B"; then
  ok "drift skips ancestry refuse (recover-with-warning shape)"
else
  fail "drift should skip ancestry refuse and exit 0"
fi
echo "c2c-bin-v1" > "$BIN_DIR/c2c"

# Case 13: drift on a non-c2c binary (mcp-server) also fires
write_stamp_with_binaries "$SHA_B"
echo "mcp-bin-tampered" > "$BIN_DIR/c2c-mcp-server"
out=$(QUIET=0 run_guard_capture "$SHA_B" || true)
if echo "$out" | grep -q "DRIFT: c2c-mcp-server stamp says"; then
  ok "drift on c2c-mcp-server detected"
else
  fail "drift on c2c-mcp-server not detected"
  echo "  output: $out" >&2
fi
echo "mcp-bin-v1" > "$BIN_DIR/c2c-mcp-server"

# Case 14: stamp lacks binaries section (old format) → silent no-op,
# normal ancestry path proceeds. write_stamp() writes the legacy format.
write_stamp "$SHA_B"
out=$(QUIET=0 run_guard_capture "$SHA_B" || true)
if echo "$out" | grep -q "DRIFT"; then
  fail "old-format stamp should not trigger DRIFT (silent no-op)"
else
  ok "old-format stamp → no drift check (silent no-op)"
fi

# Case 15: a binary listed in the stamp is missing on disk → skip silently,
# don't claim drift (binary-missing is a different bug class).
write_stamp_with_binaries "$SHA_B"
rm -f "$BIN_DIR/c2c-cold-boot-hook"
out=$(QUIET=0 run_guard_capture "$SHA_B" || true)
if echo "$out" | grep -q "DRIFT: c2c-cold-boot-hook"; then
  fail "missing binary should NOT trigger drift (different bug class)"
else
  ok "missing binary → silent (not reported as drift)"
fi
echo "cb-bin-v1" > "$BIN_DIR/c2c-cold-boot-hook"

# Case 16: drift + C2C_INSTALL_FORCE=1 — drift check should still run
# (FORCE only bypasses ancestry refuse, not drift).
write_stamp_with_binaries "$SHA_B"
echo "c2c-tampered-force" > "$BIN_DIR/c2c"
out=$(QUIET=0 FORCE=1 run_guard_capture "$SHA_B" || true)
if echo "$out" | grep -q "DRIFT: c2c stamp says"; then
  ok "FORCE=1 does not skip drift check"
else
  fail "FORCE=1 should still report drift"
  echo "  output: $out" >&2
fi
echo "c2c-bin-v1" > "$BIN_DIR/c2c"

# Case 17: stamp script honors C2C_INSTALL_DRIFT_DETECTED=1 → records
# previous_drift_detected:true in the new stamp.
rm -f "$STAMP_FILE"
git -C "$WORK" checkout -q "$SHA_B"
( cd "$WORK" && C2C_INSTALL_STAMP="$STAMP_FILE" \
    C2C_INSTALL_DRIFT_DETECTED=1 bash "$STAMP" )
if grep -q '"previous_drift_detected": true' "$STAMP_FILE"; then
  ok "stamp records previous_drift_detected:true on env"
else
  fail "stamp did not record previous_drift_detected"
  cat "$STAMP_FILE" >&2 || true
fi

# Case 18: stamp script omits the field when the env var is unset.
rm -f "$STAMP_FILE"
git -C "$WORK" checkout -q "$SHA_B"
( cd "$WORK" && C2C_INSTALL_STAMP="$STAMP_FILE" bash "$STAMP" )
if grep -q '"previous_drift_detected"' "$STAMP_FILE"; then
  fail "stamp wrote previous_drift_detected without env var"
else
  ok "stamp omits previous_drift_detected when env unset"
fi

echo
echo "summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
