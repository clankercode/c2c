# Design: `c2c agent quota` — swarm-wide quota visibility

**Status:** draft
**Originator:** cairn (subagent of coordinator1)
**Date:** 2026-04-29
**Cross-refs:** `scripts/cc-quota`, `ocaml/cli/c2c_stats.ml`,
`.collab/design/SPEC-agent-stats-command.md`,
`.collab/design/statefile-idle-ema.md`

## 1. Motivation

Today's quota visibility is **per-Claude-instance and local-only**:

- `scripts/cc-quota` reads `~/.claude/sl_out/<uuid>/input.json`, prints
  the local session's `rate_limits.{five_hour,seven_day}.used_percentage`
  + reset times.
- An agent calling `cc-quota` in its own bash sees its own numbers, but
  has **no way to ask the broker** "what's the swarm's headroom right
  now? who is about to hit a wall? am I burning faster than my peers?"
- Coordinators currently eyeball quota by spawning bash in N tmux panes
  or by asking each peer in DM — slow, not machine-readable, doesn't
  trend.

Max flagged this in `~/.codex/history.jsonl` 2026-04-something:

> *"…I would also optionally like to have a command executed in
> conjunction with a heartbeat, eg it would be useful to send API usage
> quota information to coordinator automatically every 15 minutes."*

The two-clause request maps cleanly onto two slices:

1. **Self-serve quota tool** — any agent can ask "how am I doing?"
   via CLI or MCP.
2. **Aggregate broker view** — coordinator (or any peer) can ask
   "how is the swarm doing?" without polling every agent.

This design covers both, with the broker as the natural rendezvous.

## 2. Today's mechanism (recap)

`cc-quota` (bash) flow:

```
stdin or $CLAUDE_SESSION_ID
  → ~/.claude/sl_out/<session_id>/input.json
  → jq .rate_limits.five_hour.used_percentage
  → jq .rate_limits.five_hour.resets_at  (epoch)
  → format: "5h: 42% (resets at 14:30 (2h15m; 55% elapsed))"
```

Equivalent OCaml plumbing for **tokens** already exists in
`c2c_stats.ml`:

- `find_sl_out_uuid_by_alias` (line 56) — alias→UUID resolution by
  scanning `~/.claude/sl_out/*/input.json` for matching `session_name`.
- `get_claude_code_tokens` (line 83) — reads `context_window` and
  `cost` from the same JSON.
- Sibling adapters `get_codex_tokens` (sqlite) and
  `get_opencode_tokens` (oc-plugin-state.json) handle non-Claude
  clients — important for **client parity** (group goal: Codex /
  OpenCode are first-class peers, so they must report quota too).

**The rate_limits sub-object is right next to `context_window` in the
same JSON file but currently unread.** Adding a
`get_claude_code_rate_limits` sibling is ~20 lines.

## 3. Proposed model

### 3.1 Per-alias quota record

Stored on disk under `<broker_root>/quota/<alias>.json`, written by
each agent at:

- session start (one-shot snapshot), and
- every heartbeat tick (4.1m default — see CLAUDE.md "Agent wake-up").

```json
{
  "alias": "stanza-coder",
  "client": "claude-code",
  "session_id": "019dc802-d56b-...",
  "captured_at": 1777200000,
  "five_hour": {
    "used_percentage": 42,
    "resets_at": 1777215000
  },
  "seven_day": {
    "used_percentage": 18,
    "resets_at": 1777699200
  },
  "tokens": {
    "input": 312000,
    "output": 28000,
    "cost_usd": 1.43,
    "source": "claude-code"
  },
  "burn_rate": {
    "tokens_per_min_5m": 850,
    "tokens_per_min_15m": 920,
    "method": "delta-of-snapshots"
  }
}
```

Burn-rate **is computed broker-side** by diffing the last two on-disk
snapshots — agents never need to "calculate" anything; they just dump
their statusline JSON. This means non-Claude clients (Codex, OpenCode)
that don't expose 5h/7d windows still get a usable
`tokens_per_min` and a flagged `five_hour: null` for the rest.

### 3.2 Why the broker, not just per-agent CLI

Three reasons:

1. **Aggregate views need a single reader.** The coordinator wants
   `c2c agent quota --all` to print one table — that requires reading
   every agent's snapshot from one place. The broker root is already
   that place.
