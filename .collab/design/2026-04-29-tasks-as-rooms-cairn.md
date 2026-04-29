# Tasks-as-Rooms — Shared Task Management on c2c

**Date:** 2026-04-29
**Author:** cairn-vigil (subagent draft)
**Status:** Design sketch — for coordinator1 review

## Problem

`TaskList` today is per-session and harness-internal — neither the broker
nor peers can see another agent's todos. Coordination happens via DMs and
`swarm-lounge` posts that *describe* work but aren't structured: there is
no canonical "claimed by", no completion signal, no dependency edges, no
way for an idle peer to ask "what's free?". Result: silent dropped slices
(see #325 cherry-pick divergence pattern), duplicate work when two agents
pick up the same finding, and coordinator1 hand-rolling slice tables in
sitreps that go stale within minutes.

We already have a persistent N:N shared surface with append-only history:
**rooms**. The hypothesis: a *task* is a room, *or* a structured
message-in-a-room, with a small state machine layered on top.

## Model — Task as Message-in-Room (recommended)

Two shapes were considered:

| Shape | Pros | Cons |
| --- | --- | --- |
| **A. Task = Room** (one room per task) | Per-task subscription; history is task-scoped; dependencies are room invites | Room sprawl (1k+ tasks → 1k+ rooms); discovery is hard; rooms aren't cheap (member rows, meta files) |
| **B. Task = Structured message in a "tasks/*" room** | Cheap; reuses send/history/tail; one room per board (e.g. `tasks/swarm`, `tasks/relay`) is enough; agents can `tail -f` a board | State updates are derived from message history (event-sourced); need a small replayer to compute "current state" |

Recommendation: **B** with event-sourcing. A task is a sequence of typed
messages in a board room; current state is the fold of those events. This
matches how the room history file already works (JSON-per-line, append-only,
tail-able) and avoids inventing new storage.

A board room is just a room whose ID starts with `tasks/` (e.g.
`tasks/swarm`, `tasks/relay-mesh`). Convention-only — broker doesn't need
to special-case the prefix in v1; it's a UI/CLI hint.

### Event envelope

Tasks-as-events ride on top of `send_room` with a structured `content`
body. A small `task_event` JSON shape:

```json
{ "kind": "task_event",
  "v": 1,
  "task_id": "T-2026-04-29-0001",
  "op": "create" | "claim" | "release" | "progress" | "complete"
       | "block" | "unblock" | "cancel",
  "title": "...",          /* create only */
  "by": "alias",           /* sender — redundant with rm_from_alias but explicit */
  "claimed_by": "alias",   /* claim/release */
  "blocked_on": ["T-..."], /* block */
  "note": "freeform",      /* progress/complete/cancel */
  "ts": 1714...            /* redundant with rm_ts */ }
```

Plain-text room messages stay legal in the same room (humans + agents
chat about tasks alongside the structured events). The CLI/MCP filter
non-`task_event` payloads when computing state.

## State Machine

```
     create
       │
       ▼
  ┌── pending ────claim───▶ in_progress ──complete──▶ completed
  │      ▲                       │
  │      │ release               │ block
  │      │                       ▼
  │      └────unblock────── blocked
  │                              │ cancel
  └─────────────cancel───────────┴──────────▶ cancelled
```

Allowed transitions only — replayer rejects out-of-order events (e.g.
`complete` on a `pending` task without an intervening `claim`). Rejected
events are recorded but don't move state; surfaced via `c2c tasks lint`.

State is a fold over the room's history filtered to `task_event` payloads
for a given `task_id`. No separate task store — the room *is* the store.

## Claim / Release Semantics

**Claim** is cooperative, not exclusive. The room is append-only and we
deliberately do not lock; instead:

- Last-claim-wins by `rm_ts`. If two agents claim the same task within a
  few seconds, the latest wins; the loser sees the newer claim event in
  their next `poll_inbox` and self-releases (or escalates in the room).
- Agents SHOULD `room_history --since=10s` before claiming to reduce
  races (advisory; not enforced).
- A claim has an implicit TTL (default 4h). After TTL, the task is
  considered *stale-claimed* and discoverable as reclaimable. The
  replayer marks state `in_progress (stale)`; any agent may `claim`
  again, which becomes the new active claim. No automatic release event
  is written — staleness is computed at read time so no daemon is needed.
- **Release** is explicit (`c2c tasks release T-...`) and writes a
  `release` event. The replayer drops back to `pending`.

This is enough for the swarm's working pace (slice-sized tasks, ~minutes
to hours). Strong locking (compare-and-swap claim) is deferred — file an
issue if the loose model causes real collisions.

## Cross-Task Blocking Dependencies

A `block` event lists `blocked_on: ["T-other"]`. The replayer walks
the dependency graph at read time:

- A task is *transitively blocked* if any of its `blocked_on` tasks are
  not in `completed` state.
- Cycles are detected and surfaced as a lint warning (`tasks lint`); the
  replayer breaks ties by treating the cycle as `blocked` for all
  members until the human resolves it.
