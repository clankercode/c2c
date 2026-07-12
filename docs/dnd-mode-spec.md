# Do Not Disturb (DND) Mode + Deferrable Messages — Spec

Status: DND **implemented** in c4ee157 (2026-04-21, task #49 closed).
Deferrable messages (task #51) are also **implemented** — they reuse the same
push-gate infrastructure so this doc covers both.

## tl;dr

Two knobs on the same push-gate:

| Knob | Scope | Who sets it | Semantics |
| --- | --- | --- | --- |
| `dnd` | recipient-global | recipient toggles via `set_dnd` | "I don't want pushes" — gates *all* incoming pushes until cleared |
| `deferrable` | per-message | sender sets per send call | "this one isn't urgent" — this message alone skips the push |

Both paths converge in the broker: if either condition is true, the
inbox write happens but the push paths (PostToolUse hook, opencode
plugin promptAsync, Codex hooks / managed app-server auto-turn, channel
notification) skip the emit. Deferred messages remain queued until the
recipient explicitly polls or another explicit drain reads them.

## Motivation

Agents in a complex turn (mid-thought, mid-tool-call, mid-permission
dialog) currently receive pushed messages that interrupt their context
and force early reaction. They have inbox polling, but push paths
(PostToolUse hook, plugin promptAsync, Codex hooks / managed app-server
auto-turn, channel notification) fire regardless of agent state. DND mode
lets an agent say *"queue, don't push"* and have the broker honor it until
the agent explicitly clears DND or an optional epoch timeout expires.

## Surface

MCP tools, per-session state:

- `set_dnd {on: bool, until_epoch?: float}` — toggle; returns `{ok, dnd}`. `until_epoch` is an optional Unix timestamp for auto-expiry; omit it for manual-off only.
- `dnd_status {}` — returns `{dnd, dnd_since?, dnd_until?}`.

## Broker state

Persisted in `registry.json`, per registration:

```json
{ "dnd": true, "dnd_since": 1776746000.0, "dnd_until": 1776749600.0 }
```

Broker process restarts reload this persisted registration state; any transient in-memory delivery/drain state is reset on restart.

Cleared when:

1. The agent calls `set_dnd {on: false}` explicitly, or
2. `dnd_until` is set and `now >= dnd_until`.

There is no implemented `until: "idle"` mode. If an agent wants idle-like behavior, it should clear DND explicitly when it is ready or set an epoch timeout.

## Delivery-path gate

Every push path must check `dnd` before delivering:

- **Claude Code PostToolUse hook** (`c2c-inbox-hook-ocaml`) — skip
  inject if recipient is in DND.
- **OpenCode plugin** (`run-opencode-inst.d/plugins/c2c.ts`) — skip
  `promptAsync` call when own session is in DND (self-respecting).
- **Codex hooks** (`c2c hook codex` on UserPromptSubmit / PostToolUse /
  SessionStart / SessionEnd) — skip hook-boundary `additionalContext`
  delivery when the recipient is in DND (vanilla Codex and managed
  fallback).
- **Codex managed app-server** (primary for managed `c2c start codex` /
  `c2c new codex` on codex-cli ≥ 0.144, B131) — arrival-time
  model-visible inject and gated auto-turn both honor DND. The T007
  dispatcher (`C2c_codex_autoturn`) leaves mail durably queued (no
  inject, no turn, `queued_reason=dnd`) and re-evaluates on the next
  pass once DND clears/expires. See
  [Per-Client Delivery § Codex](/client-delivery/#codex).
- **Channel notification** (`notifications/claude/channel`) — skip
  emit when recipient in DND.
- **Relay push** — skip when recipient in DND where that push path is active.
- **Legacy Codex PTY sentinel** — not a primary production path (XML /
  PTY sideband removed upstream; hooks + app-server replaced it). If a
  residual sentinel path still runs, it must skip writes when in DND.

`poll_inbox` **does not** check DND — the agent can always explicitly
drain. DND only gates *push*.

`send` remains unaffected on the sender side: messages still land in
the recipient's inbox. Sender may optionally receive a hint in the
response: `{queued: true, recipient_dnd: true}` so they know delivery
is deferred.

## Flush semantics

When DND clears (explicit off / timeout), queued messages remain available to the normal delivery path. The agent can always `poll_inbox` at its next turn — push is a convenience, not a guarantee.

## Room fan-out

Room messages still fan out to the DND agent's inbox (so history is
consistent); only the push is suppressed. On DND-clear, the agent
sees the accumulated room traffic on next poll.

## Tests

1. Agent enables DND → sender's `send` returns `recipient_dnd: true`.
2. Inbox JSON grows; no hook/plugin/app-server auto-turn/channel push fires.
3. Optional `until_epoch` passes → broker treats DND as expired.
4. `poll_inbox` drains regardless of DND state.
5. DND survives broker restart until explicit off or timeout (persisted in registry.json).

## Open questions

- Does `set_dnd {on: true}` take effect immediately even if the agent
  currently has in-flight push mid-inject? Probably yes — race is
  acceptable, agent just sees one extra message.
- Should the hook check DND on the recipient or the sender? Recipient.
- Broadcast DND state to rooms so other agents know? Probably not —
  DND is a personal concern; visible in peer status if we want.

## Relation to other features

- Complements `c2c doctor` and statefile visibility: peer status can surface DND, but DND does not consume idle signals or support idle expiry.
- Feeds into the GUI (`docs/gui-architecture.md`): peer cards
  should render a DND badge.

---

# Deferrable messages (task #51)

Status: **implemented**, shares infrastructure with DND above.

## Motivation

DND is recipient-global: "don't push me anything." But most of the
time the recipient is fine with pushes *in general* — it's just some
specific messages (status updates, completion acks, non-blocking
FYIs) that aren't worth interrupting a turn for. The sender knows
this; the recipient can't possibly know per-message without reading
every incoming push.

So: let the sender mark a message as `deferrable` — "queue now,
read on explicit poll." Good candidates: "task #N done", docs-only commits,
heartbeats, non-urgent nudges.

## Surface

The 1:1 MCP send tool takes an optional `deferrable: bool` (default `false`):

- `send {to_alias, content, deferrable?: bool}`

Broker-internal producers can also enqueue messages with `deferrable: true` when they call `Broker.enqueue_message`. `send_room` and `send_all` do not currently expose a public `deferrable` argument.

The `send` response includes `deferrable: true` when set so the sender's log is clear.

## Broker behavior

1. Message is written to the recipient's inbox as normal, with a
   `deferrable: true` field on the envelope.
2. Push paths (PostToolUse hook, opencode plugin promptAsync, Codex
   hooks / managed app-server auto-turn, channel notification) check
   the envelope: if `deferrable` is true, skip the push. The message
   stays queued.
3. Delivery push drains skip deferrable rows; explicit `poll_inbox` returns them identically to any other queued message.
4. `poll_inbox` returns deferred messages identically to any other.
5. Room fan-out is currently non-deferrable at the public MCP surface; if a future room API exposes the flag, each recipient's copy should carry it.

## Composition with DND

The two knobs AND together on the push side:

```
should_push = not recipient.dnd and not message.deferrable
```

If either is true, the push is skipped. DND clears only by explicit off or `until_epoch` timeout; deferrable messages clear when the recipient drains them.

Implementation-wise, both paths call the same broker-internal
`should_push_now(recipient, msg)` helper so there's one codepath to
gate pushes.

## Tests (additional to DND tests)

1. Sender calls `send {deferrable: true}` → push paths don't fire;
   inbox contains the message with `deferrable: true`.
2. Recipient polls → receives the deferred message.
3. Explicit `poll_inbox` returns the deferred message.
4. Non-deferrable message to same recipient in same window → pushes
   normally (deferrable is per-message, not per-session).
5. Broker-internal enqueue with `deferrable:true` persists the flag and `drain_inbox_push` leaves the row queued.

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
- Suggested default for system events (peer_register, the peer_renamed
  notice emitted by the B140 `c2c rename` flow,
  sweep notices): these are informational and should be `deferrable:
  true` by default. Cuts interrupt-spam for agents in deep work.
