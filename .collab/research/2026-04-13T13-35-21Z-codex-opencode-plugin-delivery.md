# OpenCode Plugin Delivery Research

## Question

Can c2c deliver inbound messages to OpenCode as native user messages through an
OpenCode plugin, instead of using PTY injection?

## Short Answer

Yes. OpenCode's plugin API is the strongest native delivery surface among the
currently tested non-Claude clients. A project or global TypeScript plugin can
run inside OpenCode, receive an SDK client, watch or poll the c2c broker, and
call `client.session.prompt(...)` to insert a real user message into the active
session. This should replace the current OpenCode PTY wake path for managed
OpenCode sessions.

## Sources Checked

- OpenCode plugin docs: https://opencode.ai/docs/plugins/
- OpenCode SDK docs: https://opencode.ai/docs/sdk/
- Local plugin example: `/home/xertrov/src/todoer/.opencode/plugins/todoer.ts`
- Local plugin implementation: `/home/xertrov/src/todoer/src/index.ts`
- Local OpenCode plugin API notes: `/home/xertrov/src/todoer/oc-plugin-info/`
- Existing c2c client notes: `docs/overview.md`, `llms.txt`,
  `.collab/findings/2026-04-13T09-29-00Z-codex-kimi-crush-support-research.md`
- Crush upstream README/config docs: https://github.com/charmbracelet/crush
- Kimi Code docs entrypoint: https://www.kimi-cli.com/

## OpenCode Facts

- Plugins can be loaded from `.opencode/plugins/` for a project or
  `~/.config/opencode/plugins/` globally.
- Plugin files are JavaScript or TypeScript and are loaded at startup.
- The plugin function receives a context object with `project`, `directory`,
  `worktree`, `$`, and `client`.
- The `client` is the OpenCode SDK client.
- OpenCode exposes event hooks including `session.idle`, `session.created`,
  `session.updated`, and `message.updated`.
- The SDK exposes `client.session.prompt({ path, body })`, including
  `body.noReply: true` for context-only insertion and default reply-producing
  prompts for normal user messages.
- Separately, the SDK exposes TUI methods such as
  `client.tui.appendPrompt(...)` and `client.tui.submitPrompt()`, but those
  manipulate the prompt buffer and can collide with a human typing.

## Todoer Example

`todoer` is a good local proof that project plugins work:

- `.opencode/plugins/todoer.ts` exports the plugin implementation from
  `src/index.ts`.
- `src/index.ts` returns `lifecycle.start`, `event`,
  `command.execute.before`, and `experimental.session.compacting` hooks.
- It uses `ctx.client.tui.appendPrompt(...)`, `ctx.client.tui.showToast(...)`,
  and `ctx.client.app.log(...)` through helper wrappers.
- It keeps plugin-local state across events in closure variables.

That shape maps directly to c2c:

- closure state: active session id, delivery queue, delivery-in-progress flag,
  last seen inbox mtime, retry spool path
- lifecycle start: initialize config, register alias if needed, start broker
  watcher/poll loop
- event hook: learn current `sessionID` from `session.*` / `message.*` events
  and flush queued c2c messages when the session becomes idle

## Recommended OpenCode Architecture

### Plugin Files

- `.opencode/plugins/c2c.ts`
- optional `.opencode/package.json` if external dependencies are needed

Avoid dependencies for v1. Bun, Node APIs, OpenCode SDK client, and the local
`c2c` CLI should be enough.

### Config

Use a small config object from env first, then optional JSON:

- `C2C_MCP_SESSION_ID` or `C2C_OPENCODE_SESSION_ID`
- `C2C_MCP_AUTO_REGISTER_ALIAS`
- `C2C_MCP_BROKER_ROOT`
- `C2C_PLUGIN_POLL_INTERVAL_MS`

The managed `run-opencode-inst` launcher already sets most of these. The plugin
should not invent a second identity if the MCP server identity is available.

### Delivery Loop

1. On `lifecycle.start`, find broker root and session id.
2. Start a lightweight watcher:
   - preferred: watch `<broker-root>/<session-id>.inbox.json`
   - fallback: interval poll every 1-2 seconds
3. On change, call the c2c CLI fallback:
   - `c2c poll-inbox --session-id <session-id> --json`
4. Immediately append drained messages to a plugin-local spool before injecting.
5. Deliver spooled messages by calling:
   - `client.session.prompt({ path: { id: activeSessionID }, body: { parts: [...] } })`
6. Remove from spool only after OpenCode accepts the prompt call.
7. If no active session id is known, keep messages spooled and show a toast.

### Prompt Shape

Use the existing c2c envelope as the user message text:

```xml
<c2c event="message" from="storm-ember" alias="opencode-local" source="broker">
hello from the broker
</c2c>
```

Do not use `tui.appendPrompt` + `submitPrompt` for inbound c2c content. That is
native API access, but it still writes into the human prompt buffer and has the
same "Max is typing" collision class as PTY injection.

### Reliability Notes

Current `poll_inbox` drains. A plugin can avoid message loss by writing drained
messages to a local spool before calling `session.prompt`. Longer term, c2c
should add an acked delivery API:

- `peek_inbox`
- `ack_messages(message_ids)`
- retry visibility timeout

That would make plugin delivery fully broker-owned instead of relying on a
plugin-local spool after drain.

## Other Clients

### Codex

Current best path remains the managed notify daemon plus MCP polling. This
Codex environment has rich local skills/plugins, but there is no known stable
Codex CLI plugin hook equivalent to OpenCode's runtime plugin API that can call
"append a user message to this live session" without PTY. Keep Codex on
notify-only wake + `mcp__c2c__poll_inbox` until an official session-message API
or host hook appears.

### Kimi Code

Kimi already supports MCP configuration and has stronger future-native surfaces
than Crush because previous research found ACP and Wire mode. For c2c, the next
non-PTY research target should be Kimi Wire/ACP, not a PTY wake daemon. The
question is whether Wire/ACP can inject a user turn or only operate as a
structured agent transport.

### Crush

Crush supports MCP servers over stdio/http/sse and has project/global JSON
config. I did not find a plugin/session-message injection surface comparable to
OpenCode's plugin SDK. Current best path remains MCP setup plus explicit polling
or managed notify-only PTY wake.

## Implementation Plan

1. Add `c2c_opencode_plugin/` or `.opencode/plugins/c2c.ts` scaffold with a
   minimal plugin.
2. Add a pure delivery module that can be unit-tested without OpenCode:
   config resolution, poll command construction, JSON parse, spool read/write,
   message formatting, debounce.
3. Add plugin integration:
   start loop, learn active session id, call `client.session.prompt`.
4. Update `c2c setup opencode` to install or link the plugin.
5. Update managed OpenCode launcher to prefer plugin delivery and keep PTY wake
   as fallback.
6. Live test with Max typing into OpenCode while a c2c message arrives. The
   message should appear as a separate user turn, not pasted into the prompt
   buffer.

## Recommendation

Proceed with OpenCode plugin delivery as the next OpenCode integration slice.
It is a cleaner native surface than PTY injection, it directly addresses the
"breaks when Max is typing" problem, and the local `todoer` repo already proves
the plugin pattern used by OpenCode.
