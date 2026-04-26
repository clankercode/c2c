#!/usr/bin/env bash
# c2c-install-stamp.sh — write the version stamp at ~/.local/bin/.c2c-version
# after a successful install. The stamp records the SHA the binaries were
# built from, plus diagnostics for the guard's refuse messages.
#
# Run AFTER the cp in `just install-all`. Atomic (write-temp + rename).
#
# Optional env:
#   C2C_INSTALL_STAMP=PATH override the stamp path (testing)
set -euo pipefail

stamp_file="${C2C_INSTALL_STAMP:-$HOME/.local/bin/.c2c-version}"

sha=$(git rev-parse HEAD 2>/dev/null || echo "")
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
alias_name="${C2C_MCP_AUTO_REGISTER_ALIAS:-${USER:-unknown}}"
worktree="$PWD"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Skip if not in a git repo (e.g. tarball install) — no useful sha to record.
if [ -z "$sha" ]; then
  exit 0
fi

mkdir -p "$(dirname "$stamp_file")"
tmp="$stamp_file.tmp.$$"
cat >"$tmp" <<EOF
{
  "sha": "$sha",
  "branch": "$branch",
  "alias": "$alias_name",
  "worktree": "$worktree",
  "installed_at": "$ts"
}
EOF
mv "$tmp" "$stamp_file"
