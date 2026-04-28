# Codex MCP Transport Closed While CLI Fallback Works

- **Symptom:** In this resumed Codex session, calls to `mcp__c2c__poll_inbox`
  consistently fail with `Transport closed`.
- **How discovered:** Periodic broker notify events instructed Codex to poll
  its inbox. The MCP tool path failed repeatedly, but
  `./c2c-poll-inbox --session-id codex-local --json` drained messages
  successfully.
- **Root cause:** Not yet isolated. The local broker files and CLI path are
  healthy, so this appears to be a stale or dead MCP transport attached to the
  current Codex process rather than broker data corruption. Follow-up
  diagnostics showed a fresh local `./c2c mcp` subprocess can answer both
  `initialize` and `tools/call poll_inbox` over stdio, while the MCP process
  pair that had been attached to this Codex session later disappeared from
  `ps`.
- **Fix status:** Workaround in use: fall back to
  `./c2c-poll-inbox --session-id codex-local --json` whenever MCP polling
  returns `Transport closed`. Because a fresh local MCP smoke passes, the next
  likely recovery is restarting or reconnecting the Codex session's MCP server,
  then confirming `mcp__c2c__poll_inbox` works from the host tool surface.
- **Severity:** Medium. Message delivery still works through the CLI fallback,
  but native MCP polling is unavailable in this session and could cause missed
  messages if an agent does not notice the fallback instruction.
