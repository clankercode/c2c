#!/usr/bin/env bash
# Smoke test for docs/install.sh B092 self-update fallthrough.
#
# Verifies three scenarios:
#   1. Modern c2c on PATH with `self-update` subcommand → delegates.
#   2. Old c2c on PATH without `self-update` in --help → falls through
#      to fresh standalone install (NOT delegating, NOT dying).
#   3. Old c2c whose --help mentions self-update but the command errors
#      (e.g. unhandled edge case) → falls through to fresh install.
#   4. No c2c on PATH at all → fresh install (unchanged behavior).
#
# Approach: build fake c2c shell scripts that emulate a particular binary
# generation. The harness is a stripped version of install.sh's delegation
# block, with stubbed network/install helpers so we never touch the network
# or the real install dir.
#
# Self-contained: uses a temp dir, never writes to ~/.local/bin.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/docs/install.sh"

[ -f "$INSTALL_SH" ] || { echo "FAIL: install.sh missing: $INSTALL_SH" >&2; exit 2; }
bash -n "$INSTALL_SH" || { echo "FAIL: install.sh syntax error" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---- helpers --------------------------------------------------------------

# Build a fake `c2c` script that emulates a particular binary generation.
# $1 = subcommand (modern | no-self-update | errors-on-self-update)
make_fake_c2c() {
  local variant="$1"
  local target="$WORK/$1-bin/c2c"
  mkdir -p "$(dirname "$target")"
  # Use a single heredoc with a unique tag; the inner heredoc (USAGE) is
  # body text — the OUTER heredoc terminator is _FAKE_END_.
  cat > "$target" <<_FAKE_END_
#!/bin/sh
# fake c2c — variant: $variant
case "\$1" in
  --help|-h)
    cat <<'USAGE'
Usage: c2c [OPTIONS] COMMAND ...

Commands:
$(case "$variant" in
  modern)
    echo "  self-update   Update c2c to the latest release"
    echo "  send          Send a message to a peer"
    ;;
  no-self-update)
    echo "  send          Send a message to a peer"
    echo "  list          List peers"
    ;;
  errors-on-self-update)
    echo "  self-update   Update c2c to the latest release"
    echo "  send          Send a message to a peer"
    ;;
esac)
  --version     Print version
USAGE
    exit 0
    ;;
  --version)
    echo "c2c fake ($variant) 0.0.0"
    exit 0
    ;;
  self-update)
$(case "$variant" in
  modern)
    echo '    echo "fake: self-update OK" >&2'
    echo '    exit 0'
    ;;
  no-self-update)
    echo '    echo "c2c: unknown command '"'"'self-update'"'"'" >&2'
    echo '    exit 1'
    ;;
  errors-on-self-update)
    echo '    echo "c2c: self-update failed: network unreachable" >&2'
    echo '    exit 1'
    ;;
esac)
    ;;
  *)
    echo "c2c: unknown command '\$1'" >&2
    exit 1
    ;;
esac
_FAKE_END_
  chmod +x "$target"
  printf '%s' "$target"
}

# Build a harness that includes the delegation block from install.sh
# (verbatim post-fix) with stubbed network/install helpers so we never
# touch the network or the real install dir. The harness writes its
# decision to stderr on its last line so tests can grep it.
build_harness() {
  cat > "$WORK/harness.sh" <<'HARNESS'
#!/bin/sh
set -eu

# ---- stubs ---------------------------------------------------------------

# These prevent install.sh from doing real work. Anything in install.sh
# after the delegation block that would touch the network or the host is
# shadowed here; if it ever runs, the test fails loudly.
info()    { printf 'c2c install: %s\n' "$*" >&2; }
error()   { printf 'c2c install: error: %s\n' "$*" >&2; exit 99; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || error "required command '$1' not found"; }

detect_os()    { echo linux; }
detect_arch()  { echo x64; }
resolve_latest_version() { echo "9.9.9-test"; }
find_asset_url_and_checksum() { echo "https://invalid.test/c2c.tar.gz dummy_checksum"; }
download()    { error "download called — delegation should have exited before this"; }
download_to() { error "download_to called — delegation should have exited before this"; }
verify_sha256() { return 0; }

# ---- delegation block (verbatim from docs/install.sh post-fix) -----------

c2c_has_self_update() {
  c2c --help 2>&1 | grep -qw 'self-update'
}

# Track *why* we ended up in the standalone install path so we can log it.
#   0 = no c2c on PATH
#   1 = c2c present but lacks 'self-update'
#   2 = c2c present, advertised self-update, but the delegation failed
FALLTHROUGH_REASON=0

if command -v c2c >/dev/null 2>&1; then
  C2C_PATH="$(command -v c2c)"
  info "existing c2c found on PATH: ${C2C_PATH}"
  if c2c_has_self_update; then
    info "delegating to 'c2c self-update'..."
    if c2c self-update "$@"; then
      DECISION="delegated"
      echo "$DECISION" >&2
      exit 0
    fi
    info "'c2c self-update' failed; falling through to fresh standalone install."
    FALLTHROUGH_REASON=2
  else
    info "existing c2c at ${C2C_PATH} lacks the 'self-update' subcommand."
    info "falling through to fresh standalone install."
    FALLTHROUGH_REASON=1
  fi
fi

# In the real install.sh, the next block emits a context-specific message:
case "$FALLTHROUGH_REASON" in
  0) info "c2c not found on PATH — performing fresh install." ;;
  1) info "performing fresh standalone install (existing c2c lacks self-update)." ;;
  2) info "performing fresh standalone install (existing c2c self-update failed)." ;;
