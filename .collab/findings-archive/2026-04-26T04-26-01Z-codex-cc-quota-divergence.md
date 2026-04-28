# cc-quota entrypoints can diverge

- Symptom: `~/.local/bin/cc-quota` and `scripts/cc-quota` were regular files
  with different hashes and slightly different fallback logic.
- Discovery: `diff --no-index -- scripts/cc-quota ~/.local/bin/cc-quota`
  showed the installed copy had been edited or copied independently. The repo
  installer does not currently manage `cc-quota`.
- Root cause: the installed command was detached from the tracked script, so
  fixes to one entrypoint did not necessarily reach the other.
- Additional root cause: `scripts/cc-quota` treated `C2C_MCP_SESSION_ID` as a
  Claude Code statusline session id. Outside Claude Code, that variable can be
  a c2c alias or stale UUID, causing quota to be read from the wrong
  per-session file instead of `sl_out/last.json`.
- Fix status: patched the tracked script to use session-specific statusline
  data only from piped Claude statusline JSON or `CLAUDE_SESSION_ID`; added
  regression tests. The local installed command should be a tiny wrapper that
  delegates to the tracked script to avoid future drift.
- Severity: medium. Output can be stale or inconsistent, which is especially
  confusing for coordinator/failover decisions.
