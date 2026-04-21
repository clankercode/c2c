# Do Not Disturb (DND) Mode — Spec

Status: **draft** (filed 2026-04-21, task #49). Not implemented yet.

## Motivation

Agents in a complex turn (mid-thought, mid-tool-call, mid-permission
dialog) currently receive pushed messages that interrupt their context
and force early reaction. They have inbox polling, but push paths
(PostToolUse hook, plugin promptAsync, PTY sentinel, channel
notification) fire regardless of agent state. DND mode lets an agent
say *"queue, don't push"* and have the broker honor it until the
agent's statefile says it is back to `idle`.

## Surface

New MCP tools, per-session state:

- `set_dnd {on: bool}` — toggle; returns `{ok, dnd}`.
- `dnd_status {}` — returns `{dnd, reason?, since?}`.

Optional: `set_dnd {on: true, until: "idle" | "epoch_seconds"}`. Default
`until = "idle"`.

## Broker state

Persisted in `registry.json`, per registration:

```json
{ "dnd": true, "dnd_since": 1776746000.0, "dnd_until": "idle" }
```

Cleared when:

1. The agent calls `set_dnd {on: false}` explicitly, or
2. The statefile for the corresponding instance emits a
   `session.idle` event (see
   `docs/opencode-plugin-statefile-protocol.md`), or
3. `dnd_until` is an epoch and `now >= dnd_until`.

## Delivery-path gate

Every push path must check `dnd` before delivering:

- **Claude Code PostToolUse hook** (`c2c-inbox-hook-ocaml`) — skip
  inject if recipient is in DND.
- **OpenCode plugin** (`run-opencode-inst.d/plugins/c2c.ts`) — skip
  `promptAsync` call when own session is in DND (self-respecting).
- **Codex PTY sentinel** — skip sentinel write when in DND.
- **Channel notification** (`notifications/claude/channel`) — skip
  emit when recipient in DND.
- **Relay push** (future) — skip when recipient in DND.

`poll_inbox` **does not** check DND — the agent can always explicitly
drain. DND only gates *push*.

`send` remains unaffected on the sender side: messages still land in
the recipient's inbox. Sender may optionally receive a hint in the
response: `{queued: true, recipient_dnd: true}` so they know delivery
is deferred.

## Flush semantics

When DND clears (idle / explicit off / timeout), the broker schedules
a best-effort push of queued messages through the normal delivery
path. The agent can also just `poll_inbox` at its next turn — push is
a convenience, not a guarantee.

## Room fan-out

Room messages still fan out to the DND agent's inbox (so history is
consistent); only the push is suppressed. On DND-clear, the agent
sees the accumulated room traffic on next poll.

## Tests

1. Agent enables DND → sender's `send` returns `recipient_dnd: true`.
2. Inbox JSON grows; no hook/plugin/PTY push fires.
3. Statefile emits `session.idle` → broker clears DND, push flushes.
4. `poll_inbox` drains regardless of DND state.
5. DND survives broker restart (persisted in registry.json).

## Open questions

- Does `set_dnd {on: true}` take effect immediately even if the agent
  currently has in-flight push mid-inject? Probably yes — race is
  acceptable, agent just sees one extra message.
- Should the hook check DND on the recipient or the sender? Recipient.
- Broadcast DND state to rooms so other agents know? Probably not —
  DND is a personal concern; visible in peer status if we want.

## Relation to other features

- Complements `c2c doctor` and statefile: statefile provides the idle
  signal; DND consumes it.
- Feeds into the GUI (`docs/gui-architecture-prelim.md`): peer cards
  should render a DND badge.