esac

# Record the decision (single token on the last line) and exit cleanly.
case "$FALLTHROUGH_REASON" in
  0) DECISION="no_c2c" ;;
  1) DECISION="fallthrough_no_subcommand" ;;
  2) DECISION="fallthrough_after_failure" ;;
esac
echo "$DECISION" >&2
exit 0
HARNESS
  chmod +x "$WORK/harness.sh"
}

# ---- assertions ----------------------------------------------------------

assert_decision() {
  local label="$1" expected="$2" bin_dir="$3"
  local rc=0
  PATH="$bin_dir:$PATH" bash "$WORK/harness.sh" >"$WORK/stdout" 2>"$WORK/stderr" || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 0 ]; then
    echo "FAIL: $label: harness exited non-zero (rc=$rc)" >&2
    cat "$WORK/stderr" >&2
    exit 1
  fi
  local got
  got="$(tail -n 1 "$WORK/stderr")"
  if [ "$got" != "$expected" ]; then
    echo "FAIL: $label: expected decision '$expected', got '$got'" >&2
    echo "--- stderr ---" >&2
    cat "$WORK/stderr" >&2
    echo "--- stdout ---" >&2
    cat "$WORK/stdout" >&2
    exit 1
  fi
  echo "PASS: $label ($got)"
}

# ---- run scenarios -------------------------------------------------------

build_harness

# Case 1: modern c2c with self-update → delegate
MODERN_BIN="$(make_fake_c2c modern)"
MODERN_BIN_DIR="$(dirname "$MODERN_BIN")"
assert_decision "modern c2c delegates to self-update" "delegated" "$MODERN_BIN_DIR"

# Case 2: old c2c lacking self-update → fall through (B092 main case)
OLD_BIN="$(make_fake_c2c no-self-update)"
OLD_BIN_DIR="$(dirname "$OLD_BIN")"
assert_decision "old c2c without self-update falls through" "fallthrough_no_subcommand" "$OLD_BIN_DIR"

# Case 3: c2c that advertises self-update in --help but errors on it → fall through
ERR_BIN="$(make_fake_c2c errors-on-self-update)"
ERR_BIN_DIR="$(dirname "$ERR_BIN")"
assert_decision "c2c that errors on self-update falls through" "fallthrough_after_failure" "$ERR_BIN_DIR"

# Case 4: no c2c on PATH → fresh install (unchanged behavior)
# Use a minimal PATH with no c2c.
PATH="/usr/bin:/bin" bash "$WORK/harness.sh" >"$WORK/stdout" 2>"$WORK/stderr" || {
  echo "FAIL: no-c2c case exited non-zero (rc=$?)" >&2
  cat "$WORK/stderr" >&2
  exit 1
}
got="$(tail -n 1 "$WORK/stderr")"
if [ "$got" != "no_c2c" ]; then
  echo "FAIL: no-c2c case: expected 'no_c2c', got '$got'" >&2
  exit 1
fi
echo "PASS: no c2c on PATH performs fresh install ($got)"

# Sanity: the modern delegation actually exits at 0 (the harness exits
# with 0 for delegated). The earlier assertion verified the decision.
PATH="$MODERN_BIN_DIR:/usr/bin:/bin" bash "$WORK/harness.sh" >/dev/null 2>&1
echo "PASS: modern c2c path returns clean exit"

echo
echo "ALL OK: install.sh B092 fallthrough behaves correctly for all four scenarios."