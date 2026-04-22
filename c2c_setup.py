#!/usr/bin/env python3
"""Unified c2c setup command for all supported clients.

Usage: c2c setup <client> [options]

Supported clients:
  claude-code    Configure ~/.claude.json MCP entry + PostToolUse hook
  opencode       Write .opencode/opencode.json MCP entry for a target dir
  codex          Write ~/.codex/config.toml MCP entry + tool approvals
  kimi           Write ~/.kimi/mcp.json MCP entry for Kimi Code CLI
  crush          Write ~/.config/crush/crush.json MCP entry for Crush CLI

Examples:
  c2c setup claude-code          # configure current user's Claude Code
  c2c setup claude-code --force  # overwrite existing config
  c2c setup opencode             # write config for cwd
  c2c setup opencode --target-dir ~/src/myrepo
  c2c setup codex                # configure current user's Codex
  c2c setup kimi                 # configure current user's Kimi Code CLI
  c2c setup crush                # configure current user's Crush CLI

Run `c2c setup <client> --help` for per-client options.
"""
from __future__ import annotations

import sys


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0

    client = argv[0]
    remainder = argv[1:]

    if client == "claude-code":
        import c2c_configure_claude_code
        return c2c_configure_claude_code.main(remainder)
    if client == "opencode":
        import c2c_configure_opencode
        return c2c_configure_opencode.main(remainder)
    if client == "codex" or client == "codex-headless":
        import c2c_configure_codex
        return c2c_configure_codex.main(remainder)
    if client == "kimi":
        import c2c_configure_kimi
        return c2c_configure_kimi.main(remainder)
    if client == "crush":
        import c2c_configure_crush
        return c2c_configure_crush.main(remainder)

    print(
        f"c2c setup: unknown client '{client}'\n"
        "Supported: claude-code, opencode, codex, codex-headless, kimi, crush",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
