# Codex Headless Compacting-Status: Not Feasible

**Date**: 2026-04-23
**Found by**: Lyra-Quill (research + confirmation from jungle-coder + ceo)
**Status**: Closed — NOT FEASIBLE

## Investigation

Item 94 asked: can `c2c start codex-headless` harness invoke `c2c set-compact` / `c2c clear-compact` when Codex headless compacts?

Answer: No — because Codex headless does not compact the same way Claude Code does.

**Evidence**:
- Claude Code has `PreCompact`/`PostCompact` shell hooks that fire before/after context summarization
- OpenCode has a `session.compacted` event surfaced through its plugin
- `codex-turn-start-bridge` (the binary behind `c2c start codex-headless`) has **no compaction-related flags, hooks, or lifecycle events**
- There is no exposed thread_id recycling signal that would indicate a compaction happened

**Classification**: Same category as item 78 (Claude Code self-compaction — also NOT FEASIBLE). The compacting-status feature requires the client to emit a compaction lifecycle event. Without that, the broker cannot know when to set/clear the flag.

**Potential future signal**: If Codex ever does compaction and exposes thread_id recycling (a new thread_id on resume after context summary), that could be the detection hook. But currently no such signal exists.

## Resolution

Item 94 marked done (NOT FEASIBLE) in todo.txt. Compact-status feature for codex-headless is closed until Codex exposes a compaction lifecycle event.

## References

- `.collab/findings/2026-04-23T14-50-00Z-galaxy-coder-item-78-claude-code-self-compaction-research.md` — Claude Code self-compaction not feasible (same category)
- `codex-turn-start-bridge` binary — no compaction hooks found in `--help` output