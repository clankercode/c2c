# #272 — Push-aware heartbeat content

**Author:** stanza-coder · **Created:** 2026-04-26 · **Status:** DRAFT (awaiting coord-PASS before implementation)

## Problem

The c2c-start managed heartbeat sends every target alias the same body:

> Session heartbeat. Poll your C2C inbox and handle any messages.

For agents that already receive inbound messages via push (channel
notifications, e.g. Claude Code with channels enabled), the
"Poll your C2C inbox" instruction is noise — they don't need to call
`poll_inbox`; messages already arrive in their transcript via the
`notifications/claude/channel` MCP method. The heartbeat should still
fire (it's a wake/work trigger), but the body should drop the
poll-inbox phrasing for push-capable agents.

This slice adds the registry-side tracking and uses it in the heartbeat
content path.

## Decisions

### 1. Where the capability lives

**Decision**: extend `registration` with a new optional field
`automated_delivery : bool option`.

- Default: `None` (unknown — pre-Phase compatibility, treat as
  not-push-capable for content selection).
- `Some true` = client negotiated `experimental.claude/channel` in
  initialize.
- `Some false` = client did NOT declare channel support.

Why a new field rather than reusing `client_type`:
- `client_type` is "human" / "agent" / None — orthogonal axis.
- Channel capability is per-client *configuration*, not per-client
  *type* (e.g. Claude Code with channels enabled vs Claude Code
  without — same client_type, different delivery mode).
- Keeps the boolean cleanly testable without parsing a string enum.

Field name `automated_delivery` rather than `channel_capable`:
- "automated" describes the user-visible behavior (messages arrive
  without manual polling), which is what the heartbeat content
  decision actually depends on.
- Future: could expand to other automated paths (Codex PTY sentinel,
  OpenCode plugin) without renaming the field. Today only channel
  notifications qualify as "automated"; the field is forward-compatible.

### 2. Who sets / clears

**Set**: the MCP server's `initialize` handler. When the client
declares `experimental.claude/channel: {}` in capabilities, the
server flips `automated_delivery := Some true` for the current
session's registration. When the client doesn't declare it,
`automated_delivery := Some false`.

This piggybacks on the existing `C2c_capability.negotiated_in_initialize`
function — no new parsing logic, just a registry update.

**Clear**: never explicitly. The field is overwritten on each
`initialize` (i.e. on every new MCP session). When the client
disconnects and re-connects with a different capability set, the new
`initialize` overwrites.

**Do NOT** auto-clear on session-restart paths that don't go through
`initialize` — there are no such paths today. If a client reconnects
without re-doing `initialize`, that's an MCP protocol violation, not
something to defensively handle here.

### 3. Defaults & migration

- Phase 0 registrations (without the field) parse as `None`.
- Heartbeat content function treats `None` as "not push-capable" — the
  conservative default that keeps "Poll your C2C inbox" in the body.
  This means existing managed sessions that haven't yet hit
  `initialize` after upgrade will still get the legacy body for one
  cycle, then flip after their first MCP `initialize` round-trip.
- No registry-format migration needed; field is optional.

### 4. Heartbeat content selection

In `C2c_start.render_heartbeat_content`, after rendering the
configured `message`, look up the target alias's registration:

```
if reg.automated_delivery = Some true then
  "Session heartbeat — pick up the next slice / advance the goal."
else
  "Session heartbeat. Poll your C2C inbox and handle any messages."
```

For commanded heartbeats (those with a `command` to run), the prefix
selection is the same; the command output suffix is unchanged.

Custom configured `message` strings (set via `[heartbeat.foo] message
= "..."` in config.toml) are passed through verbatim — the
push-aware swap only applies when the heartbeat is using the default
message. We don't second-guess operator-authored content.

### 5. Helper API

Pure helpers, exposed in the mli for testing:

```
val automated_delivery_for_alias :
  broker_root:string -> alias:string -> bool option

val heartbeat_body_for_alias :
  broker_root:string -> alias:string -> message:string -> string
(** When `message` is the legacy default, returns the push-aware
    variant for push-capable aliases. Otherwise returns `message`
    unchanged. *)
```

The split keeps the registry lookup testable in isolation and the
content-selection rule testable without a broker.

### 6. Tests

- `automated_delivery_for_alias` returns `None` for unknown alias.
- `automated_delivery_for_alias` returns the stored value after
  registration with `~automated_delivery:(Some true)`.
- `heartbeat_body_for_alias` swaps content when alias is
  push-capable AND message is the legacy default.
- `heartbeat_body_for_alias` passes through when alias is push-capable
  but message is custom (operator authored).
- `heartbeat_body_for_alias` keeps legacy body when alias is not
  push-capable or unknown.
- Integration: registering a session with experimental.claude/channel
  → registration record has `automated_delivery = Some true` after
  initialize.

### 7. Out of scope

- Auto-detecting capability for non-MCP delivery paths (Codex PTY
  sentinel, OpenCode plugin). These could grow their own setters
  later; the field is forward-compatible.
- Per-heartbeat opt-out of the swap. If a heartbeat author wants the
  legacy body even for push agents, they can set a custom `message`
  via config.toml.
- Auto-clearing on plugin downgrade. The field flips on the next
  `initialize`, which is the only safe re-evaluation point.

## Implementation order

1. `registration` field + JSON ser/de + tests for round-trip.
2. `register` setter accepts `?automated_delivery` arg; MCP
   `initialize` handler calls it after capability negotiation.
3. `automated_delivery_for_alias` + `heartbeat_body_for_alias`
   helpers in `c2c_start.ml` + tests.
4. Wire `heartbeat_body_for_alias` into `render_heartbeat_content`.
5. Update `docs/commands.md` and CLAUDE.md envelope-format note if
   either references the heartbeat body.

Open question for coord-PASS: are we OK with the field being
`None`-default and migrating in via `initialize`, or do we want a
synchronous backfill path (e.g. a one-shot "probe each alias"
mechanism)? Backfill adds complexity; recommend the lazy approach.
