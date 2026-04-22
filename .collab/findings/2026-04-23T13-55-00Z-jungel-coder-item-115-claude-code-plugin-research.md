---
alias: jungel-coder
utc: 2026-04-23T13-55-00Z
updated: 2026-04-23T14-02-00Z
severity: low
tags: [claude-code, plugin, delivery, research]
---

# Item 115 Research: Claude Code Plugin Feasibility

## What item 115 asks for

Build a proper Claude Code plugin for c2c mail delivery, parallel to `.opencode/plugins/c2c.ts` and the Codex integration. Current Claude Code delivery is PostToolUse-hook-only which fires only on tool calls — idle sessions miss messages.

## Key questions to answer

1. Can we push messages into transcript?
2. Background tasks?
3. Event hooks beyond PostToolUse?
4. Plugin SDK surface area

## Findings

### Claude Code Plugin Architecture

Claude Code uses a JSON-based plugin hook system. Plugins declare hooks in `hooks.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "type": "command", "command": "...", "timeout": 30 }],
    "Stop": [...],
    "PreCompact": [...]
  }
}
```

Available event hooks (confirmed from idle-info plugin):
- `UserPromptSubmit` — fires when user submits a prompt
- `Stop` — fires when assistant stops generating
- `PreCompact` — fires before context compaction
- `SessionStart` / `sessionStart` — session initialization
- (Also: `PostToolUse`, `PreToolUse`, `PostCompact`, etc. from settings.json)

### What hooks CAN do

Hooks receive JSON event data on stdin and can output a response with:
- **`systemMessage`** — injected into context (confirmed from idle-info `user-prompt-submit.js`)
- **`hookSpecificOutput.additionalContext`** — additional context injected
- **`hookSpecificOutput.hookEventName`** — event name for routing

This means plugins CAN inject content into the transcript — but only when the hook fires.

### What hooks CANNOT do

1. **Background tasks**: No mechanism for plugins to run persistent background processes or scheduled jobs
2. **Real-time delivery to idle sessions**: Hooks only fire on events; a session that hasn't triggered any event in hours won't receive any hook output
3. **Push without an event trigger**: There's no `on idle` or `on timer` hook

### What OpenCode plugin (`c2c.ts`) CAN do that Claude Code hooks cannot

| Capability | OpenCode (`c2c.ts`) | Claude Code (hooks) |
|---|---|---|
| Real-time message injection | `promptAsync()` — immediate | `systemMessage` in hook response — only on event |
| Permission waits | `waitForPermissionReply()` — blocking | Not possible |
| Background delivery daemon | Yes — polling loop | No |
| Event-driven on any event | Yes | Only predefined hooks |

### Existing Claude Code Integration (what we have now)

- `~/.claude/hooks/c2c-inbox-check.sh` — PostToolUse hook calling `c2c hook`
- `~/.claude/hooks/c2c-precompact.sh` — PreCompact → `c2c set-compact`
- `~/.claude/hooks/c2c-postcompact.sh` — PostCompact → `c2c clear-compact`
- All shell-command based, not TypeScript

### Existing Workaround (already in production)

`c2c monitor --archive` (Monitor tool with inotifywait) provides near-real-time wake-on-inbox-write. This solves the idle-session delivery gap. The Monitor fires a notification when new messages arrive, which wakes the agent via the Monitor tool. This is the recommended pattern in CLAUDE.md and is working.

### What a Claude Code plugin COULD improve

Even without a TypeScript SDK, a proper Claude Code plugin could:

1. **Hook into `UserPromptSubmit`** and inject pending c2c messages as a `systemMessage` — better integration than the current PostToolUse approach (would inject at prompt time rather than after tool calls)
2. **Hook into `SessionStart`** and inject c2c session state / unread count
3. **Unified plugin package** — could distribute the c2c integration as a installable Claude Code plugin instead of manual hook setup

But it CANNOT solve the idle-session delivery problem — that requires background execution which Claude Code hooks don't support.

## Conclusion

**Feasibility**: Partial. A Claude Code plugin could improve message injection quality for active sessions, but cannot provide real-time delivery to idle sessions without background task support.

**Real-time idle delivery**: Not possible without Claude Code plugin SDK with background task support. Monitor approach is the correct solution for this.

**Recommendation**:
1. A Claude Code plugin is worth building for better active-session delivery and easier installation
2. But it should NOT be the solution for idle-session delivery — Monitor is already the right answer there
3. File feature request with Anthropic for background task / real-time push support in Claude Code

## Next Phase (if pursued)

Phase 1 (this scope): Design a `hooks.json`-based c2c plugin that:
- Hooks `UserPromptSubmit` to inject pending messages
- Hooks `SessionStart` to inject session context
- Ships as an installable plugin package (drop in `~/.claude/plugins/cache/`)

Phase 2 (deferred): TypeScript plugin SDK request to Anthropic.

Filed by jungel-coder 2026-04-23.