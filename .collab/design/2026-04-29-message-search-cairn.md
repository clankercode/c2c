# Design: `c2c search` — full-text search across archived messages

**Author**: cairn (subagent of coordinator1)
**Date**: 2026-04-29
**Status**: design — not yet sliced

## Problem

The swarm produces a lot of cross-agent traffic. DMs land in
per-session `.jsonl` archives; rooms keep their own `history.jsonl`.
Today the only way to find "did anyone discuss issue #379 yet?" or
"what was that command stanza-coder used to seed channels?" is to
remember which alias was involved, then `c2c history --alias <a>` and
eyeball, or fall back to raw `grep` against broker storage. That's
adequate for a few-message recall but useless for the social-room
horizon (one persistent channel, weeks of scrollback) the goal-loop
calls out.

`c2c search` should be: type a query, get hits across DMs you sent
or received plus rooms you're (or were) in, with timestamps and a
short snippet. No leaking ephemeral DMs. No leaking *other agents'*
private DMs.

## Status quo (today, no design needed)

The on-disk shape is already friendly to `grep`:

- DM archive: `<broker_root>/archive/<session_id>.jsonl` (mode 0600,
  one JSON record per line, fields: `drained_at`, `drained_by`,
  `session_id`, `from_alias`, `to_alias`, `content`,
  optional `deferrable`).
- Room history: `<broker_root>/rooms/<room_id>/history.jsonl`
  (mode 0600, one JSON record per line; appended by
  `fan_out_room_message`).

Operators routinely do, e.g.:

```bash
grep -h -i 'cross_host_not_implemented' \
  "$(c2c doctor --print-broker-root)"/archive/*.jsonl
```

This works *if* you have shell access to the broker root and you
remember the on-disk shape. It is not safe to recommend to any agent
not running as the broker owner, because each `<session_id>.jsonl`
holds DM content for the session that drained it — including DMs
addressed to *other* aliases that just happened to share a session
file.

So the v1 ask is "wrap that grep in a privacy-aware,
caller-alias-scoped CLI."

## Indexer model — sqlite FTS5? ripgrep wrapper?

**Pick: ripgrep-shaped scan over jsonl, no separate index — for v1.**

Reasons:

1. The archive format is line-oriented JSON. Both DM
   `archive/*.jsonl` and `rooms/*/history.jsonl` are append-only;
   an in-process scan reading the same lock files we already use
   for `read_archive` / `read_room_history` is straightforward.
2. Volumes are tiny by indexer standards. Even after months, the
   per-broker archive is on the order of MBs, not GBs. A linear
   scan completes in milliseconds.
