# Agent File Schema Draft

> Status: DRAFT — for review before implementation

## Goal

Define a minimal schema for `.opencode/agents/<name>.md` files that enables `c2c start opencode --agent <name>` to launch a configured agent without manual setup.

## Format

YAML frontmatter + markdown body. Backward-compatible with existing c2c-build.md format.

```yaml
---
# Required
description: One-line summary for agent selection menus
mode: subagent  # matches existing c2c-build.md format

# Optional c2c configuration
c2c:
  alias: my-agent           # optional; defaults to agent name
  auto_join_rooms:         # optional array of room ids
    - swarm-lounge
  client_type: opencode     # warn (don't error) on unknown client

# Optional permission defaults (OpenCode plugin)
permission:
  edit: allow
  bash:
    "*": deny
    "just *": allow
    # ... existing OpenCode permission format

# Optional runtime hints
temperature: 0.1
---

[Markdown body: agent persona, instructions, context]
```

## Design Principles

1. **Extensible**: new fields can be added to the `c2c:` block without breaking parsing
2. **Backward-compatible**: existing c2c-build.md stays valid (only `description` + `mode` + markdown body are required)
3. **Fail-fast**: unknown fields in `c2c:` block emit a warning but don't error
4. **No broker discovery**: agent files live in the repo under `.opencode/agents/` — no cross-machine discovery v1

## Open Questions

1. Should `c2c:` config override instance-level config, or be additive?
2. Do we need a `themes:` block for Max's fork? (暂定: defer to v2)
3. Should agent files be validated at `c2c start --agent` time, or just at load time?

## Next Step

Review with CEO before implementation.