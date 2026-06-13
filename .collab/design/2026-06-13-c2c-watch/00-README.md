# `c2c watch` — Live Swarm Browser · Index + Executive Proposal

**Date:** 2026-06-13 · **Status:** DESIGN / SPEC (no implementation) · **Driver:** Max-requested
**Scope:** a new top-level `c2c watch` subcommand — a 3-tab live TUI (Peers · DMs · Rooms) over the broker message layer, with in-tab send. Built **into the OCaml `c2c` binary**, reading the broker in-process and sending in-process.

> This supersedes the earlier `2026-06-13-c2c-tui-review-design/` research, which
> recommended a **standalone Python/Textual** browser. The decisions below
> (D1–D5) were taken **after** that pass and override it: the deliverable is an
> **OCaml subcommand**, **all 3 tabs**, **with send**. The prior research remains
> useful for its data-substrate map and gotcha catalogue; where it conflicts with
> this doc on stack/scope, **this doc wins**.

---

## 1. Decisions resolved (the fixed frame)

- **D1 — broker-message layer, not pane-scraping.** The data substrate is the
  broker's flat JSON/JSONL under one broker-root dir: registrations (Peers),
  per-session archive shards (DMs), room history (Rooms). No tmux
  `capture-pane`, no ANSI-stripping, no scrollback loss. This is the *durable,
  lossless* window the operator has never had.
- **D2 — `c2c watch` as an OCaml subcommand** in the canonical binary. Reads the
  broker **in-process** via the already-exposed `Broker` module
  (`ocaml/c2c_mcp.mli`) — zero shell-outs to `c2c list --json` / `c2c history`,
  and **richer** per-peer data than the JSON projection (the in-process
  `registration` record carries `role`/`dnd`/`compacting`/`last_activity_ts`
  even when the on-disk JSON omits them when unset).
- **D3 — full 3 tabs: Peers · DMs · Rooms.** Not a phased "agents-first" cut —
  all three land in v1.
- **D5 — send is in v1.** Send a DM / post to a room **in-process** via
  `Broker.enqueue_message` / `Broker.send_room` (exactly what `send_cmd` does at
  `ocaml/cli/c2c.ml:510`). No PTY typing, no `c2c send` fork. The send path
  **must surface** the broker's `invalid_arg` rejections (Unknown_alias /
  All_recipients_dead / reserved-system from_alias).

*(D4 — the stale-research "standalone vs subcommand" question — is dissolved by
D2: it is a subcommand.)*

---

## 2. Headline approach

- **TUI library: `lambda-term` 3.4.0** (primary), with **`mosaic` 0.1.0** kept on
  the table as the documented Plan B. lambda-term is the **only RELEASED,
  dependency-stable** TUI lib that installs cleanly on c2c's actual switch (opam
  `c2c`, OCaml 5.4.1). `notty`/`nottui`/`lwd` are **solver-blocked** (released
  notty 0.2.3 caps `ocaml < 5.4`; the master fix is unreleased → would force a
  git `pin-depends` — maintenance debt the swarm pays at every push). `minttea`
  is blocked (riot needs `ocaml < 5.3`). lambda-term is also **lwt-native**
  (c2c is already an lwt app) and org-maintained (ocaml-community), lowering
  bus-factor. Caveat carried into the spec: `LTerm_widget` is self-described
  "not stable" → **pin `lambda-term = 3.4.0` and `zed < 4.0`** in `dune-project`
  and keep all rendering behind a thin c2c module so a future swap (to mosaic, or
  hand-rolled ANSI) is cheap.
- **New module `ocaml/cli/c2c_watch.ml`** exposing `C2c_watch.watch_cmd`,
  appended to the `all_cmds` list at `ocaml/cli/c2c.ml:12321`, added to
  `(modules ...)` in `ocaml/cli/dune:3`. The top-level name `watch` is **free**
  (the existing `watch` is nested under `deliver`, `c2c_deliver_watch.ml:135`)
  and `try_fast_path` (`c2c.ml:12078`) does not intercept it.
- **Tier3** in `command_tier_map ()` (`c2c_commands.ml:20`) — operator-visible,
  **hidden from managed agent sessions** (`tier_visible` shows Tier3 only when
  `not (is_agent_session ())`, keyed off `C2C_MCP_SESSION_ID`). Leaving it
  unmapped would default to Tier2 = visible-to-agents — **wrong** for an
  interactive TUI.
- **Live refresh: poll + mtime**, matching the `c2c deliver --watch` precedent
  (`c2c_deliver_watch.ml:41-103`, a `Unix.select` sleep loop) — NOT inotify.
  Stat the four file classes (registry, `*.inbox.json`, `archive/*.jsonl`,
  `rooms/*/history.jsonl`); re-read on mtime change. inotify is a v2 upgrade only
  if poll latency proves visibly laggy.
- **Two load-bearing data gotchas** (full detail in 01): room messages are
  **double-stored** (untagged in `rooms/<id>/history.jsonl`, and tagged
  `<alias>#<room_id>` in each recipient's archive shard — dedup on the `#room`
  suffix); and `session_id` is **NOT the alias** (UUID *or* alias-string,
  churns across restarts) — key DM shards on `session_id`, label by alias,
  **surface orphan shards** whose session_id is gone from the registry.

---

## 3. Recommended build sequence

- **S1 — Scaffold + Peers tab (read-only).** Add the dep + module + tier entry;
  `Broker.create ~root:(resolve_broker_root ())` then `list_registrations` +
  `registration_liveness_state`. Render the roster (alias, liveness tristate,
  pid, role/last-activity where present). Poll-refresh loop with clean raw-mode
  teardown on quit/SIGINT/SIGTERM. **Pure render function split from the event
  loop from day one** — render to a string buffer so a golden-snapshot test path
  exists before any second tab (agents can't see a real terminal; this is how the
  swarm self-maintains the TUI).
