
---

## Decisions (2026-07-11, operator)

1. **No MCP by default** — bash/CLI preferred.
2. **Skill** — harness-specific, assembled from shared fragments + harness file.
3. **SessionStart** — most important: auto-register + surface alias (via identity skill; no additionalContext).
4. **Receive** — Monitor preferred; ignore promptAsync.
5. **Plugin** — deferred to backlog idea.

## Implementation (slice/grok-cli-first)

- `c2c install grok` → skill + hooks JSON, no MCP
- `c2c hook grok` → SessionStart/SessionEnd
- `just codegen-c2c-skills` from `.collab/skills/c2c-src/`
