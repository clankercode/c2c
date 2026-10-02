#!/usr/bin/env bash
# Regression check for the platform guard on the lifecycle cleanup wrapper.
# macOS defines O_NOFOLLOW, but the exact-owner implementation is Linux-only.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
compiler="${CC:-clang}"
ocaml_include="$(ocamlc -where)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/c2c-posix-stubs.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

# The source includes <util.h> on Darwin/BSD for forkpty.  This check only
# needs only a declaration stand-in, so it stays independent of the host libc
# while preserving the Darwin include branch.
cat > "$tmp_dir/util.h" <<'EOF'
#include <sys/types.h>
int forkpty(int *, void *, void *, void *);
EOF

"$compiler" -fsyntax-only -Werror \
  -D__APPLE__ -U__linux__ -DO_NOFOLLOW=0x1 \
  -I"$tmp_dir" -I"$ocaml_include" \
  "$repo_root/ocaml/c2c_posix_stubs.c"

"$compiler" -fsyntax-only -Werror \
  -U__APPLE__ -U__linux__ -UO_NOFOLLOW \
  -I"$tmp_dir" -I"$ocaml_include" \
  "$repo_root/ocaml/c2c_posix_stubs.c"

"$compiler" -E -P \
  -D__APPLE__ -U__linux__ -DO_NOFOLLOW=0x1 \
  -I"$tmp_dir" -I"$ocaml_include" \
  "$repo_root/ocaml/c2c_posix_stubs.c" > "$tmp_dir/preprocessed.c"

grep -q 'caml_c2c_unlink_regular_confirmed' "$tmp_dir/preprocessed.c"
if grep -q 'c2c_open_locked_parent\|c2c_unlink_one_at' "$tmp_dir/preprocessed.c"; then
    echo "FAIL: Linux-only cleanup helpers leaked into the Darwin build" >&2
    exit 1
fi

echo "PASS: Darwin-shaped and no-O_NOFOLLOW configurations compile; cleanup remains fail-closed"
