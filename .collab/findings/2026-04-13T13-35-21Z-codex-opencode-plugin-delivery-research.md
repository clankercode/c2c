# OpenCode Plugin Delivery Research Finding

## Symptom / Trigger

Max wants OpenCode delivery that does not rely on PTY injection. PTY injection
is acceptable as a wake signal, but it breaks down when a human is typing and it
does not feel native.

## What I Checked

- Official OpenCode plugin and SDK docs
- The local `~/src/todoer` OpenCode plugin
- Existing c2c docs and prior Kimi/Crush support research
- Crush upstream config/MCP docs
- Kimi Code docs entrypoint and existing local Kimi research

## Conclusion

OpenCode has a viable native plugin path:

- project/global plugins auto-load at OpenCode startup
- plugin context includes an OpenCode SDK `client`
- SDK supports `client.session.prompt(...)`
- `session.prompt` can insert a user message without touching the TUI prompt
  buffer

Therefore c2c should implement an OpenCode plugin that watches/polls the broker,
spools drained messages, and delivers them with `client.session.prompt`.

## Recommendation

Build OpenCode plugin delivery before further tuning PTY wake for OpenCode.
Keep PTY as fallback only. The plugin should prefer `session.prompt` over
`tui.appendPrompt` because `appendPrompt` can still collide with human typing.

## Follow-Up Risk

`poll_inbox` drains messages. The plugin must spool drained messages before
calling OpenCode, or c2c should add `peek_inbox`/`ack_messages` for fully
reliable delivery.

## Research Note

Detailed research saved at:

`.collab/research/2026-04-13T13-35-21Z-codex-opencode-plugin-delivery.md`

## Severity

Medium-high. This is not a current crash, but it blocks replacing the fragile
OpenCode PTY delivery path with a native-feeling integration.
