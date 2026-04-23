# Claude Code doesn't export CLAUDE_CODE_SESSION_ID to shell env

**Reporter**: coordinator1 (Cairn-Vigil)
**Date**: 2026-04-23 17:41 UTC (2026-04-24 03:41 AEST)
**Severity**: papercut — enables a class of session-hijack footguns

## Symptom

`env | grep CLAUDE` inside a Claude Code Bash tool returns only:

```
CLAUDE_CODE_ENTRYPOINT=cli
CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
CLAUDECODE=1
CLAUDE_CODE_EXECPATH=/home/xertrov/.local/share/claude/versions/2.1.118
```

No `CLAUDE_SESSION_ID` / `CLAUDE_CODE_SESSION_ID`. `env | grep SESSION` only
shows `XDG_SESSION_ID` and our own `C2C_MCP_SESSION_ID` (which we set
manually for exactly this reason).

## Why it matters

- Any child CLI shelled out from a Bash tool cannot know which CC session
  it belongs to.
- When running `kimi -p`, `codex`, etc. from inside CC, they can't
  self-identify — this is the root cause of the session-hijack footgun we
  guard against by manually exporting `C2C_MCP_SESSION_ID=...`.
- Tools trying to correlate shell activity back to a CC session have to
  walk `/proc` and guess, instead of reading one env var.
- The broker gets the session ID via MCP `initialize`, but that path is
  MCP-only. Shell children have no equivalent.

## Ask

Claude Code should export `CLAUDE_CODE_SESSION_ID` (and ideally
`CLAUDE_CODE_TRANSCRIPT_PATH`) into the Bash tool's environment. Matches
what most agent harnesses already do (Codex exports `CODEX_SESSION_ID`,
OpenCode exports its session dir).

## Workaround

Set `C2C_MCP_SESSION_ID` explicitly when launching child CLIs, as
documented in CLAUDE.md. Not a fix — every new integration has to
remember this.

## Relevant for

- tundra-coder-live2 (working on OCaml-native c2c poker; wants to
  correlate poker targets back to CC sessions without /proc walks)
- anyone writing CC → child-CLI integrations

## Discussion context

Flagged by Max 2026-04-24 03:41 AEST after confirming that `env | grep
CLAUDE` produces the same output inside CC Bash as in his shell — i.e.
the session ID truly isn't passed through, not just filtered by a tool
wrapper.
