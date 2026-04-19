# OpenCode Notification/Message Injection Research

## Summary

**`notifications/claude/channel` is NOT supported in OpenCode.** OpenCode has no equivalent mechanism for external processes to inject visible messages into its chat UI via an MCP-style notification channel. However, OpenCode provides several alternative mechanisms that partially cover the use case.

---

## What OpenCode Has Instead

### 1. Server-Side Plugin Hook: `chat.message` (Plugin V2)

OpenCode's plugin system has a `chat.message` hook that can intercept and react to incoming messages. This is defined in `/packages/plugin/src/index.ts`:

```typescript
interface Hooks {
  "chat.message"?: (
    input: {
      sessionID: string
      agent?: string
      model?: { providerID: string; modelID: string }
      messageID?: string
      variant?: string
    },
    output: { message: UserMessage; parts: Part[] },
  ) => Promise<void>
}
```

**Limitation**: This hook is read-only/transformative — it can observe and modify a message's parts, but cannot inject a standalone message from an external source. It works on messages that are already part of the session flow.

### 2. HTTP API: `/tui/show-toast` and `/tui/publish`

OpenCode exposes REST endpoints for the TUI (Terminal User Interface). The SDK client in `/packages/sdk/js/src/v2/gen/sdk.gen.ts` exposes these methods:

- `client.tui.showToast({ title, message, variant, duration })` — posts to `/tui/show-toast`
- `client.tui.publish({ type, properties })` — posts to `/tui/publish`

The `TuiEvent.ToastShow` event (defined in `/cli/cmd/tui/event.ts`) is:
```typescript
ToastShow: BusEvent.define(
  "tui.toast.show",
  z.object({
    title: z.string().optional(),
    message: z.string(),
    variant: z.enum(["info", "success", "warning", "error"]),
    duration: z.number().default(5000).optional(),
  }),
)
```

**Limitation**: Toasts are ephemeral (5s default), appear at the top-right of the TUI, and are not inserted into the chat message history. An external process could call these endpoints if it has access to the local OpenCode server (default port-based communication), but there is no MCP notification channel for this.

### 3. Session Message API: `POST /session/{sessionID}/message`

OpenCode has a full session message API at `/session/{sessionID}/message` (defined in `/server/routes/session.ts`). You can:

- **Send a user message** to an existing session: `POST /session/{sessionID}/message` with body `{ text: "..." }` — this streams an AI response
- **Send async**: `POST /session/{sessionID}/prompt_async` with `204` return

**Limitation**: This is user message injection (triggers an AI response), not notification injection. You cannot post a message that appears as a bot/assistant message without the AI processing it.

### 4. Plugin Event System

OpenCode plugins can subscribe to a broad set of internal events via the `event` hook:

| Event | Description |
|-------|-------------|
| `session.idle` | Agent turn completed |
| `message.updated` | Message updated |
| `message.part.updated` | Message part updated |
| `tool.execute.before/after` | Tool execution |
| `command.executed` | Command run |
| `permission.asked/replied` | Permission requests |
| `question.asked/replied` | Agent questions |
| `file.edited` | File edited |

These are internal event streams, not external injection points.

### 5. MCP Integration

OpenCode uses the Model Context Protocol (MCP) for tool/prompt/resource access. MCP in OpenCode (defined in `/mcp/index.ts`) converts MCP tools into AI SDK tools and supports streaming. However, MCP itself has no built-in message injection primitive equivalent to `notifications/claude/channel`.

### 6. TUI Plugin API: `api.ui.toast()`

TUI plugins (Solid.js frontend plugins) have access to `api.ui.toast({ message, variant, title, duration })`. This is the same mechanism as the HTTP endpoint, but called from within a TUI plugin.

---

## What OpenCode Does NOT Have

1. **No `notifications/claude/channel` equivalent** — there is no MCP-style notification channel that external processes can use to inject visible messages into the chat stream.

2. **No "bot message" injection** — there is no API to inject a message that appears as an assistant/bot message without going through the LLM. The session message API sends user messages; tool result injection is done by the LLM itself.

