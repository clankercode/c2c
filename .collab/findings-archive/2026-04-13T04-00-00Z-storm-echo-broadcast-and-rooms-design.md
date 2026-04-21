# Broadcast + rooms design sketch

**Author:** storm-echo / c2c-r2-b1
**Date:** 2026-04-13 ~04:00Z
**Status:** design sketch — no code changes in this turn.

## Goal

Land a minimum-viable path for the two topology targets from the
group goal:

1. **1:N broadcast** — one sender, many receivers, best-effort.
   "I want all currently-registered peers to see this status update."
2. **N:N rooms** — a persistent shared channel keyed by a room id.
   "anyone who has joined room X sees anything sent to room X."

These are the last two topologies in the active-goal.md reach list,
and rooms in particular enable the social layer ("sit in a shared
room and reminisce about the bugs we got through together").

## What exists today

- 1:1 broker routing is solid — `send(to_alias, content)` enqueues to
  one inbox. Cross-client (Claude/Codex) and cross-language
  (Python/OCaml) interlocks are live.
- There is no aliasing of a single logical recipient to multiple
  inboxes. If two sessions register with the same alias, the broker
  dedupes on register and keeps only the newest. Sending to `codex`
  goes to exactly one `codex-local` inbox.
- There is no persistent room identity — no notion of "who is in the
  room", no membership list, no broadcast fan-out.
- The survival-guide docs refer to "broadcast if unsure who to ask"
  but that currently just means "send several individual 1:1
  messages".

## Proposal — phase 1: 1:N broadcast

### Wire format

Add one new MCP tool and one CLI verb:

```
mcp__c2c__send_all(from_alias, content, exclude_aliases?: string[])
c2c send-all "<message>" [--exclude <alias>...]
```

Semantics:
- Fan out `content` to every live registration in `registry.json`,
  excluding the sender and any aliases in `exclude_aliases`.
- Per-recipient enqueue reuses `with_inbox_lock` so the existing
  cross-language write lock keeps working.
- Returns `{sent_to: [alias…], skipped: [{alias, reason}], errors: […]}`.
- Non-live registrations are skipped with `reason: "not alive"`
  rather than raising, because a 1:N broadcast shouldn't fail the
  whole call just because one peer died.

### Non-goals for phase 1

- No persistent record of "I broadcast this". That's a job for
  phase 2 (rooms with history).
- No de-dup if the same alias has multiple registrations. The broker
  already dedupes on register, so this is a non-issue right now.
- No ordering guarantees across recipients — the point is fan-out,
  not consistency.

### Why this is worth it on its own

Right now peers reach for `mcp__c2c__list` then loop over aliases
calling `send` N times. It works but pollutes the call log and drops
one peer on the floor if any enqueue errors. A single `send_all`
primitive gets us:
- One call in the tool use log instead of N.
- Atomic-ish (per-inbox-locked) delivery.
- A clean error surface for partial failure.

And the implementation is ~30 lines of OCaml + equivalent Python CLI
+ tests.

## Proposal — phase 2: rooms with persistent history

### Wire format

Two new MCP tools, one new broker file:

```
mcp__c2c__join_room(room_id, alias)
mcp__c2c__leave_room(room_id, alias)
mcp__c2c__send_room(from_alias, room_id, content)
mcp__c2c__list_rooms()
mcp__c2c__room_history(room_id, limit?: int)

c2c init <room_id>
c2c join <room_id>
c2c leave <room_id>
c2c room-send <room_id> <message>
c2c room-history <room_id>
```

### New broker state

```
.git/c2c/mcp/
  rooms/
    <room_id>/
      members.json        # [{alias, session_id, joined_at}]
      history.jsonl       # append-only log {ts, from_alias, content}
      members.lock        # fcntl sidecar
      history.lock        # fcntl sidecar
```

### Semantics

- `join_room`: append `(alias, session_id, joined_at)` to
  `members.json` under `members.lock`. Idempotent per `(alias,
  session_id)`.
- `send_room`: append one line to `history.jsonl` under
  `history.lock`, then fan out by enqueueing a normal message to
  every current member's inbox, with `to_alias = "<alias>@<room>"`
  so the recipient can tell it's a room message.
- `room_history(limit)`: read the last `limit` lines of
  `history.jsonl` without mutating state. Enables the "reminisce
  about the bugs" experience at the end.
- `list_rooms`: list room ids with member counts.

### Why append-only jsonl instead of a "database"

- Same lock discipline as the existing inbox files — we already know
  how to do POSIX `fcntl.lockf` / `Unix.lockf` sidecars cross-language.
- Trivially tails with `tail -f` for debugging.
- No schema migration cost.
- Matches the social-layer "persistent history" requirement for free
  — the log IS the history.

### Membership durability

`members.json` persists across broker restarts, so a session that
`join_room`s once stays a member until explicit `leave_room`. But
`send_room` should still skip non-live members at delivery time so
we don't pile up messages in dead inboxes.

A future `room_sweep` tool can prune members whose session is
permanently dead, analogous to `sweep` for the global registry.

## Naming tension

`send_all` vs `broadcast`: "broadcast" reads more naturally to me, but
"send_all" mirrors the existing `send` verb and is obvious at a glance
in the tool list. I'd go with `send_all` for the MCP tool and
`broadcast` as a CLI alias (`c2c broadcast` / `c2c send-all` both work).

## Ordering

I'd build phase 1 first, standalone. It's small, closes an obvious
gap in the current primitives, and doesn't depend on rooms at all.

Phase 2 (rooms) should only start after phase 1 is live so the
`send_room` fan-out can reuse the same `Broker.send_all` helper.

## Risks / open questions

- **Cross-client compatibility for the new tools.** Codex and OpenCode
  both use MCP tools/call, so new MCP tools show up automatically.
  CLI paths need `c2c_cli.py` updates — watch for conflicts with
  codex, who currently holds locks on c2c_cli.py / c2c_install.py.
- **Room id namespace.** Plain strings for now. Max may want a
  `c2c init` to generate cute room ids the way register generates
  alias pairs. Defer — start with raw strings.
- **Cap on history size.** `history.jsonl` grows forever otherwise.
  Add a simple "keep the last N lines" option in `c2c_sweep` later.
- **Who owns the read cursor?** For phase-1 broadcast, each
  recipient's cursor is their own inbox — no shared cursor. For
  phase-2 rooms, history re-read is a separate tool, not an inbox
  drain, so no cursor either. Good.

## Suggested next step for the swarm

- Ping codex to confirm they're OK with a follow-on c2c_cli.py edit
  for `c2c send-all` once they release their current lock.
- When my OCaml edit window opens: implement phase 1 in
  `Broker.send_all` + `handle_tool_call "send_all"` + tests, then a
  thin wrapper in `c2c_send.py` + `c2c_cli.py` + tests.
- Message Max with "phase 1 broadcast primitive ready for review,
  phase 2 (rooms) needs a go-ahead because it introduces persistent
  on-disk state under .git/c2c/mcp/rooms/".
