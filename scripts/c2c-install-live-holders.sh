#!/usr/bin/env bash
# c2c-install-live-holders.sh — log a warning when about to replace a c2c
# binary that's currently being executed by a live process.
#
# The atomic rm+cp in `just install-all` works (Linux unlinks open files
# safely), but if a running c2c-mcp-server is one of the targets, the
# session holding it can briefly lose MCP signals or fail to re-exec on
# subsequent fork. To peers it looks like a silent restart with no log.
#
# This script does NOT block the install — it only logs. The user
# decides whether to `c2c restart <name>` to pick up the new binary.
#
# Optional env:
#   C2C_INSTALL_QUIET=1   suppress informational messages on stderr
#   C2C_INSTALL_BIN_DIR=PATH override target dir (default ~/.local/bin)
#
# Filed: .collab/findings/2026-04-28T09-06-00Z-coordinator1-install-all-tears-down-mcp-silently.md
set -euo pipefail

bin_dir="${C2C_INSTALL_BIN_DIR:-$HOME/.local/bin}"

log() {
  if [ "${C2C_INSTALL_QUIET:-0}" != "1" ]; then
    printf '[c2c install-live-holders] %s\n' "$*" >&2
  fi
}

# Binaries that `just install-all` replaces. If you add a new binary to
# the install set, add it here too so the warning covers it.
binaries=(
  "$bin_dir/c2c"
  "$bin_dir/c2c-mcp-server"
  "$bin_dir/c2c-mcp-inner"
  "$bin_dir/c2c-inbox-hook-ocaml"
  "$bin_dir/c2c-cold-boot-hook"
  "$bin_dir/c2c-post-compact-hook"
)

# Resolve each binary to its inode + dev so we can compare /proc/*/exe
# symlinks robustly (they may resolve to a deleted-but-still-open file
# after rm). We use stat output rather than readlink because /proc/exe
# can show the (deleted) suffix.
declare -A inode_to_name
for bin in "${binaries[@]}"; do
  if [ -e "$bin" ]; then
    # Format: dev:inode → friendly name
    key=$(stat -c '%d:%i' "$bin" 2>/dev/null || echo "")
    [ -n "$key" ] && inode_to_name["$key"]="$(basename "$bin")"
  fi
done

# No installed binaries to scan against.
if [ "${#inode_to_name[@]}" -eq 0 ]; then
  exit 0
fi

# Walk /proc/*/exe. Only readable for our own pids (or with sudo).
# That's fine — we mostly care about user-owned c2c sessions.
holders=()
for exe in /proc/*/exe; do
  # Skip if we can't stat (permission, gone).
  pid_path="${exe%/exe}"
  pid="${pid_path##*/}"
  # Skip non-numeric (kernel threads etc.)
  case "$pid" in (*[!0-9]*) continue ;; esac

  key=$(stat -L -c '%d:%i' "$exe" 2>/dev/null || true)
  [ -z "$key" ] && continue

  name="${inode_to_name[$key]:-}"
  [ -z "$name" ] && continue

  comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "?")
  holders+=("pid=$pid comm=$comm bin=$name")
done

if [ "${#holders[@]}" -eq 0 ]; then
  # Nothing live — install will be transparent.
  exit 0
fi

log "WARNING: ${#holders[@]} live process(es) hold binaries about to be replaced:"
for h in "${holders[@]}"; do
  log "  $h"
done
log "  Those sessions may briefly drop MCP signals; they will not auto-pick-up the new binary."
log "  To refresh: \`c2c restart <name>\` for each managed session, or restart by other means."

# Always exit 0 — this is a heads-up, not a gate.
exit 0
