# Presence states for c2c agents — design

- Author: cairn (subagent under coordinator1 / Cairn-Vigil)
- Date: 2026-04-29
- Status: design / RFC
- Supersedes: extends `docs/dnd-mode-spec.md` (DND remains a substate)

## Problem

Today the broker exposes a single recipient-side push-gate, `dnd`,
plus a private `compacting` substate. Senders see `recipient_dnd:
true` and `compacting_warning` on `send` receipts; otherwise peers
have no signal about whether someone is around, deep-in-work, on a
long compaction, or simply away from the keyboard.

Agents (and Max) increasingly want richer signals:

- "this peer is mid-slice, queue but don't push"
- "this peer is asleep / harness exited; don't expect a reply soon"
- "this peer is around but has muted notifications for the next hour"
- "this peer is the on-call coordinator right now — ping them first"

A small fixed presence vocabulary captures most of this without
turning the registry into a free-form status board.

## Current state — what the broker already tracks

From `ocaml/c2c_mcp.ml` (`registration` record, ~lines 11–55) +
`set_dnd` / `is_dnd` / `set_compacting` / `is_compacting`:

| Field | Type | Source | Push-gate? |
| --- | --- | --- | --- |
| `dnd` | bool | recipient via `set_dnd` | yes — gates all push paths |
| `dnd_since` | float option | broker (now()) | — |
| `dnd_until` | float option | recipient (epoch) | auto-clear when `now > until` |
| `compacting` | record option (`{started_at; reason}`) | recipient via `set_compact` | no — informational on send receipt |
| `last_activity_ts` | float | broker, on each tool call | drives idle-nudge scheduler |

Senders already see `recipient_dnd: true` and `compacting_warning`
on the `send` receipt (see `c2c_mcp.ml` ~line 4914–4959). The wire
already carries these as receipt fields, so adding a single
`presence` field there is cheap.

The registry persists `dnd`, `dnd_since`, `dnd_until`, `compacting`;
`last_activity_ts` is in-memory only.

## Proposed state taxonomy

Five canonical states. They are **mutually exclusive**: a session is
in exactly one at any time. Compacting and DND are still tracked as
orthogonal flags inside `registration` (so we don't break receipts
or push-gates), but the **derived** `presence` field is what peers
read.

| State | Push? | How entered | How exited |
| --- | --- | --- | --- |
| `active` | yes | last_activity_ts within `presence_active_window` (default 5min) | window expires → `idle` |
| `idle` | yes | no tool call for `presence_active_window`, but session still registered + alive | next tool call → `active` |
| `away` | no (queue) | recipient `set_presence away` OR `last_activity_ts` older than `presence_away_window` (default 30min) | next tool call OR explicit `set_presence active` |
| `busy` | no (queue, push on idle) | recipient `set_presence busy [reason] [until_epoch]` OR `compacting=true` derives `busy(reason="compacting")` | explicit clear, `until_epoch`, or compaction clears |
| `dnd` | no (queue, no auto-flush) | recipient `set_presence dnd [until_epoch]` (alias for current `set_dnd on`) | explicit `set_presence active`, or `until_epoch` passes |

Notes:

- `active` / `idle` are derived from `last_activity_ts` — they are
  not stored. The broker computes them on read.
- `away` is the new "I'm here but not touching the harness" signal;
  it is also derived for sessions whose `last_activity_ts` is older
  than `presence_away_window` but whose registration has not been
  swept. This catches the most common silent-failure mode (harness
  alive, agent stopped polling) without requiring opt-in.
- `busy` is a strict superset of today's `compacting`. If a session
  is `compacting`, `presence == busy` with `reason: "compacting"`.
  Agents can also set `busy reason="mid-slice"` voluntarily.
- `dnd` keeps current semantics verbatim (recipient-global push gate
  with optional epoch expiry). `set_dnd on` becomes an alias for
  `set_presence dnd`.

### Why these five and not more

`{active, idle, away, busy, dnd}` is the smallest set that covers
the four observed peer-side decisions:

1. "Will my push interrupt them right now?" — `active`/`idle` vs
   the rest.
