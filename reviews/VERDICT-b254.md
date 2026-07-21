# PASS — B254/B255/B256/B257 no-MCP-by-default review

Reviewed against `d996db56` (including `3b483fb0`, `1a163676`, `e5d1dda9`, and
`db2e79e6`). The requested MCP opt-in behavior is complete and no blocking
issue remains.

## Review fixes made

- Default client setup no longer resolves or requires `c2c-mcp-server`; hooks,
  skills, and the OpenCode plugin work in a binary-only installation.
- The default Claude path does not parse, rewrite, or fail on an existing MCP
  JSON file. Its result no longer duplicates MCP receipt metadata.
- Install-state detection now recognises a hooks/skill-only client as installed;
  `install all --with-mcp` separately detects MCP state so it can upgrade an
  existing default installation. The TUI does not ask the Claude channel-MCP
  prompt on its no-MCP route.
- Uninstall now treats a manifest receipt as authoritative for mutable MCP
  keys/TOML sections. A no-MCP receipt cannot reconstruct and remove an
  operator's pre-existing MCP configuration.
- A stale optional Codex MCP block advises `c2c install codex --with-mcp`.
  `Mcp_missing` remains non-blocking for managed Codex.
- Corrected docs: MCP auto-join is opt-in; the default hooks/plugin path leaves
  room membership explicit through the skill/CLI.

## Verification

- Forced build, worktree-safe targets, `-j 2`: `c2c.exe`,
  `c2c_mcp_server.exe`, the affected setup/uninstall/plugin suites, Codex
  session suite, and the full CLI suite — passed.
- Focused suites: 124 tests passed:
  - setup Claude 7; setup Codex 9; setup Kimi 24; OpenCode embedded plugin 5;
    Codex uninstall 3; setup Grok 3; Codex session 73.
- Full `test_c2c_cli`: 188 tests passed in 56.650s.
- Isolated temporary-HOME CLI runs verified all four default installs write no
  MCP config or MCP manifest artifact while delivery artifacts remain present;
  all four `--with-mcp` runs write their MCP config. `install all` is
  binary-only without `--with-clients`, and forwards `--with-mcp` with it.

No push, managed-session launch, or real-HOME install was performed.