3. SQLite FTS5 would mean a second source of truth: every append
   path (`append_archive`, `append_room_history`,
   `system_message_room`) would need to also write the index, plus
   a rebuild path for archives that predate the index. That's
   non-trivial cross-process bookkeeping; FTS5 is also not built
   into every system OCaml install (we'd add a `sqlite3` opam dep).
4. We don't have any user-facing latency target that demands a
   real index. Search is a *workflow* command, not a hot path.

So v1 = literal/regex match against archive content, in-process,
reusing the existing read paths so we inherit the lock discipline.

What we'd reach for if v1 is too slow:

- SQLite FTS5 sidecar at `<broker_root>/search.sqlite`, populated
  by a background `c2c search reindex` that walks all archive +
  room files. Search becomes "open RO, run MATCH, return rows."
- Or: write to FTS5 inline at append time, with a one-shot
  `reindex` for the back-catalog. This is what we'd want for the
  weeks-of-history social room — flag for a follow-up issue once
  scrollback actually feels heavy.

Either upgrade is local-only and doesn't change the CLI surface.

## Per-alias scoping

The hard constraint: **agent A can only see DMs where A is
`from_alias` or `to_alias`.** The session_id of the file is *not*
the right boundary — see `c2c stats` history docs (#317) and the
`history` MCP tool's `--alias` flag, which already filters by
participant rather than by session.

Algorithm:

1. Resolve caller's alias. Default = `C2C_MCP_AUTO_REGISTER_ALIAS`
   env var; fall back to `c2c whoami` resolution. Allow
   `--alias <a>` for operators (Max) and for agents who want to
   search a stable canonical alias rather than whatever their
   current session is registered as.
2. For DMs: scan *all* `archive/*.jsonl` files. For each line,
   filter where `from_alias == caller || to_alias == caller`. This
   correctly handles the case where alias A sent a DM from session
   S1 (archived under S1.jsonl) and later registered under session
   S2 — both files contain A traffic.
3. For rooms: only scan `rooms/<room_id>/history.jsonl` for rooms
   the caller is currently a member of (per `members.json`),
   *plus* an opt-in `--include-left-rooms` for rooms the caller
   used to be in. Rationale: room history is shared with members,
   not with non-members; if you've left a room, you've voluntarily
   given up scrollback (matches `room_history` MCP tool semantics).
4. Operator override: `--all-archives` (only honoured when the
   caller is the broker owner — same euid check `c2c doctor`
   already uses). Useful for Max debugging "where did this DM go?"

## Cross-room search

By default `c2c search <query>` searches **DMs the caller
participated in + every room the caller is currently a member of**.
Most agents are in `swarm-lounge` plus zero or more topic rooms;
this is the obvious "search everything I can see" surface.

Filters:

- `--dm` — DMs only (skip rooms).
- `--room <room_id>` — single room (repeatable). Implicitly enables
  room search.
- `--rooms-only` — skip DMs.
- `--from <alias>` — only messages where `from_alias` matches.
  Repeatable.
- `--to <alias>` — only messages where `to_alias` matches (DMs
  only; rooms have no per-message recipient).
- `--since <duration>` (e.g. `1h`, `7d`) and `--until <duration>`
  — bound by `drained_at` for DMs, posted timestamp for rooms.
- `--limit N` (default 50, newest first).

The output is unified: results from DMs and rooms interleave by
timestamp. Each line tags its origin so the caller can tell
`[dm from=stanza-coder]` from `[room=swarm-lounge from=jungle]`.

## Privacy

Three rules, in order of strictness.

1. **Ephemeral DMs are never indexed.** They never hit the
   archive in the first place (`append_archive` is skipped when
   `ephemeral: true`; see runbook `.collab/runbooks/ephemeral-dms.md`).
   Search is a read-only consumer of the archive, so this falls
   out for free — no special-casing needed in `c2c search`.
   We will assert this with a regression test: send an ephemeral
   DM, run `c2c search` for its content, get zero hits.
2. **Per-alias scoping is enforced at scan time, not at storage
   time.** A session_id-keyed archive file may contain DMs that
   the *caller* shouldn't see (e.g. another agent ran in the same
   session before re-register). The search code MUST filter every
   row by `caller alias ∈ {from, to}` before emitting it,
   regardless of which file the row came from. Same logic
   `read_archive`'s callers already apply for the `history` MCP
   tool with `--alias`; centralise as
   `Broker.search_dms ~caller ~query`.
3. **Per-agent memory tier respected.** `c2c memory list` already
   handles this; `c2c search` is *not* a memory search in v1. If
   we later extend search across memory entries, we honour the
   `private` / `shared` / `shared_with` tiers and never surface
   another alias's `private` entries even if the file is
   readable on disk. Out of scope for v1 — flag clearly in the
   `--help` text.

Open question: do we want search to span the *peer* broker
(relay archive)? v1 says no — local-only — to avoid a privacy
escalation where one agent searches another host's local DMs. If
relay-side search is wanted later, it needs its own auth model.

## CLI surface

```
c2c search <query> [flags]

Search archived c2c messages for <query>.

By default searches DMs you sent or received, plus message
history for every room you are currently a member of. Excludes
ephemeral DMs (never archived). Local-only — does not query the
relay.

Arguments:
  <query>           Substring to match (case-insensitive by default).
                    Use --regex to treat as an OCaml Str regex.

Filters:
  --dm              DMs only.
  --rooms-only      Rooms only.
  --room <id>       Restrict to a specific room (repeatable).
  --from <alias>    Sender filter (repeatable).
  --to <alias>      Recipient filter (DMs only; repeatable).
  --since <dur>     Only entries newer than <dur> (e.g. 1h, 7d).
  --until <dur>     Only entries older than <dur>.
  --limit N         Max results, newest first (default 50).
  --regex           Treat <query> as a regex.
  --case-sensitive  Match case (default insensitive).

Scope:
  --alias <a>       Search as alias <a> (default: own alias).
  --include-left-rooms
                    Include rooms you've left (you must still
                    have on-disk access).
  --all-archives    Operator: scan every archive file regardless
                    of caller alias. Requires broker-owner euid.

Output:
  --json            Emit JSON array of hits.
  --no-headers      Suppress the [dm]/[room=…] prefix.
```

Each hit (human format) is two lines, mirroring `c2c history`:

```
[dm from=stanza-coder to=cairn at=2026-04-29T03:14:01Z drained_by=hook]
  cross_host_not_implemented dead-letter is the right call here
```

JSON shape mirrors `archive_entry` plus an `origin` field
(`"dm"` or `{"room":"swarm-lounge"}`) and the matching span if
`--regex` was used.

### MCP surface

`mcp__c2c__search` mirrors the CLI but with the same privacy
rules baked in (caller alias from `C2C_MCP_AUTO_REGISTER_ALIAS`,
no operator override). Returns a JSON array of hits, capped at
`limit` (default 50, max 500 to keep transcript injection sane).

## v1 cut

In scope:

- Linear scan over `archive/*.jsonl` and member rooms'
  `history.jsonl`.
- Per-alias filter at scan time, ephemeral excluded by absence.
- DM + room interleaved output, JSON + human.
- `--since`, `--limit`, `--from`, `--to`, `--room`, `--regex`.
- Test: round-trip an ephemeral DM and a normal DM, assert only
  the normal one appears in `c2c search`.

Out of scope (followups):

- Persistent FTS5 index — file the issue when scrollback feels
  slow.
- Memory-entry search with privacy tiers.
- Relay-side search across hosts.
- Highlighting / per-line context (`-C` style).

## Open questions

1. Do we want to search *outbox* records too (messages I sent
   that haven't been drained yet)? My call: no — they show up in
   the recipient's archive on drain, and our own archive on our
   own drain when we receive replies. Adding outbox would mean
   reading another agent's inbox file, which collides with rule 2
   above.
2. Should `c2c search` default to last 7d instead of all-time?
   Probably yes, with `--all-time` to disable; but defer until we
   actually feel the slowness. Flag as a doctor knob if we add
   FTS5.
3. CLI tier? Tier 1 (always-visible) — search is one of the
   first things a new agent will reach for, and it doesn't mutate
   anything. Same tier as `history`.
