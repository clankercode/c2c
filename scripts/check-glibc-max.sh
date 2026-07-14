#!/usr/bin/env bash
# check-glibc-max.sh — fail if any ELF requires a GLIBC symbol newer than MAX.
#
# Usage:
#   scripts/check-glibc-max.sh MAX_VERSION path [path ...]
#
# Example:
#   scripts/check-glibc-max.sh 2.35 dist/c2c-linux-x64/c2c
#
# Exit codes:
#   0 — all paths are at or under the ceiling (or non-ELF / no GLIBC symbols)
#   1 — at least one path requires a newer GLIBC
#   2 — usage / tooling error
#
# Used by .github/workflows/release.yml (B190) to keep official Linux
# release binaries runnable on Ubuntu 22.04+ (glibc 2.35).

set -euo pipefail

usage() {
  echo "usage: $0 MAX_VERSION path [path ...]" >&2
  echo "  MAX_VERSION e.g. 2.35" >&2
  exit 2
}

if [ "$#" -lt 2 ]; then
  usage
fi

max_allowed="$1"
shift

if ! printf '%s' "$max_allowed" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
  echo "error: MAX_VERSION must look like N.N (got: ${max_allowed})" >&2
  exit 2
fi

if ! command -v objdump >/dev/null 2>&1; then
  echo "error: objdump not found (install binutils)" >&2
  exit 2
fi

overall_max=""
any_checked=0
failed=0

for path in "$@"; do
  if [ ! -e "$path" ]; then
    echo "error: path not found: ${path}" >&2
    exit 2
  fi
  if [ -d "$path" ]; then
    echo "error: path is a directory (pass file paths): ${path}" >&2
    exit 2
  fi

  # Collect unique GLIBC_* versions from the dynamic symbol table.
  # Non-ELF files / stripped static musl binaries may yield nothing.
  found_versions="$(
    {
      objdump -T "$path" 2>/dev/null || true
    } | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' \
      | sed 's/^GLIBC_//' \
      | sort -Vu || true
  )"

  if [ -z "$found_versions" ]; then
    printf 'check-glibc-max: %s: no GLIBC_* version symbols (skipped)\n' "$path"
    continue
  fi

  any_checked=1
  max_found="$(printf '%s\n' "$found_versions" | tail -n 1)"
  printf 'check-glibc-max: %s requires up to GLIBC_%s\n' "$path" "$max_found"
  printf '%s\n' "$found_versions" | sed 's/^/  GLIBC_/'

  if [ -z "$overall_max" ]; then
    overall_max="$max_found"
  else
    overall_max="$(printf '%s\n%s\n' "$overall_max" "$max_found" | sort -Vu | tail -n 1)"
  fi

  newest="$(printf '%s\n%s\n' "$max_allowed" "$max_found" | sort -Vu | tail -n 1)"
  if [ "$newest" != "$max_allowed" ]; then
    echo "error: ${path} requires GLIBC_${max_found}, above supported ceiling GLIBC_${max_allowed}" >&2
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  exit 1
fi

if [ "$any_checked" -eq 1 ]; then
  printf 'check-glibc-max: OK (max required GLIBC_%s ≤ ceiling GLIBC_%s)\n' \
    "$overall_max" "$max_allowed"
else
  echo "check-glibc-max: OK (no GLIBC symbols found on any path)"
fi