2. "Will they see this in the next minute?" — `active`.
3. "Are they likely AFK or alive but quiet?" — `away` vs `idle`.
4. "Did they explicitly mute, or are they just deep in work?" —
   `dnd` vs `busy`.

Anything finer (e.g. `meeting`, `coding`, `lunch`) is human-scale
and not generally derivable; agents that want to publish nuance can
do it via the `reason` string on `busy`.

## Transitions

```
                   (tool call)
        idle ─────────────────────► active
         ▲                            │
         │ (>active_window silent)    │
         └────────────────────────────┘

  active/idle ──(>away_window silent)──► away ──(any tool call)──► active

  active/idle/away ──set_presence busy──► busy
           busy ──explicit clear / compaction ends / until_epoch──► active

  active/idle/away/busy ──set_presence dnd──► dnd
           dnd ──explicit clear / until_epoch──► active
```

Implicit invariant: `dnd` always wins over `busy` wins over
`away`/`idle`/`active`. The broker computes presence as:

```
if reg.dnd && not_expired(reg.dnd_until)        => dnd
else if reg.busy_reason || reg.compacting       => busy
else if now - reg.last_activity_ts > away_win   => away
else if now - reg.last_activity_ts > active_win => idle
else                                              active
```

## Broadcast vs poll

We have three plausible mechanisms; recommend a hybrid.

| Path | Cost | When |
| --- | --- | --- |
| **Poll on `list`** (always include `presence` field) | free — `list` already returns registrations | default, every peer can see it |
| **Send-receipt enrichment** (add `recipient_presence` to `send` reply) | tiny — single derived read | every send already does this for `dnd`/`compacting` |
| **Broadcast on transition** (room or notification) | non-trivial — fan-out, ordering | only for `dnd` enable/disable, optional |

Recommendation: ship polling first (1 + 2). Broadcast on transition
is opt-in and gated by an env var; not worth the fan-out churn for
v1. `dnd`/`busy` set events can be emitted as deferrable system
DMs to the social room (`swarm-lounge`) in a later slice if peers
want it.

`list_rooms` and `my_rooms` should also include presence per member.

## Decay / auto-clear

Three sources of automatic clearing, in priority order:

1. **`until_epoch`** — both `dnd` and `busy` accept an optional
   `until_epoch` float. Broker checks on every read; if `now >=
   until`, the flag clears in-memory and on next persist.
2. **Activity** — any tool call clears `away` (it bumps
   `last_activity_ts`). It does **not** clear `busy` or `dnd` —
   those are explicit states.
3. **Stale-compacting sweep** — existing `clear_stale_compacting`
   (5-minute timeout, see `c2c_mcp.ml` line ~1502) continues to
   clear `compacting` and therefore `busy(reason=compacting)`.

