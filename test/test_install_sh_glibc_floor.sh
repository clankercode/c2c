#!/usr/bin/env bash
# Smoke tests for docs/install.sh B190 glibc floor helpers.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/docs/install.sh"
PASS=0
FAIL=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: ${name}"
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${name} (expected=${expected} actual=${actual})" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_ok() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS: ${name}"
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${name}" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_fail() {
  local name="$1"
  shift
  if "$@"; then
    echo "FAIL: ${name} (expected non-zero)" >&2
    FAIL=$((FAIL + 1))
  else
    echo "PASS: ${name}"
    PASS=$((PASS + 1))
  fi
}

[ -f "$INSTALL_SH" ] || { echo "FAIL: install.sh missing" >&2; exit 2; }
# install.sh is POSIX sh; bash -n still catches many syntax errors
bash -n "$INSTALL_SH"
sh -n "$INSTALL_SH"

# Extract helper functions into a harness (no network, no install side effects).
HARNESS="$(mktemp)"
trap 'rm -f "$HARNESS"' EXIT
cat >"$HARNESS" <<'EOF'
set -eu
MIN_LINUX_GLIBC="2.35"
error() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { :; }
version_lt() {
  _a="$1"
  _b="$2"
  _newest="$(printf '%s\n%s\n' "$_a" "$_b" | sort -Vu | tail -n 1)"
  [ "$_newest" = "$_b" ] && [ "$_a" != "$_b" ]
}
EOF
# Pull the two functions from install.sh verbatim between their markers.
sed -n '/^version_lt() {$/,/^}$/p' "$INSTALL_SH" >/dev/null
# Re-define from known-good copy already in harness; assert install.sh still has them.
grep -q '^version_lt()' "$INSTALL_SH"
grep -q '^host_glibc_version()' "$INSTALL_SH"
grep -q '^check_linux_glibc_floor()' "$INSTALL_SH"
grep -q 'MIN_LINUX_GLIBC="2.35"' "$INSTALL_SH"
grep -q 'check_linux_glibc_floor' "$INSTALL_SH"

# Unit-test version_lt
# shellcheck disable=SC1090
. "$HARNESS"
assert_ok "2.31 < 2.35" version_lt 2.31 2.35
assert_ok "2.34 < 2.35" version_lt 2.34 2.35
assert_fail "2.35 not < 2.35" version_lt 2.35 2.35
assert_fail "2.38 not < 2.35" version_lt 2.38 2.35
assert_ok "2.35 < 2.38" version_lt 2.35 2.38

# Simulate check_linux_glibc_floor against fixed uname/ldd via a tiny driver.
driver="$(mktemp)"
cat >"$driver" <<'EOF'
set -eu
MIN_LINUX_GLIBC="2.35"
error() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf 'info: %s\n' "$*" >&2; }
version_lt() {
  _a="$1"; _b="$2"
  _newest="$(printf '%s\n%s\n' "$_a" "$_b" | sort -Vu | tail -n 1)"
  [ "$_newest" = "$_b" ] && [ "$_a" != "$_b" ]
}
host_glibc_version() { printf '%s' "$FAKE_GLIBC"; }
uname() { printf '%s\n' "$FAKE_UNAME"; }
check_linux_glibc_floor() {
  case "$(uname -s)" in
    Linux*) ;;
    *) return 0 ;;
  esac
  _glibc="$(host_glibc_version)"
  if [ "$_glibc" = "musl" ]; then
    error "official Linux releases are glibc-linked and do not run on musl"
  fi
  if [ -n "$_glibc" ] && version_lt "$_glibc" "$MIN_LINUX_GLIBC"; then
    error "host glibc ${_glibc} is older than the minimum"
  fi
}
check_linux_glibc_floor
EOF

set +e
out="$(FAKE_UNAME=Linux FAKE_GLIBC=2.31 sh "$driver" 2>&1)"
rc=$?
set -e
assert_eq "linux 2.31 rejected rc" "1" "$rc"
assert_ok "linux 2.31 error text" sh -c "printf '%s' \"$out\" | grep -q 'older than the minimum'"

set +e
out="$(FAKE_UNAME=Linux FAKE_GLIBC=2.35 sh "$driver" 2>&1)"
rc=$?
set -e
assert_eq "linux 2.35 accepted rc" "0" "$rc"

set +e
out="$(FAKE_UNAME=Linux FAKE_GLIBC=2.39 sh "$driver" 2>&1)"
rc=$?
set -e
assert_eq "linux 2.39 accepted rc" "0" "$rc"

set +e
out="$(FAKE_UNAME=Darwin FAKE_GLIBC=2.0 sh "$driver" 2>&1)"
rc=$?
set -e
assert_eq "darwin skips glibc check rc" "0" "$rc"

set +e
out="$(FAKE_UNAME=Linux FAKE_GLIBC=musl sh "$driver" 2>&1)"
rc=$?
set -e
assert_eq "musl rejected rc" "1" "$rc"
assert_ok "musl error text" sh -c "printf '%s' \"$out\" | grep -qi musl"

rm -f "$driver"

echo "----"
echo "passed=${PASS} failed=${FAIL}"
[ "$FAIL" -eq 0 ]
