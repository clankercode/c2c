# #140: OpenCode cross-client role pollution investigation

**Date**: 2026-04-24T09:25 UTC
**Investigator**: jungle-coder
**Contributors**: galaxy-coder (additional evidence)
**Status**: CLOSED — not a bug; by design

## Concern

Does OpenCode auto-read `.claude/agents/*.md` (or any Claude Code-specific agent path), potentially conflicting with c2c's role loading from `.c2c/roles/`?

## Findings

### OpenCode agent loading paths (confirmed via opencode.ai/docs/agents)

OpenCode loads agents from:
- **Global**: `~/.config/opencode/agents/` — markdown files
- **Per-project**: `.opencode/agents/` — markdown files

Agent names are derived from filenames (e.g. `review.md` → `@review` agent).

### c2c role → OpenCode agent pipeline (galaxy-coder补充证据)

Evidence from `c2c.ml:6704`:
```ocaml
let agent_file_path ~client ~name =
  match client with
  | "opencode" -> ".opencode" // "agents" // (name ^ ".md")
  | "claude"   -> ".claude"   // "agents" // (name ^ ".md")
```

Evidence from `Agent-files.md` line 30:
> `c2c` reads `.c2c/roles/<name>.md`, renders it to `.opencode/agents/<name>.md` (gitignored), and launches OpenCode with the agent active.

**The two-layer design**:
1. Canonical source: `.c2c/roles/<name>.md` (c2c-owned)
2. Compiled output: `.opencode/agents/<name>.md` (c2c writes here; OpenCode reads here)
3. `.opencode/agents/` files are gitignored — don't pollute the repo

This means c2c's role system and OpenCode's agent loading are **designed to work together**, not conflict. Every compiled role becomes visible in OpenCode's agent menu — this is the feature.

### Conclusion

**No cross-pollution**. The concern was unfounded.
- OpenCode never reads `.claude/agents/` — that's Claude Code's path
- c2c writes to `.opencode/agents/` by design, not by accident
- The two paths serve different layers (compiled output vs canonical source)

## Files examined

- OpenCode docs: https://opencode.ai/docs/agents
- c2c.ml:6704 — `agent_file_path` function
- Agent-files.md — role compilation pipeline
- `.c2c/roles/`: 6 role files (stanza-coder, test-agent, review-bot, planner1, tundra-coder, Lyra-Quill)
- `.opencode/agents/`: does not exist in this repo (gitignored output)
- `.claude/agents/`: does not exist in this repo

## Resolution

**Not a bug — by design.** Close the concern. c2c compiles roles to OpenCode's native format as an intentional feature.