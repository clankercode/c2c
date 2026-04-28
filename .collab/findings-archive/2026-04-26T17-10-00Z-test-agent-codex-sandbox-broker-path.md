# Finding: Codex Sandbox Broker Path — NOT $HOME/.c2c/

**Severity**: Informational (design validation for #294)

**Date**: 2026-04-26

## Context
Coordinator1 asked whether `$HOME/.c2c/` writes work inside the codex sandbox,
which is the load-bearing assumption for stanza's #294 redesign:
`$HOME/.c2c/repos/<fingerprint>/broker/`

## Finding
**Codex c2c MCP config pins `C2C_MCP_BROKER_ROOT` to an explicit host path, not `$HOME/.c2c/`**.

When `c2c install codex` runs, it writes this to the codex MCP config env:
```
C2C_MCP_BROKER_ROOT = "/home/xertrov/src/c2c/.git/c2c/mcp"
```

The codex sandbox at `/tmp/codex-home/` isolates codex's own files (memories, skills, logs).
The c2c broker is NOT inside the sandbox — it is at the explicit host path set in the MCP
server env block. Therefore:

- **c2c broker writes from codex go to the real host filesystem** (same as other clients)
- **The `$HOME/.c2c/` sandbox restriction does not affect c2c's broker path**
- **The #294 redesign assumption (per-repo `$HOME/.c2c/repos/<fp>/broker/`) is safe for codex**

## How Verified
- `c2c install codex` output shows broker root in MCP config: `/home/xertrov/src/c2c/.git/c2c/mcp`
- `c2c install codex` with `HOME=/tmp/codex-home` (sandboxed) did NOT create `/tmp/codex-home/.c2c/`
- Only other clients (claude, opencode, kimi, crush) confirmed by coordinator1 to have full $HOME access

## Status
✓ No blocker for #294. Codex broker path already explicitly host-based.