2. **The broker can age out stale snapshots.** A 6h-old quota number
   is misleading; the broker drops anything > `2 ×
   C2C_NUDGE_CADENCE_MINUTES`.
3. **MCP exposure is free.** Adding a `quota_summary` field to
   `server_info` (or a new tool) means any MCP-attached agent can ask
   without shelling out. CLI-only would force a bash trip on every
   query.

### 3.3 Estimating burn without Anthropic API calls

**Hard rule: zero per-agent calls to Anthropic for quota.** Every
number we expose comes from data the harness already wrote to disk.

- **5h / 7d windows** — `~/.claude/sl_out/<uuid>/input.json` is updated
  by Claude Code's own statusline pipeline every prompt. We read; we
  do not write. Same JSON `cc-quota` already trusts.
- **Tokens** — same file's `context_window`. Already harvested by
  `c2c_stats.ml`.
- **Burn rate** — local diff of two snapshots. `(tokens_now -
  tokens_5min_ago) / 5min`. EMA optional (see
  `statefile-idle-ema.md` for prior art on the same agent).
- **Codex / OpenCode** — no 5h/7d structure today. Report
  `five_hour: null` and let the burn-rate column carry the signal.

The broker therefore has **no new external dependency**. It is purely
a fan-in of files the harness already produces.

## 4. CLI surface

```bash
c2c agent quota                       # this agent (whichever alias is auto-registered)
c2c agent quota --alias stanza-coder  # one peer
c2c agent quota --all                 # whole swarm, table form
c2c agent quota --all --json          # machine-readable
c2c agent quota --refresh             # force a fresh sl_out read for self
c2c agent quota --watch               # repaint every 30s (TUI-ish)
```

### Sample `--all` output

```
$ c2c agent quota --all
Swarm quota — 2026-04-29 18:42 UTC+10  (snapshots ≤ 4m old)

| alias          | client      | 5h%  | 7d%  | tok/min (15m) | $ this 5h | reset 5h | stale |
|----------------|-------------|------|------|---------------|-----------|----------|-------|
| coordinator1   | claude-code |  62% |  31% |   1.8k        | $4.20     | 22:10    |  0:30 |
| stanza-coder   | claude-code |  44% |  19% |     920       | $1.43     | 22:10    |  1:12 |
| jungle-coder   | claude-code |  78% |  22% |   2.1k        | $5.80     | 22:10    |  0:45 |
| galaxy-coder   | codex       |   —  |   —  |     410       | $0.92     |   —      |  2:01 |
| lyra-quill     | claude-code |  91% |  44% |   3.4k        | $7.10     | 22:10    |  0:18 |

Aggregate: 5h band 44–91% (median 62%); est. swarm burn 8.6k tok/min.
⚠ lyra-quill at 91% 5h — likely to throttle in next ~25min.
```

## 5. MCP surface

Two changes to `c2c_mcp.ml`:

### 5.1 New tool `quota` (preferred)

```json
{ "name": "quota",
  "input": { "scope": "self" | "all" | "alias:<name>" } }
```

Returns the same JSON as `c2c agent quota --json`. Cheaper than
`server_info` for repeated polling and discoverable.

### 5.2 Embed lightweight summary in `server_info`

`server_info_lazy` (c2c_mcp.ml:251) already returns
`{name, version, git_hash, features, runtime_identity}`. Add:

```json
"quota_summary": {
  "self": { "five_hour_pct": 44, "tok_per_min": 920, ... },
  "swarm": { "max_5h_pct": 91, "median_5h_pct": 62, "agents_in_red": 1 }
}
```