- **S2 — DMs tab (read-only).** Enumerate `*.inbox.json` + `archive/*.jsonl`
  shards keyed by session_id; reuse `C2c_history.format_entry` for rendering;
  **filter out `#room`-tagged archive rows** from the DM view. Show orphan shards
  under their stored alias.
- **S3 — Rooms tab (read-only).** `list_rooms` + `read_room_history` +
  `read_room_members`; treat empty/absent history as the common (not guaranteed)
  case.
- **S4 — Send (D5).** Input line per tab → `Broker.enqueue_message` (DMs) /
  `Broker.send_room` (Rooms), from_alias via the existing `resolve_alias` helper
  (`c2c.ml:149`). **Wrap every send in error handling** and surface
  Unknown_alias / All_recipients_dead / reserved-from_alias rejections in the UI.
- **S5 — Polish.** Tab cycling, scroll, selection-driven detail, copy-id /
  copy-path bindings; expand golden screens.

Each slice is a separate worktree + peer-PASS, per CLAUDE.md git workflow. The
TUI dep enlarges the opam closure (lambda-term pulls 11 pkgs incl. uucp/uuseg) —
**it must NOT trigger a push by itself**; coordinator-gated push discipline
applies.

---

## 4. Remaining open questions (surfaced to Max for sign-off)

- **opam pin freshness — ✅ VALIDATED 2026-06-13 (orchestrator).** Ran
  `opam update`; on the *fresh* index `lambda-term 3.4.0` is still the latest
  (zed 3.2.3) and resolves clean (11 pkgs), and `notty` is still solver-blocked
  (`notty → ocaml < 5.4` vs `ocaml = 5.4.1`) — the block is real, not a
  stale-index artifact. So the pin `lambda-term = 3.4.0` / `zed < 4.0` is
  current. **Remaining call for Max:** exact-version pin vs a constraint range
  (recommend exact, given the "not stable" `LTerm_widget` API).
- **Snapshot/golden harness shape.** The Python/Textual prior art had a mature
  `render_snapshot → export_text → normalize` path + checked-in goldens. An
  OCaml TUI needs its own pure-render-to-string path designed from scratch. What
  WxH normalization + diff format does the swarm standardize on?
- **Liveness cost at scale.** `registration_liveness_state` does a live
  `/proc/<pid>` stat per call. The refresh loop must batch one
  `list_registrations` + liveness pass per tick, not per-peer-per-render.
  Acceptable refresh interval (1s? slower)?
- **DM thread reconstruction.** v1 keys on session_id and shows shards
  individually. Do we want a merged A↔B *conversation* view (map alias→session_id
  via registry, merge both archive files by ts) in v1, or defer to v2? (The
  scout warns an alias-keyed join is unsafe across restarts.)
- **Send identity in an operator shell.** `resolve_alias` needs a registered
  from_alias. The human operator running `c2c watch` from a plain shell has no
  `C2C_MCP_SESSION_ID` → how is the send from_alias chosen (a `--as <alias>`
  flag? a reserved operator identity)?
- **Plan-B trigger.** What concrete friction (zed unicode-width bugs, widget API
  churn) flips us from lambda-term to mosaic, and at which slice is that
  decision cheap to make?

---

## 5. Document map

- **`00-README.md`** (this file) — index + executive proposal.
- **`01-c2c-watch-spec.md`** — concrete spec: OCaml module breakdown, data flow with
  `file:line`, ASCII mockups using REAL data fields, key bindings, send path +
  error surfacing, poll/mtime refresh, render/event split for golden tests.
- **`02`** (deferred) — the §4 open questions are surfaced directly to Max for
  sign-off (this hand-off) rather than expanded into a separate doc; the opam-pin
  and snapshot-harness calls are policy decisions Max makes before B0 starts.

---

## Exec summary

`c2c watch` is a new **OCaml subcommand** (D2) on the canonical binary: a 3-tab
live TUI — **Peers · DMs · Rooms** (D3) — over the **broker message layer** (D1,
flat JSON/JSONL under one broker-root dir), reading **in-process** via the
already-exposed `Broker` module (no shell-outs, richer per-peer data than
`c2c list --json`) and **sending in-process** via `Broker.enqueue_message` /
`send_room` (D5, surfacing the broker's dead/unknown-recipient rejections). The
TUI library is **`lambda-term` 3.4.0** — the only RELEASED, lwt-native,
dependency-stable option on c2c's OCaml 5.4.1 switch (notty/nottui solver-blocked
on a released cap; minttea blocked on riot) — with **`mosaic` 0.1.0** as the
documented Plan B and pinned versions to dodge the "not stable" `LTerm_widget`
API. Integration is small: new `c2c_watch.ml`, one `all_cmds` append
(`c2c.ml:12321`), one dune `(modules)` add, and a `"watch", Tier3` entry to hide
it from agents; the `c2c monitor` blocking-loop pattern is the proof a
long-running interactive subcommand coexists with Cmdliner. Refresh is
**poll + mtime** (the `deliver --watch` precedent), not inotify. **Two
load-bearing gotchas**: room messages are double-stored (dedup on the
`#<room_id>` `to_alias` tag) and DM shards are keyed by **session_id, not alias**
(surface orphans, never assume a 1:1 join). Build sequence: Peers → DMs → Rooms
→ Send → polish, each a separate peer-PASSed slice with a **pure-render-to-string
golden path** designed from S1 so the swarm can self-maintain a TUI no agent can
see. Open calls (in 02): opam-pin freshness, snapshot-harness shape, send
identity in a plain operator shell, and the lambda-term→mosaic Plan-B trigger.
