#!/usr/bin/env bash
# Unit tests for scripts/check-glibc-max.sh (B190).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/check-glibc-max.sh"
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

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -q -- "$needle"; then
    echo "PASS: ${name}"
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${name} (missing '${needle}' in output)" >&2
    FAIL=$((FAIL + 1))
  fi
}

[ -x "$SCRIPT" ] || chmod +x "$SCRIPT"
bash -n "$SCRIPT"

# Usage errors
set +e
out="$("$SCRIPT" 2>&1)"
rc=$?
set -e
assert_eq "no-args exits 2" "2" "$rc"

set +e
out="$("$SCRIPT" not-a-version /dev/null 2>&1)"
rc=$?
set -e
assert_eq "bad-version exits 2" "2" "$rc"

set +e
out="$("$SCRIPT" 2.35 /no/such/file 2>&1)"
rc=$?
set -e
assert_eq "missing-file exits 2" "2" "$rc"

# Non-ELF file: no GLIBC symbols → OK
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
echo 'not an elf' >"$tmp"
set +e
out="$("$SCRIPT" 2.35 "$tmp" 2>&1)"
rc=$?
set -e
assert_eq "non-elf exits 0" "0" "$rc"
assert_contains "non-elf message" "no GLIBC" "$out"

# Live check against a real dynamically linked binary if present.
# Host c2c on rolling distros often needs GLIBC > 2.35 — use that to
# exercise the failure path when available.
if command -v objdump >/dev/null 2>&1 && [ -x /bin/ls ]; then
  set +e
  out="$("$SCRIPT" 99.0 /bin/ls 2>&1)"
  rc=$?
  set -e
  # /bin/ls is almost always glibc-linked on this project's Linux hosts.
  if printf '%s' "$out" | grep -q 'GLIBC_'; then
    assert_eq "ls under absurdly high ceiling exits 0" "0" "$rc"
    assert_contains "ls reports OK" "OK" "$out"
  else
    echo "SKIP: /bin/ls has no GLIBC symbols (unusual on this host)"
  fi

  # Ceiling 0.1 must fail for any real glibc binary.
  set +e
  out="$("$SCRIPT" 0.1 /bin/ls 2>&1)"
  rc=$?
  set -e
  if printf '%s' "$out" | grep -q 'GLIBC_'; then
    assert_eq "ls above tiny ceiling exits 1" "1" "$rc"
    assert_contains "ls ceiling error text" "above supported ceiling" "$out"
  else
    echo "SKIP: /bin/ls has no GLIBC symbols for failure-path test"
  fi
fi

echo "----"
echo "passed=${PASS} failed=${FAIL}"
[ "$FAIL" -eq 0 ]