This makes quota visible **on every `initialize`** — i.e. cold-boot
and post-compact context injection (#317) will both surface "you were
at 44% 5h before compact". Costs ~500B per initialize; cheap.

## 6. Aggregate views & alerting

### 6.1 Coordinator workflow

A `quota --watch --alert` mode in the coordinator's tmux pane:

- Repaints every 30s.
- Prints a one-line alert into `swarm-lounge` when any agent crosses
  85% 5h or 90% 7d.
- Hands off to existing nudge infrastructure
  (`relay_nudge.ml`-style) — quota alerts are just deferrable DMs to
  the at-risk alias plus a non-deferrable DM to coordinator1.

### 6.2 Sitrep integration

Hourly sitrep (`heartbeat @1h+7m "sitrep tick"`) appends:

```
## Quota
- swarm 5h band: 44–91% (median 62%)
- highest: lyra-quill 91% (resets 22:10, ~25m to throttle)
- 7d band: 19–44% (no concern)
```

Same code path as `c2c stats --append-sitrep`.

## 7. Slice plan

Five slices, ~1 day each. **Slices 1–3 deliver the v1 self-serve tool;
slices 4–5 add aggregate + sitrep.**

### Slice A — `get_claude_code_rate_limits` + write snapshot (#new1)

- New helper in `c2c_stats.ml` (sibling of `get_claude_code_tokens`)
  parsing `rate_limits.five_hour` / `seven_day`.
- Write `<broker_root>/quota/<alias>.json` from a new
  `c2c_quota.ml` module.
- Hook into existing heartbeat tick (no new cron).
- AC: snapshot file appears; matches `cc-quota` output ±1%.

### Slice B — `c2c agent quota` CLI (self only) (#new2)

- New cmdliner subcommand (`agent` group).
- Reads `<broker_root>/quota/<self-alias>.json`, prints one-line.
- `--refresh` triggers Slice A's writer first.
- AC: parity with `cc-quota` for Claude Code; reports `client: codex`
  with `5h/7d: —` for Codex.

### Slice C — Burn-rate (#new3)

- Keep last 4 snapshots per alias (ring buffer in same dir).
- 5m and 15m EMAs computed at read time.
- AC: monotonic input drives strictly-positive `tok/min`; idle agent
  trends to 0 within 15min.

### Slice D — `--all` + MCP `quota` tool (#new4)

- Aggregate reader: glob `<broker_root>/quota/*.json`, drop stale
  (>2× nudge cadence), render table or JSON.
- MCP `quota` tool wired into `tool_definition` table
  (`c2c_mcp.ml` ~line 4271).
- AC: `c2c agent quota --all --json` round-trips through the MCP tool.

### Slice E — Coordinator alerts + sitrep (#new5)

- `--watch --alert` mode dispatches DMs at 85% / 90% thresholds.
- `--append-sitrep` writes the Quota section.
- AC: red-band agent shows up in `swarm-lounge` within 60s; sitrep
  contains the swarm 5h band.

## 8. Open questions

1. **Where does the snapshot live for non-Claude clients?** Codex's
   `state_5.sqlite` doesn't expose a 5h/7d window. Slice A handles
   this by writing `five_hour: null` — but if Codex / OpenCode add
   real quotas later we want the schema to absorb them. The
   `client` field is the discriminator; readers fan out on it.

2. **Privacy / cross-host.** Today everything is local. If we ever
   relay quota numbers between hosts (#379-style cross-host work),
   we may want to coarsen — `tier: red/amber/green` instead of raw
   percentages. Out of scope for v1.

3. **Race on heartbeat write.** Two agents shouldn't write the
   same file. They don't — each writes `<alias>.json`. Same agent
   restarting could collide with itself; use the standard
   `tmpfile + rename` pattern from `c2c_registry.py`.

4. **Should `mcp__c2c__quota` be tier-1 (visible) or tier-0
   (always)?** Given the goal is "any agent can ask any time",
   tier-0 (always-visible) is correct. No CLI nudge needed.

## 9. Non-goals

- Predicting throttle time precisely — we report current %, not
  forecasts.
- Per-tool cost attribution (how much `mcp__c2c__send` costs) — that's
  deeper instrumentation.
- Anthropic billing API integration. We only read what the harness
  has already cached locally.

## 10. Done means

- Any agent (Claude / Codex / OpenCode) can run `c2c agent quota`
  and see their own numbers in <100ms with no network call.
- Coordinator can run `c2c agent quota --all` and see every live
  peer in one table.
- `mcp__c2c__quota` returns the same data, callable from any
  MCP-attached session.
- An hourly sitrep auto-includes a Quota section.
- Lyra at 91% triggers a `swarm-lounge` alert without anyone asking.

---

*Companion in-progress stub:
`.collab/research/SUBAGENT-IN-PROGRESS-quota-awareness.md` — delete or
rename once this design is reviewed and a slice is opened.*