- Cross-board dependencies are allowed (`blocked_on: ["tasks/relay#T-42"]`).
  IDs are room-qualified when not in the same board.

`unblock` either removes a specific entry from `blocked_on` (`unblock
--on T-other`) or clears the list. When all blockers complete, the task
auto-transitions back to `pending` (or `in_progress` if it had been
claimed before being blocked) at read time — no daemon, no event needed.

## Integration with TaskList

The harness `TaskList` tool stays — it's still useful for ephemeral
session-scoped todos (research breadcrumbs, "remember to revert this
flag", etc). Two integration paths:

1. **Mirror, don't merge.** A new `c2c tasks pull --board tasks/swarm
   --mine` command emits a JSON shape compatible with the harness
   `TaskList` import (or just prints a checklist). Agents call it on
   wake and paste/import. Cheap, no harness changes.
2. **Promote.** `c2c tasks promote <task-list-id>` reads the harness
   TaskList (via a hypothetical export) and writes a `create` event to
   a board. Deferred until a harness export exists; not v1.

Recommendation: ship path 1 only in v1. The shared/board surface is the
new primitive; per-session TaskList stays as-is.

## CLI / MCP Surface

CLI:

- `c2c tasks list [--board ID] [--mine|--free|--blocked|--all]`
- `c2c tasks show <task-id>` — full event log + computed state
- `c2c tasks create --board ID --title "..." [--blocked-on T-...]`
- `c2c tasks claim <task-id>`
- `c2c tasks release <task-id>`
- `c2c tasks progress <task-id> --note "..."`
- `c2c tasks block <task-id> --on T-other [--on T-...]`
- `c2c tasks unblock <task-id> [--on T-other]`
- `c2c tasks complete <task-id> [--note "..."]`
- `c2c tasks cancel <task-id> [--note "..."]`
- `c2c tasks lint --board ID` — surfaces invalid transitions, cycles, stale claims
- `c2c tasks tail --board ID` — thin wrapper over `c2c rooms tail tasks/...`
  with task-aware formatting

MCP mirrors: `mcp__c2c__tasks_{list,show,create,claim,release,progress,
block,unblock,complete,cancel}`. All implemented as `send_room` with a
typed payload + a fold over `read_room_history` — no new broker storage.

## Slice Plan

1. **Slice 1 — replayer + read-only CLI.** Define `task_event` JSON,
   write the fold (`Tasks.state_of_history : room_message list -> task_state list`),
   add `c2c tasks list/show` reading from any room. No write surface yet;
   tests use hand-crafted history fixtures. Acceptance: replayer round-
   trips a fixture board through every state transition; lint catches
   invalid orderings and cycles.
2. **Slice 2 — write surface.** Wire `create/claim/release/progress/
   complete/block/unblock/cancel` as `send_room` calls with structured
   content. Convention: board IDs prefixed `tasks/`. Acceptance: end-to-
   end claim → progress → complete on a real board room across two
   tmux peers.
3. **Slice 3 — MCP tool surface.** Mirror the CLI verbs as
   `mcp__c2c__tasks_*` tools. Acceptance: a Claude-Code peer claims a
   task created by a Codex peer via tools only.
4. **Slice 4 — lint + stale-claim TTL surfacing.** Wire stale detection
   into `tasks list --free` so reclaim-eligible tasks surface
   automatically. Acceptance: a stale claim 4h+ old appears under
   `--free` for any peer.
5. **Slice 5 — coordinator board.** Coordinator1 creates `tasks/swarm`
   as the canonical board, dispatches via `tasks create`, and the
   sitrep auto-renders from `tasks list --board tasks/swarm`.
   Acceptance: one full sitrep cycle without hand-edited slice tables.
6. **Slice 6 (deferred) — per-role boards.** `tasks/coders`,
   `tasks/reviewers`, etc., joined alongside role-specific rooms (#392
   adjacent). Out of scope until slice 5 lands.

## Open Questions

1. **Numbering scheme.** `T-YYYY-MM-DD-NNNN` per board, or globally?
   Per-board avoids cross-board allocator coordination and lets boards
   operate independently. Recommend per-board; cross-board references
   use the qualified `tasks/relay#T-42` form.
2. **Edit/retract.** No edit events in v1 — fix typos by `cancel + create`
   or a follow-up `progress` note. Aligns with append-only log.
3. **Privacy.** Boards inherit room visibility (`public` /
   `invite_only`). Sensitive tasks live on an invite-only board.
4. **Volume.** A busy board grows the room history file unboundedly.
   Existing room history rotation/compaction (if any) applies; if not,
   that's a separate broker concern (#?). Not blocking — boards stay
   small at swarm scale.

## Non-Goals

- Strong locking on claim (cooperative is fine for v1).
- Cross-broker / federated boards (relay carries rooms already; this
  rides on top).
- Web UI (the GUI app from the memory note can render boards once shipped).
- Replacing the harness `TaskList` — explicitly complementary.
