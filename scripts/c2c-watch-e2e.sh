#!/usr/bin/env bash
# c2c-watch-e2e.sh — TUI smoke end-to-end for `c2c watch`.
#
# Drives the REAL `c2c watch` binary inside a tmux pane (via tui-snapshot.sh)
# against the LIVE broker and asserts that each tab renders, the compose line
# works, the CLI flags exist, the not-a-tty path refuses cleanly, and quitting
# restores the terminal. It codifies the manual "tested in the wild" QA so it
# is repeatable.
#
# SAFE: it NEVER submits a send (no real peer is messaged) — it only opens the
# compose line and types into the local buffer, then quits. The actual send
# DELIVERY round-trip (a message reaching the recipient's inbox / room history)
# is covered by the headless OCaml suite ocaml/cli/test_c2c_watch_e2e.ml.
#
# Assertions key off STRUCTURAL markers that are present regardless of how many
# peers/shards/rooms the live broker currently holds (e.g. "PEERS (" shows even
# at count 0), so the smoke test is not flaky against a quiet broker. The
# compose check tolerates an empty roster (it accepts either the compose prompt
# or the "nothing selected" status).
#
# Usage:   scripts/c2c-watch-e2e.sh
# Env:     C2C_WATCH_EXE  override the c2c binary path (default: the worktree build)
# Exit:    0 all pass, 1 a check failed, 2 setup error (missing exe/snapshot).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
EXE="${C2C_WATCH_EXE:-$REPO/_build/default/ocaml/cli/c2c.exe}"
SNAP="$HERE/tui-snapshot.sh"

fail=0
pass() { echo "  PASS: $1"; }
die()  { echo "  FAIL: $1" >&2; fail=1; }
have() { printf '%s' "$1" | grep -qF -- "$2"; }
want() { if have "$1" "$2"; then pass "$3"; else die "$3 — missing marker: $2"; fi; }
nope() { if have "$1" "$2"; then die "$3 — unexpected marker: $2"; else pass "$3"; fi; }

[ -x "$EXE" ]  || { echo "FAIL: c2c binary not found/executable: $EXE (build it first: just build-cli)"; exit 2; }
[ -x "$SNAP" ] || { echo "FAIL: tui-snapshot.sh not found: $SNAP"; exit 2; }

echo "c2c watch TUI e2e — binary: $EXE"

# 1. CLI surface: the operator-facing flags are advertised.
echo "[1] CLI flags"
H="$("$EXE" watch --help=plain 2>&1 || true)"
want "$H" "--as" "watch --help advertises --as"
want "$H" "--interval" "watch --help advertises --interval"

# 2. Not-a-tty refusal: piped stdin (no terminal) must refuse, not crash.
echo "[2] not-a-tty refusal"
NT="$(printf '' | "$EXE" watch 2>&1 || true)"
want "$NT" "not a tty" "refuses cleanly when not a tty"

# 3. Peers tab (default).
echo "[3] Peers tab"
P="$("$SNAP" 80 24 --keys "" -- "$EXE" watch 2>&1 || true)"
want "$P" "c2c watch"  "Peers: title bar present"
want "$P" "[P]eers"    "Peers: tab bar present"
want "$P" "PEERS ("    "Peers: roster heading present"
want "$P" "alive"      "Peers: liveness legend present"

# 4. DMs tab (key 2).
echo "[4] DMs tab"
D="$("$SNAP" 80 24 --keys "2" -- "$EXE" watch 2>&1 || true)"
want "$D" "DMs"        "DMs: heading present"
want "$D" "shards ("   "DMs: shard-list pane present"

# 5. Rooms tab (key 3).
echo "[5] Rooms tab"
R="$("$SNAP" 80 24 --keys "3" -- "$EXE" watch 2>&1 || true)"
want "$R" "ROOMS ("    "Rooms: heading present"
want "$R" "rooms ("    "Rooms: room-list pane present"

# 6. Compose UI: Enter (begin compose) + type into the buffer. NO submit.
#    Leading \n = an Enter keypress; the rest is typed literally.
echo "[6] compose UI (no submit)"
C="$("$SNAP" 80 24 --keys $'\ne2e-probe-msg' -- "$EXE" watch 2>&1 || true)"
if have "$C" "e2e-probe-msg"; then
  pass "Compose: typed text echoed into the compose line"
  want "$C" "$(printf '\342\200\272')" "Compose: prompt arrow (U+203A) present"
elif have "$C" "nothing selected"; then
  pass "Compose: empty roster -> 'nothing selected' (Enter handled, no crash)"
else
  die "Compose: neither typed text nor 'nothing selected' surfaced"
fi

# 7. Clean teardown on q: the sentinel is reached and no TUI frame lingers.
echo "[7] teardown"
Q="$("$SNAP" 80 24 --keys "q" -- "$EXE" watch 2>&1 || true)"
nope "$Q" "c2c watch ──── broker" "Teardown: no lingering frame after q"

echo
if [ "$fail" -eq 0 ]; then
  echo "=== c2c watch TUI e2e: ALL PASS ==="
  exit 0
else
  echo "=== c2c watch TUI e2e: FAILURES (see above) ==="
  exit 1
fi