3. **No push-style notification for external processes** — an external process would need to call the local HTTP API (requiring local access or network access to the OpenCode server process).

4. **No "injected message" concept** — the `chat.message` hook is for observing/transforming, not injecting new messages from outside the session.

---

## The Closest Equivalent

If you want an external process to leave a visible message in an OpenCode session, the options are:

### Option A: Use the Session Message API (if you want user-message-style injection)

```typescript
// Via SDK client
const client = createOpencodeClient({ baseUrl: "http://localhost:3000" })
// Note: requires authentication and server accessibility
await client.session.prompt({
  sessionID: "your-session-id",
  text: "Hello from external process"
})
```

This sends a user message and gets an AI response. Not what you want if you just want to inject a notification.

### Option B: Use the Toast API (if you want ephemeral notifications)

```typescript
// Via SDK client
await client.tui.showToast({
  message: "External process notification",
  variant: "info",
  duration: 10000
})
```

This shows a toast for 10 seconds in the top-right of the TUI. No message history. Ephemeral.

### Option C: Write a Server Plugin that bridges the notification

A server plugin could:
1. Listen on some external interface (stdin, file, socket, etc.)
2. When external input arrives, call `client.tui.showToast()` or subscribe to a C2C-like mechanism
3. Or, manipulate the session state directly via the SDK

The existing `opencode-x-notif` plugin (in `/home/xertrov/src/opencode-x-notif/`) is a real-world example: it subscribes to `session.idle` and `question.asked` events and triggers desktop notifications via `notify-send` / `osascript`. This is event-driven, not injection-driven.

---

## Architecture Comparison

| Feature | Claude Code | OpenCode |
|---------|------------|----------|
| `notifications/claude/channel` | Yes (MCP notification channel) | No |
| Equivalent message injection | MCP tool with message injection | None |
| Ephemeral toast notifications | MCP `notifications/claude/channel` + rendering | `/tui/show-toast` HTTP API + TUI toast component |
| Session message send | Via MCP tool / SDK | `POST /session/{sessionID}/message` HTTP API |
| Plugin hooks | Tool-based + notification hooks | `chat.message`, `event` hooks |
| MCP integration | Yes (full MCP support) | Yes (MCP tools/prompts/resources) |
| External process bridge | C2C MCP notifications | None (would need custom plugin) |

---

## Key Source Files

- `/home/xertrov/src/opencode/packages/plugin/src/index.ts` — Plugin hooks interface, includes `chat.message` and `event` hooks
- `/home/xertrov/src/opencode/packages/opencode/src/cli/cmd/tui/event.ts` — TUI event definitions (`TuiEvent.ToastShow`, `TuiEvent.PromptAppend`, etc.)
- `/home/xertrov/src/opencode/packages/opencode/src/cli/cmd/tui/ui/toast.tsx` — TUI toast component (renders toasts in top-right)
- `/home/xertrov/src/opencode/packages/opencode/src/cli/cmd/tui/plugin/api.tsx` — TUI plugin API (`api.ui.toast()`)
- `/home/xertrov/src/opencode/packages/opencode/src/server/routes/tui.ts` — HTTP routes: `/tui/show-toast`, `/tui/publish`
- `/home/xertrov/src/opencode/packages/opencode/src/server/routes/session.ts` — Session message API: `POST /session/{sessionID}/message`
- `/home/xertrov/src/opencode/packages/sdk/js/src/v2/gen/sdk.gen.ts` — SDK client with `tui.showToast()`, `tui.publish()`, `session.prompt()`
- `/home/xertrov/src/opencode/packages/opencode/src/mcp/index.ts` — MCP integration (uses MCP SDK for tool/prompt/resource exposure)
- `/home/xertrov/src/opencode-x-notif/` — Example plugin: subscribes to `session.idle` and `question.asked`, triggers OS notifications

---

## Conclusion

OpenCode does not support `notifications/claude/channel` or any equivalent. The closest mechanism is the `POST /tui/show-toast` HTTP API (available via SDK client), which produces an ephemeral toast notification. There is no way to inject a message into the chat history from an external process. A custom server plugin would be needed to bridge from an external notification source (like C2C) into OpenCode's TUI.
