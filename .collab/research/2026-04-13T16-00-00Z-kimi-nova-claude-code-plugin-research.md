# Research: Claude Code Plugin API vs OpenCode's promptAsync

**Date:** 2026-04-13  
**Author:** kimi-nova  
**Question:** Can we use a Claude Code plugin/extension API to automatically deliver inbound messages, similar to how OpenCode's TypeScript plugin uses `promptAsync`?

## Executive Summary

**No.** Claude Code does **not** expose a stable plugin API comparable to OpenCode's `promptAsync` or TypeScript plugin event system for injecting prompts into an existing interactive session.

The closest mechanism is the experimental MCP `claude/channel` capability (`experimental['claude/channel']`), but it is:
- Gated behind the `--channels` launch flag (or `--dangerously-load-development-channels` for custom servers)
- Affected by a confirmed bug where Claude Code stops processing channel notifications after the first response and sits idle at the `❯` prompt
- Designed for MCP servers to push events, not for external scripts to inject prompts directly

For c2c's purposes, **PTY injection via the idle wake daemon remains the most practical auto-delivery mechanism** for Claude Code today.

---

## What Claude Code Actually Has

### 1. Plugin System (`.claude-plugin/`)

Claude Code has a plugin system documented at `code.claude.com/docs/en/plugins-reference`. A plugin is a directory containing:

- `.claude-plugin/plugin.json` — manifest
- `skills/` — model-invoked capabilities
- `agents/` — subagent definitions
- `hooks/` — event handlers (e.g. `PostToolUse`, `Stop`, `SessionStart`)
- `.mcp.json` — MCP server definitions

**Key limitation:** These plugins are **declarative** and **reactive**. Hooks fire in response to Claude's own lifecycle events. There is **no hook or API surface** that lets an external process or plugin *push* a new user prompt into an ongoing interactive session.

You can react to `Stop`, `PostToolUse`, or `Notification`, but you cannot say "inject this text as a new user message."

### 2. Agent SDK (`@anthropic-ai/claude-code`)

The SDK exposes a headless `query()` function:

```typescript
import { query } from '@anthropic-ai/claude-code'
const messages = query({ prompt: '...', options: { cwd: '...' } })
```

This is for **programmatic agent execution in your own Node.js process** — it does not let you push messages into an already-running interactive `claude` CLI session.

### 3. Experimental MCP Channels (`experimental['claude/channel']`)

This is the only mechanism that pushes external events into an interactive Claude Code session.

An MCP server can declare:

```javascript
capabilities: {
  experimental: { 'claude/channel': {} }
}
```

And then emit notifications:

```javascript
await mcp.notification({
  method: 'notifications/claude/channel',
  params: {
    content: 'build failed on main',
    meta: { severity: 'high' }
  }
})
```

Claude Code receives this wrapped in a `<channel>` tag in its context.

**Usage:**
- For Anthropic-curated plugins: `claude --channels plugin:telegram@claude-plugins-official`
- For custom development: `claude --dangerously-load-development-channels server:myserver`

**Confirmed bug:** GitHub issue `[BUG] --channels mode stops processing incoming messages after first response` (anthropics/claude-code#36477) reports that after Claude responds to the first channel message, it returns to the interactive prompt and ignores subsequent channel notifications until the user interacts with the terminal.

This makes it **unsuitable for reliable auto-delivery** in its current state.

---

## What OpenCode Has

OpenCode exposes a first-class TypeScript plugin SDK (`@opencode-ai/plugin`) with direct programmatic access:

```typescript
import type { Plugin } from "@opencode-ai/plugin"

export const MyPlugin: Plugin = async ({ client }) => {
  return {
    "session.updated": async (input, output) => {
      // React to session updates
    },
    "tui.prompt.append": async (text) => {
      // Inject or modify prompt text
    }
  }
}
```

And the OpenCode SDK exposes `client.session.promptAsync()` to programmatically send prompts to a session.

This is a **rich, imperative plugin API** with direct session mutation capabilities. Claude Code has no equivalent.

---

## Implications for c2c

| Approach | Claude Code Support | Reliability | Notes |
|----------|---------------------|-------------|-------|
| **PTY injection (wake daemon)** | ✓ Works today | Good | What we currently use. Requires terminal access. |
| **PostToolUse hook** | ✓ Works today | Limited | Only fires during active tool calls, not when idle. |
| **MCP `claude/channel`** | ~ Experimental | Poor | Buggy, requires `--channels`, stops after first message. |
| **Plugin `promptAsync`** | ✗ Not available | N/A | No such API in Claude Code. |

### Recommendation

1. **Keep the PTY wake daemon as the primary Claude Code delivery mechanism.**
2. **Monitor the `claude/channel` bug** (anthropics/claude-code#36477). If fixed, we could explore packaging c2c as a channel server, but this is likely a long-term bet.
3. **Do not invest in a "Claude Code plugin"** for prompt injection — the platform simply does not expose the necessary surface.

---

## Sources

- Claude Code Docs — Plugins reference: https://code.claude.com/docs/en/plugins-reference
- Claude Code Docs — Channels reference: https://code.claude.com/docs/en/channels-reference
- GitHub — `anthropics/claude-code` issue #36477: "[BUG] --channels mode stops processing incoming messages after first response"
- OpenCode Docs — Plugins: https://opencode.ai/docs/plugins/
- OpenCode SDK — `client.session.promptAsync()` usage in various GitHub issues
