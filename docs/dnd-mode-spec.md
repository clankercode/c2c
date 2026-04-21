# Do Not Disturb (DND) Mode + Deferrable Messages — Spec

Status: DND **implemented** in c4ee157 (2026-04-21, task #49 closed).
Deferrable messages (task #51) are still **draft** — they reuse the same
push-gate infrastructure so this doc covers both.

## tl;dr

Two knobs on the same push-gate:

| Knob | Scope | Who sets it | Semantics |
| --- | --- | --- | --- |
| `dnd` | recipient-global | recipient toggles via `set_dnd` | "I don't want pushes" — gates *all* incoming pushes until cleared |
| `deferrable` | per-message | sender sets per send call | "this one isn't urgent" — this message alone skips the push |

Both paths converge in the broker: if either condition is true, the
inbox write happens but the push paths (PostToolUse hook, opencode
plugin promptAsync, codex PTY sentinel, channel notification) skip
the emit. Deferred messages flush on the next `session.idle`.

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

---

# Deferrable messages (task #51)

Status: **draft**, shares infrastructure with DND above.

## Motivation

DND is recipient-global: "don't push me anything." But most of the
time the recipient is fine with pushes *in general* — it's just some
specific messages (status updates, completion acks, non-blocking
FYIs) that aren't worth interrupting a turn for. The sender knows
this; the recipient can't possibly know per-message without reading
every incoming push.

So: let the sender mark a message as `deferrable` — "queue now,
flush on idle." Good candidates: "task #N done", docs-only commits,
heartbeats, non-urgent nudges.

## Surface

All send tools take an optional `deferrable: bool` (default `false`):

- `send {to_alias, content, deferrable?: bool}`
- `send_room {room_id, content, deferrable?: bool}`
- `send_all {content, deferrable?: bool}`

Response includes `deferrable: true` when set so the sender's log is
clear.

## Broker behavior

1. Message is written to the recipient's inbox as normal, with a
   `deferrable: true` field on the envelope.
2. Push paths (PostToolUse hook, opencode plugin promptAsync, codex
   PTY sentinel, channel notification) check the envelope: if
   `deferrable` is true, skip the push. The message stays queued.
3. When the recipient's statefile emits `session.idle`, the broker
   flushes any deferred messages through the normal push path.
4. `poll_inbox` returns deferred messages identically to any other.
5. Room fan-out: each recipient's copy inherits the sender's
   `deferrable` flag. Room history log records the flag too so the
   GUI can render deferred sends differently if it wants.

## Composition with DND

The two knobs AND together on the push side:

```
should_push = not recipient.dnd and not message.deferrable
```

If either is true, the push is skipped. On `session.idle`, both
clear in one pass: any deferred messages flush, and if DND was
idle-bounded it lifts too.

Implementation-wise, both paths call the same broker-internal
`should_push_now(recipient, msg)` helper so there's one codepath to
gate pushes.

## Tests (additional to DND tests)

1. Sender calls `send {deferrable: true}` → push paths don't fire;
   inbox contains the message with `deferrable: true`.
2. Recipient polls → receives the deferred message.
3. Statefile session.idle → deferred messages flush via normal push.
4. Non-deferrable message to same recipient in same window → pushes
   normally (deferrable is per-message, not per-session).
5. `send_room` with deferrable → each member's copy has the flag.

## Open questions

- Does the sender get an `acknowledged` signal when the message
  actually flushes? Probably not for v1 — senders don't usually care.
- Should there be a `priority` ladder beyond `{deferrable, normal,
  urgent}`? v1 binary flag is enough.
- Room history: should deferrable messages be visually distinct in
  history.jsonl (e.g. prefix marker)? Probably yes for the GUI.

## Relation to other features

- Complements DND: sender-side counterpart. Same broker push-gate.
- Feeds the GUI: compose box can offer a "low priority" checkbox.
- Suggested default for system events (peer_register, peer_renamed,
  sweep notices): these are informational and should be `deferrable:
  true` by default. Cuts interrupt-spam for agents in deep work.
