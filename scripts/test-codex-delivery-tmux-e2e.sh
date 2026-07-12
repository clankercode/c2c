#!/usr/bin/env bash
# OBSOLETE (2026-07-10, codex-xmlfd-removal): this test exercised the managed
# XML sideband path (codex --xml-input-fd + c2c-deliver-inbox --xml-output-fd).
# Upstream codex removed the flag and the xml_fd plumbing was removed from
# c2c; codex delivery is via config.toml hooks (`c2c hook codex`) with the
# managed app-server transport as the default.
#
# REPLACED BY (B144, 2026-07-12) — two gated live transport harnesses that
# drive a REAL codex round-trip (each is preflight/run, run from inside tmux):
#   * hook+CLI transport:      scripts/codex-hooks-live-e2e.py
#       C2C_CODEX_HOOKS_LIVE=1 scripts/codex-hooks-live-e2e.py run
#   * managed app-server:      scripts/codex-managed-appserver-live-e2e.py
#       C2C_CODEX_APPSERVER_LIVE=1 scripts/codex-managed-appserver-live-e2e.py run
# In-suite skip proof + gate wiring: ocaml/test/test_c2c_codex_live_e2e.ml.
echo "OBSOLETE: the codex --xml-input-fd delivery path was removed." >&2
echo "Use the B144 live harnesses instead:" >&2
echo "  scripts/codex-hooks-live-e2e.py            (hook+CLI transport)" >&2
echo "  scripts/codex-managed-appserver-live-e2e.py (managed app-server)" >&2
exit 2

# B013 e2e: codex inbound c2c delivery in a LIVE tmux session, driven via
# scripts/c2c_tmux.py. Proves a peer -> codex send actually lands in the codex
# session's transcript pane through the managed XML sideband path (the
# c2c-deliver-inbox daemon + codex --xml-input-fd).
#
# Two modes:
#
#   preflight   (default) — check every prerequisite WITHOUT launching codex.
#               Background-agent / CI safe. Verifies tmux, the c2c + deliver
#               binaries, a codex binary that advertises --xml-input-fd,
#               c2c_tmux.py, and inotifywait.
#
#   run         — full live test. MUST run from inside a tmux session. Launches
#               codex via `c2c_tmux.py launch codex`, waits for it to register,
#               sends a peer -> codex DM carrying a unique marker, then polls the
#               codex pane (c2c_tmux.py capture) until the marker appears,
#               proving the XML frame was injected into the codex transcript.
#               Tears the session down via `c2c_tmux.py stop`.
#
# DELICATE: `run` mode starts a real codex model session (consumes API quota)
# and is sensitive to TTY/pgroup state. Per CLAUDE.md, never `c2c start codex`
# directly from a bare shell — this is why launch goes through c2c_tmux.py and
# `run` refuses unless $TMUX is set. A background agent should run `preflight`
# and hand the live `run` to the coordinator.
#
# Usage:
#   scripts/test-codex-delivery-tmux-e2e.sh            # preflight (default)
#   scripts/test-codex-delivery-tmux-e2e.sh preflight
#   scripts/test-codex-delivery-tmux-e2e.sh run        # live (coordinator, in tmux)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODE="${1:-preflight}"

C2C_TMUX="$REPO_ROOT/scripts/c2c_tmux.py"

ok()   { echo "  ok   $*"; }
warn() { echo "  WARN $*"; }
bad()  { echo "  FAIL $*"; }

resolve_bin() {  # $1 override, $2 _build path, $3 PATH name
  if [ -n "${1:-}" ]; then printf '%s\n' "$1"; return 0; fi
  if [ -x "$2" ]; then printf '%s\n' "$2"; return 0; fi
  command -v "$3" 2>/dev/null || return 1
}

C2C_BIN="$(resolve_bin "${C2C_BIN:-}" "$REPO_ROOT/_build/default/ocaml/cli/c2c.exe" "c2c")" || C2C_BIN=""
C2C_DELIVER_BIN="$(resolve_bin "${C2C_DELIVER_BIN:-}" \
  "$REPO_ROOT/_build/default/ocaml/cli/c2c_deliver_inbox.exe" "c2c-deliver-inbox")" || C2C_DELIVER_BIN=""

# Find a codex binary that advertises --xml-input-fd (the xml_fd deliver mode).
# Prefer .c2c/config.toml [default_binary] codex, then $HOME/.local/bin/codex,
# then PATH codex.
find_codex_xml() {
  local cand
  for cand in \
      "$(awk -F'"' '/^\[default_binary\]/{f=1} f&&/codex/{print $2; exit}' \
            "$REPO_ROOT/.c2c/config.toml" 2>/dev/null)" \
      "$HOME/.local/bin/codex" \
      "$(command -v codex 2>/dev/null || true)"; do
    [ -n "$cand" ] && [ -x "$cand" ] || continue
    if "$cand" --help 2>&1 | grep -q -- '--xml-input-fd'; then
      printf '%s\n' "$cand"; return 0
    fi
  done
  return 1
}

