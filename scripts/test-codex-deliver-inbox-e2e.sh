#!/usr/bin/env bash
# B013 e2e: codex XML sideband delivery through the REAL c2c-deliver-inbox
# binary, launched exactly the way `c2c start codex` launches it for a managed
# session: --client codex --xml-output-fd N --inotify --loop.
#
# Regression guard for the dispatch-shadowing bug (B013 item 2): when
# inotifywait is on PATH, start_deliver_daemon auto-adds --inotify, so the
# codex deliver daemon receives BOTH --xml-output-fd AND --inotify. The old
# run_loop dispatch checked use_inotify first and routed codex to the log-only
# inotify path (which printed a preview to a /dev/null stdout and NEVER wrote
# XML to the fd) — so codex silently went dark. The fix makes xml_output_fd
# take precedence over --inotify.
#
# This test needs NO codex process: it seeds a peer->codex message into an
# isolated broker, runs the daemon for a few bounded iterations with the output
# fd redirected to a file, and asserts the XML <message><c2c ...> frame with the
# message body actually lands on that fd. Pre-fix, the fd would be empty.
#
# Background-agent-safe: no tmux, no live model session, fully self-contained.
#
# Usage:  scripts/test-codex-deliver-inbox-e2e.sh
# Env overrides:
#   C2C_BIN          path to the c2c binary          (default: worktree _build, then PATH)
#   C2C_DELIVER_BIN  path to c2c-deliver-inbox binary (default: worktree _build, then PATH)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- resolve binaries: prefer freshly-built worktree _build, then PATH ----
resolve_bin() {
  # $1 = explicit override (may be empty); $2 = _build path; $3 = PATH name
  if [ -n "${1:-}" ]; then printf '%s\n' "$1"; return 0; fi
  if [ -x "$2" ]; then printf '%s\n' "$2"; return 0; fi
  if command -v "$3" >/dev/null 2>&1; then command -v "$3"; return 0; fi
  return 1
}

C2C_BIN="$(resolve_bin "${C2C_BIN:-}" \
  "$REPO_ROOT/_build/default/ocaml/cli/c2c.exe" "c2c")" || {
    echo "FATAL: cannot find c2c binary (build with 'just build' or set C2C_BIN)" >&2; exit 2; }
C2C_DELIVER_BIN="$(resolve_bin "${C2C_DELIVER_BIN:-}" \
  "$REPO_ROOT/_build/default/ocaml/cli/c2c_deliver_inbox.exe" "c2c-deliver-inbox")" || {
    echo "FATAL: cannot find c2c-deliver-inbox binary (build with 'just build' or set C2C_DELIVER_BIN)" >&2; exit 2; }

if ! command -v inotifywait >/dev/null 2>&1; then
  echo "WARN: inotifywait not on PATH — this test specifically exercises the" >&2
  echo "      --inotify + --xml-output-fd combination; without inotifywait the" >&2
  echo "      managed daemon would not auto-add --inotify and the bug would not" >&2
  echo "      reproduce. We still pass --inotify explicitly, so the dispatch is" >&2
  echo "      exercised regardless." >&2
fi

echo "c2c binary:            $C2C_BIN"
echo "c2c-deliver-inbox bin: $C2C_DELIVER_BIN"

# ---- isolated broker + temp state ----
WORK="$(mktemp -d /tmp/b013-deliver-e2e.XXXXXX)"
BROKER="$WORK/broker"
OUT="$WORK/xml-out.txt"
DELIV_ERR="$WORK/deliver.stderr"
mkdir -p "$BROKER"
export C2C_MCP_BROKER_ROOT="$BROKER"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Non-word aliases to avoid collisions with the live alias pool (CLAUDE.md).
SID="b013sid$$"
RECV="b013rx$$"
SEND="b013tx$$"
MARKER="B013-DELIVER-MARKER-$$-$RANDOM"

fail() { echo "FAIL: $*" >&2; exit 1; }

# ---- seed a peer -> codex message into the isolated broker ----
"$C2C_BIN" register --alias "$RECV" --session-id "$SID"     >/dev/null 2>&1 \
  || fail "register recipient ($RECV) failed"
"$C2C_BIN" register --alias "$SEND" --session-id "${SID}tx" >/dev/null 2>&1 \
  || fail "register sender ($SEND) failed"
C2C_MCP_SESSION_ID="${SID}tx" "$C2C_BIN" send -F "$SEND" "$RECV" "$MARKER" >/dev/null 2>&1 \
  || fail "send peer->codex message failed"

[ -s "$BROKER/$SID.inbox.json" ] || fail "message did not land in recipient inbox"

# ---- run the daemon exactly like managed codex: xml fd + inotify + loop ----
# fd 9 -> $OUT ; daemon writes XML frames to --xml-output-fd 9.
# Bounded by --max-iterations so it self-terminates; timeout is a safety net.
timeout 20 "$C2C_DELIVER_BIN" \
  --client codex --session-id "$SID" --broker-root "$BROKER" \
  --xml-output-fd 9 --inotify --loop --interval 0.1 --max-iterations 5 \
  9>"$OUT" 2>"$DELIV_ERR" || true

# ---- assertions: the XML frame, the envelope, and the body must be on fd 9 ----
[ -s "$OUT" ] || { echo "--- deliver stderr ---"; cat "$DELIV_ERR" >&2; \
  fail "fd 9 is EMPTY — XML delivery was shadowed (codex would go dark)"; }
grep -q '<message'  "$OUT" || fail "no <message ...> frame on fd 9"
grep -q '<c2c'      "$OUT" || fail "no <c2c ...> envelope on fd 9"
grep -q "$MARKER"   "$OUT" || fail "message body ($MARKER) not delivered on fd 9"

echo "PASS: codex XML sideband frame delivered on fd 9 with --inotify + --xml-output-fd"
echo "      ($(grep -c '<message' "$OUT") frame(s); body present)"
exit 0