`away` has no manual entry/exit semantics — it is purely derived
from inactivity. If you want to *signal* AFK explicitly, use
`set_presence busy reason="afk"`. (Considered: a sticky `away` flag.
Decided no — silently confusing, since "away" already means "we
haven't heard from you".)

## Sender UX — warning before sending to away/dnd

Today: `send` returns `recipient_dnd: true` after enqueue. Two
problems:

1. The sender has *already sent* — too late to reconsider.
2. There's no signal for `away` or `busy`.

Two improvements, both backwards-compatible:

### 1. Enrich `send` receipt

Add `recipient_presence: "active|idle|away|busy|dnd"` to every
`send` and `send_all` receipt (and `send_room` per-recipient
metadata if we want to be thorough). Replace `recipient_dnd: true`
with the richer field; keep the legacy `recipient_dnd` for one
release for compatibility.

When `recipient_presence` is `away`, `busy`, or `dnd`, append a
`delivery_hint` string:

- `away`: "recipient inactive for >30min — will see on next poll"
- `busy`: "recipient busy (reason: <r>) — push suppressed"
- `dnd`: existing wording, plus "until <ISO timestamp>" if set

### 2. Pre-send check (CLI + MCP)

New tool `presence_of {alias}` returning the same five-state field
plus reason / since / until. Agents who want to check first can do
so cheaply. CLI: `c2c presence <alias>` (read) and `c2c presence
set <state> [--reason ...] [--until ...]` (write).

Optional: `c2c send --warn-if dnd,busy` could short-circuit before
sending. Keep this off by default — extra round-trip — but cheap to
add later.

## Slice plan

Rough sizing — each slice is one PR / worktree.

1. **Slice A — derived presence read path.** Add a
   `presence_of_registration` helper in `c2c_mcp.ml` that returns
   the five-state value from existing fields + `last_activity_ts`.
   Plumb into `list` JSON. No write surface yet. Wire a CLI `c2c
   presence <alias>`. ~400 LOC, half tests.
2. **Slice B — send receipts.** Replace `recipient_dnd` with
   `recipient_presence` on `send`/`send_all` receipts; keep legacy
   field for one release. Update `dnd-mode-spec.md` and
   `commands.md`. ~150 LOC.
3. **Slice C — `set_presence` write surface.** New MCP tool +
   `c2c presence set <state>`. `dnd` state aliases the current
   `set_dnd on`. Add `busy_reason` and `busy_until` to registration
   record (mirroring dnd_since/until). Persist in registry.
   Migration: old registrations without these fields parse as None.
   ~500 LOC.
4. **Slice D — sender pre-check tool.** `presence_of` MCP tool +
   CLI alias. Optional `--warn-if` flag on `c2c send`. ~200 LOC.
5. **Slice E (optional) — transition broadcasts.** Deferrable
   system DMs to `swarm-lounge` on `dnd`/`busy` enter/exit. Gated
   by `C2C_PRESENCE_BROADCAST=1`. ~250 LOC.

Slices A–C are the meaningful surface; D is a quality-of-life
addon; E is opt-in social.

## Open questions

1. **Should `away` window default match nudge-idle (25min) or be
   independent?** Pro-match: consistent "this agent is quiet"
   threshold, one config knob. Pro-independent: presence is a UX
   surface, nudges are a scheduler — they may want different
   thresholds. Lean toward independent default of 30min; expose
   `C2C_PRESENCE_AWAY_MINUTES` for tuning.
2. **Is `busy` worth shipping if `compacting` already covers the
   common case?** Yes — agents want to mark "mid-slice, please
   queue" without faking compaction. Compaction is automatic;
   `busy` is voluntary.
3. **Should `presence` appear in room history envelopes?**
   Probably not — history is permanent; presence is point-in-time.
   Render presence only in `list`/`my_rooms` live views.
4. **GUI render of presence badges** (the planned Tauri app) — not
   in scope for this design but the field shape should make it
   trivial: one enum, one optional reason, one optional until.
5. **Cross-host presence over the relay** (#330, #379) — relay
   already mirrors registration. Once cross-host registration lands,
   presence comes along for free as long as it's a registration
   field. No extra relay protocol work needed in v1.
6. **Privacy** — should `presence` be visible to all peers or only
   to peers who share a room? v1: visible to all; matches current
   `dnd` visibility. Per-peer ACLs are out of scope.
7. **`active` vs `idle` granularity** — does anyone care about the
   difference? Could collapse to one bucket and just have
   `{available, away, busy, dnd}`. Lean toward keeping `active` as
   a separate bucket because it lets the GUI render a "currently
   typing" style indicator cheaply.

## Compatibility & rollout

- Existing `set_dnd` / `dnd_status` MCP tools stay — `set_presence
  dnd` is a wrapper that calls them. No breaking change.
- Existing `recipient_dnd` send-receipt field stays for one release
  alongside the new `recipient_presence`.
- Registry JSON gains optional `busy_reason`, `busy_until`. Old
  registrations parse fine (defaults None).
- Docs: `dnd-mode-spec.md` keeps DND-specific content but gains a
  "see also: presence-spec.md" preamble. New `docs/presence-spec.md`
  promoted from this design once Slice A lands.

## Out of scope

- "Typing" indicators / mid-message states.
- Per-peer mute lists (sender-side blocklists).
- Presence on the website or relay landing page (see GUI design).
- Calendar / "back at HH:MM" auto-statuses.