preflight() {
  local fails=0
  echo "B013 codex-delivery tmux e2e — PREFLIGHT"

  command -v tmux >/dev/null 2>&1 && ok "tmux present ($(tmux -V))" \
    || { bad "tmux missing"; fails=$((fails+1)); }

  [ -n "$C2C_BIN" ] && ok "c2c binary: $C2C_BIN" \
    || { bad "c2c binary not found (just build / set C2C_BIN)"; fails=$((fails+1)); }

  [ -n "$C2C_DELIVER_BIN" ] && ok "c2c-deliver-inbox: $C2C_DELIVER_BIN" \
    || { bad "c2c-deliver-inbox not found (just build)"; fails=$((fails+1)); }

  if [ -f "$C2C_TMUX" ] && python3 "$C2C_TMUX" --help >/dev/null 2>&1; then
    ok "c2c_tmux.py usable"
  else
    bad "scripts/c2c_tmux.py missing or not runnable"; fails=$((fails+1))
  fi

  if cx="$(find_codex_xml)"; then
    ok "codex with --xml-input-fd: $cx"
  else
    bad "no codex binary advertises --xml-input-fd — xml_fd deliver mode unavailable (see CLAUDE.md: two codex binaries)"
    fails=$((fails+1))
  fi

  command -v inotifywait >/dev/null 2>&1 \
    && ok "inotifywait present (managed daemon will auto-add --inotify; B013 dispatch fix exercised)" \
    || warn "inotifywait missing — managed daemon won't auto-add --inotify (bug would not reproduce, but delivery still works via xml poll)"

  [ -n "${TMUX:-}" ] && ok "inside tmux ('run' mode available here)" \
    || warn "not inside tmux — 'run' mode must be invoked from a tmux session"

  echo
  if [ "$fails" -eq 0 ]; then
    echo "PREFLIGHT PASS — prerequisites satisfied; 'run' mode can be executed (in tmux)."
    return 0
  fi
  echo "PREFLIGHT FAIL — $fails prerequisite(s) missing."
  return 1
}

run_live() {
  [ -n "${TMUX:-}" ] || { echo "FATAL: 'run' mode must be invoked from inside a tmux session (per CLAUDE.md; do not c2c start codex from a bare shell)." >&2; exit 2; }
  preflight >/dev/null || { echo "FATAL: preflight failed; fix prerequisites first." >&2; exit 2; }

  local NAME MARKER SENDER
  NAME="b013cdx$$"
  SENDER="b013peer$$"
  MARKER="B013-TMUX-MARKER-$$-$RANDOM"

  echo "Launching codex session '$NAME' via c2c_tmux.py ..."
  python3 "$C2C_TMUX" launch codex -n "$NAME" --auto

  cleanup_live() { python3 "$C2C_TMUX" stop "$NAME" >/dev/null 2>&1 || true; }
  trap cleanup_live EXIT

  echo "Waiting for '$NAME' to register (alive) ..."
  python3 "$C2C_TMUX" wait-alive "$NAME" --timeout 120 \
    || { echo "FAIL: codex '$NAME' never went alive" >&2; exit 1; }

  # Register a peer sender and DM the codex session a marker. We phrase it as a
  # plain message; we only need the XML frame to be INJECTED into the codex
  # transcript pane (delivery), not for codex to act on it.
  "$C2C_BIN" register --alias "$SENDER" --session-id "${SENDER}sid" >/dev/null 2>&1 || true
  echo "Sending peer -> codex DM (marker=$MARKER) ..."
  C2C_MCP_SESSION_ID="${SENDER}sid" "$C2C_BIN" send -F "$SENDER" "$NAME" \
    "$MARKER (B013 delivery probe — no action needed)" >/dev/null 2>&1 \
    || { echo "FAIL: peer->codex send failed" >&2; exit 1; }

  echo "Polling codex pane for the injected marker ..."
  local deadline found=0
  deadline=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if python3 "$C2C_TMUX" capture "$NAME" -n 400 2>/dev/null | grep -q "$MARKER"; then
      found=1; break
    fi
    sleep 2
  done

  if [ "$found" -eq 1 ]; then
    echo "PASS: marker '$MARKER' appeared in the codex pane — XML sideband delivery landed."
    exit 0
  fi
  echo "FAIL: marker '$MARKER' did NOT appear in the codex pane within 60s." >&2
  echo "      Capture tail for diagnosis:" >&2
  python3 "$C2C_TMUX" capture "$NAME" -n 60 >&2 || true
  exit 1
}

case "$MODE" in
  preflight) preflight ;;
  run)       run_live ;;
  *) echo "usage: $0 [preflight|run]" >&2; exit 2 ;;
esac
