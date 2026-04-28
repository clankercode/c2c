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
bin_dir="$(dirname "$stamp_file")"

sha=$(git rev-parse HEAD 2>/dev/null || echo "")
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
alias_name="${C2C_MCP_AUTO_REGISTER_ALIAS:-${USER:-unknown}}"
worktree="$PWD"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

hash_file() {
  local path="$1"
  if [ -f "$path" ]; then
    sha256sum "$path" | awk '{print $1}'
  else
    printf ''
  fi
}

c2c_path="$bin_dir/c2c"
mcp_path="$bin_dir/c2c-mcp-server"
hook_path="$bin_dir/c2c-inbox-hook-ocaml"
cold_boot_path="$bin_dir/c2c-cold-boot-hook"

c2c_hash=$(hash_file "$c2c_path")
mcp_hash=$(hash_file "$mcp_path")
hook_hash=$(hash_file "$hook_path")
cold_boot_hash=$(hash_file "$cold_boot_path")

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
  "installed_at": "$ts",
  "binaries": {
    "c2c": {
      "path": "$c2c_path",
      "sha256": "$c2c_hash"
    },
    "c2c-mcp-server": {
      "path": "$mcp_path",
      "sha256": "$mcp_hash"
    },
    "c2c-inbox-hook-ocaml": {
      "path": "$hook_path",
      "sha256": "$hook_hash"
    },
    "c2c-cold-boot-hook": {
      "path": "$cold_boot_path",
      "sha256": "$cold_boot_hash"
    }
  }
}
EOF
mv "$tmp" "$stamp_file"
