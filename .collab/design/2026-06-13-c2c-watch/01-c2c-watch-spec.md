# `c2c watch` — v1 Implementation Spec

**Date:** 2026-06-13 · **Status:** SPEC (no implementation) · **Audience:** c2c maintainer
**Decisions IN (fixed upstream):** D1 = broker **message** layer (not agent reasoning) ·
D2 = **OCaml `c2c watch` subcommand** (not standalone Python) · D3 = **full 3 tabs**
(Peers / DMs / Rooms) · D5 = **include send/act** in v1.

This spec is the contract for building `c2c watch`: a single-binary, in-process,
live, read-and-send TUI over the c2c broker. It supersedes `00`/`01` of the TUI
review (Python/Textual, read-only, phased-to-3-tabs) where they conflict — those
predate the D-decisions. The `03-open-questions-and-corrections.md` factual
corrections are carried forward and treated as authoritative on data shape.

Every load-bearing claim below is grounded in source at `file:line`. No
fabricated data fields appear in any mockup — only fields that exist in the
`registration` / `archive_entry` / `room_message` / `room_info` types are shown.

---

## 1. TUI library + opam/dune changes

### 1.1 Chosen library: **lambda-term 3.4.0** (pinned), mosaic 0.1.0 named fallback

The c2c switch is **OCaml 5.4.1, dune 3.22.2, lwt 6.1.1**. On this exact switch
the solver verdict (dry-run, confirmed against upstream raw opam files):

| Lib | Result on 5.4.1 | Verdict |
|---|---|---|
| **lambda-term 3.4.0** | installs CLEAN (11 pkgs) | **CHOSEN** |
| mosaic 0.1.0 | installs CLEAN (5 pkgs) | **Plan B** (v0.1.0, single-maintainer, non-lwt loop) |
| notty 0.2.3 (latest released) | **FAILS** — capped `ocaml < 5.4` | rejected (would need a git `pin-depends` on unreleased master) |
| nottui / lwd | FAILS (transitively via notty) | rejected |
| minttea 0.0.2 | FAILS — riot needs `ocaml < 5.3` | rejected |

**Why lambda-term:** it is the only *released, dependency-stable* TUI lib that
installs on c2c's actual switch with no git pins; it is **lwt-native** (lwt ≥ 4.2;
c2c is already an lwt app via `lwt.unix` + `cohttp-lwt-unix`, see `ocaml/cli/dune:4`),
so its event loop composes with c2c's async I/O instead of fighting it; it is
maintained under `ocaml-community` (org-owned, low bus-factor); and its widget set
(`LTerm_widget` hbox/vbox/frame/labels + `LTerm_edit`/zed for the send line) covers
every D3/D5 need without hand-rolling a render/event/input/resize/unicode layer.

**Pin exact versions** (the `LTerm_widget` README self-describes as "not stable"):
`lambda-term = 3.4.0`, `zed >= 3.2.0 < 4.0`. Without pins an `opam update` could
silently break the build. **Plan B trigger:** if `LTerm_widget`'s unstable API or
zed's unicode handling causes real friction, switch to mosaic 0.1.0 (richer
table/tree/select widgets + flexbox) — accept its v0.1.0 / single-maintainer /
non-lwt-loop risk *only then*. The render logic MUST sit behind a thin c2c module
(`C2c_watch_render`, §2) so a library swap is cheap.

**Rejected: hand-rolled raw mode.** Feasible (Unix `tcgetattr`/`tcsetattr` compile
clean; `ocaml/Banner.ml:43` `visible_width` already strips CSI for column math;
`ocaml/c2c_posix_stubs.c` is the natural home for a `TIOCGWINSZ` ioctl) but
rebuilding widgets/layout/input/resize from `Banner` primitives is disproportionate
for a 3-tab browser when lambda-term exists.

### 1.2 dune + dune-project + opam changes

```
; ocaml/cli/dune — c2c executable stanza
(executable
  (name c2c)
  (modules ... c2c_watch c2c_watch_state c2c_watch_data c2c_watch_render ...)   ; ADD 4 modules
  (libraries c2c_mcp cmdliner yojson logs unix str lwt.unix cohttp-lwt-unix     ; current line 4
             lambda-term))                                                       ; ADD lambda-term
```

```
; dune-project — add to (package (depends ...))
(lambda-term (= 3.4.0))
(zed (and (>= 3.2.0) (< 4.0)))
```

`Broker` reads need **no new dep** — they come via the already-linked `c2c_mcp`
lib. `Banner` (the `visible_width`/`pad_right` helpers) also already lives in
`c2c_mcp` (`ocaml/dune:32`), reusable from the exe.

> **Pre-pin action:** the local opam repo is ~3 months stale (2026-03-05). Run
> `opam update` before locking the final version; it will NOT unblock released
> notty (the `< 5.4` cap is real on every published version) but may surface a
> newer lambda-term/zed.

> **Push discipline:** adding lambda-term enlarges the opam closure (+uucp/uuseg
> unicode tables ~17.0.0) → longer Railway/Pages build. The TUI dep does **not**
> by itself justify a push (CLAUDE.md coordinator-gate rule). Local `just install`
> validates it; coordinator decides the deploy.

---

## 2. Module breakdown

Four new modules in `ocaml/cli/`, plus a 4-line touch to `c2c.ml` + `c2c_commands.ml`.
The split mirrors the proven render/state separation so a **pure render function**
can be golden-snapshot-tested with no terminal (see §9).

| Module | Responsibility | Key deps |
|---|---|---|
| **`c2c_watch.ml`** | Cmdliner term `C2c_watch.watch_cmd`; owns the lwt main loop, terminal raw-mode setup/teardown, key dispatch → state transitions, wiring the data layer + render + send action. The only module that touches `LTerm`. | lambda-term, `C2c_watch_state`, `C2c_watch_data`, `C2c_watch_render` |
| **`c2c_watch_data.ml`** | **Pure-ish read substrate.** Snapshots all broker state into immutable records: roster (`peer_row list`), DM shards (`dm_shard list` keyed by `session_id`), rooms (`room_view list`). One `Broker.t` handle. Implements the alias↔session_id non-join, the `#room` dedup filter, the empty-room-as-default. Also the **send wrappers** that catch `Invalid_argument`. | `c2c_mcp` (Broker), no LTerm |
| **`c2c_watch_state.ml`** | **Pure state machine.** Holds `{ tab; selected_idx per tab; scroll offsets; focus; input_buffer; status_line; last_error }`. Transition functions `(state -> event -> state)` for every key. NO IO, NO render. | none (pure) |
| **`c2c_watch_render.ml`** | **Pure render.** `render : viewport:(int*int) -> snapshot:Data.snapshot -> state:State.t -> string` (or `LTerm_draw` matrix; the string path is what golden tests assert). Builds the tab bar, the active pane, the status/input line. Reuses `C2c_history.format_timestamp` (`ocaml/cli/c2c_history.ml:10`) and `Banner.visible_width`/`pad_right` for column math. | `c2c_mcp` types, `C2c_history`, `Banner` |

**Why this split is load-bearing:** `c2c_watch_render` + `c2c_watch_state` are pure
and terminal-free, so the snapshot/golden tests (§9) drive them directly. Only
`c2c_watch.ml` imports lambda-term, so a Plan-B swap to mosaic touches one module.

### 2.1 Data layer types (concrete)

```ocaml
(* c2c_watch_data.ml — projections built once per refresh *)
type peer_row = {
  pr_alias        : string;                  (* registration.alias *)
  pr_session_id   : string;                  (* registration.session_id (the join key) *)
  pr_liveness     : C2c_mcp.Broker.liveness_state;  (* Alive | Dead | Unknown — c2c_broker.ml:1407 *)
  pr_role         : string option;           (* registration.role (sparse; None on old rows) *)
  pr_last_activity: float option;            (* registration.last_activity_ts (sparse) *)
  pr_dnd          : bool;                     (* registration.dnd *)
  pr_compacting   : C2c_mcp.compacting option;(* registration.compacting *)
  pr_client_type  : string option;           (* registration.client_type *)
}

type dm_shard = {                            (* one per archive/<session_id>.jsonl shard *)
  ds_session_id   : string;                  (* filename key — NOT the alias *)
  ds_owner_alias  : string option;           (* registry lookup of session_id; None = orphan *)
  ds_entries      : C2c_mcp.Broker.archive_entry list;  (* DM rows only — #room rows filtered out *)
}

type room_view = {
  rv_info    : C2c_mcp.Broker.room_info;                    (* list_rooms row: counts+members+visibility *)
  rv_history : C2c_mcp.Broker.room_message list;            (* read_room_history; [] is the common case *)
}

type snapshot = { peers : peer_row list; shards : dm_shard list; rooms : room_view list; broker_root : string }
```

---

## 3. The three tabs

Top-level layout (every tab): **tab bar** (row 0) · **list pane / detail pane**
(split) · **status + input line** (bottom 2 rows). Tabs cycle with `Tab`/`Shift-Tab`
or `1`/`2`/`3`.

### 3.1 Peers tab — roster + liveness tristate

**Source:** `Broker.list_registrations` (`ocaml/c2c_mcp.mli:300`) →
`registration_liveness_state` per row (`ocaml/c2c_broker.ml:1407`, identical
function backing `c2c list --json`'s tristate at `ocaml/cli/c2c.ml:648-652`:
`Alive→true`, `Dead→false`, `Unknown→null`). **Do NOT reimplement `/proc` liveness.**

Columns use ONLY real `registration` fields (`ocaml/c2c_mcp.mli:49-117`):
`alias`, liveness, `role` (sparse → blank), `last_activity_ts` (sparse → `—`),
`client_type`, `dnd`, `compacting`. The in-process reader gets these even when the
on-disk JSON omitted them (the type carries them; JSON elides when unset). **No
fabricated `role/dnd/compacting` columns** — every column below maps to a field
that exists.

Liveness glyph: `●` Alive (green), `○` Dead (dim), `?` Unknown (yellow). `Unknown`
= `null` = pid unknowable, NOT dead — keep the tristate visible.

```
┌ c2c watch ──── broker: ~/.c2c/repos/e0eb9c317019/broker ──── [P]eers  [D]Ms  [R]ooms ┐
│ PEERS (4)                                                        refreshed 0.6s ago   │
│                                                                                       │
│   alias              live  role          client   last-activity     flags            │
│ ▸ 535implr           ●     coder         claude   2026-06-13 14:02  -                 │
│   wf2-escalation     ?     coordinator   claude   2026-06-13 13:58  -                 │
│   claude-tavi-helio  ○     —             —        —                 -                 │
│   opus1              ○     —             claude   2026-06-13 11:40  dnd                │
│                                                                                       │
│ ● alive  ○ dead  ? unknown(null)        ↑/↓ select · Enter→DM compose · r refresh     │
└───────────────────────────────────────────────────────────────────────────────────┘
```

`—` = sparse field absent on an older registration row (e.g. `claude-tavi-helio`
carries only the minimal set). `?` (wf2-escalation) is `Unknown`, distinct from
`○` dead. `Enter` on a selected peer opens the DM compose line pre-targeted at that
alias (§4).

### 3.2 DMs tab — per-`session_id` shards (no unsafe alias join)

**The non-1:1 problem (must handle, not paper over):** `session_id` is the
inbox/archive **filename key** and is **NOT** the alias. Live proof: shard
`cfef26df-...jsonl` ↔ alias `535implr`; the same alias churns `session_id` across
restarts and aliases can share pids. So **alias→session_id is not a 1:1 join.**

**v1 model = shard browser, label-by-alias, never reconstruct A↔B threads.** List
one row per `archive/<session_id>.jsonl` shard (`Broker.read_archive ~session_id
~limit`, `ocaml/c2c_broker.ml:2427`, returns oldest-first / newest-last; `[]` if
absent). Resolve `session_id → alias` via the registry for the **label only**
(`canonical_alias`/`alias`). Shards whose `session_id` is **absent from
registry.json** are shown explicitly as **orphans** under their stored alias —
this is the churn case the corrections doc flags. The undrained
`<session_id>.inbox.json` queue (`Broker.read_inbox`, `ocaml/c2c_mcp.mli:377`) is
merged in as **in-flight** rows at the tail of the matching shard.

**`#room` dedup filter (in-process, from `ae_to_alias`):** `fan_out_room_message`
(`ocaml/c2c_broker.ml:3406`) writes each recipient's archive row with
`to_alias = "<alias>#<room_id>"` while `rooms/<id>/history.jsonl` stores the
**untagged** copy. So a room message appears twice. **The DMs tab MUST drop any
archive row whose `ae_to_alias` contains `#`** (route those to the Rooms tab).
Rule: `String.contains e.ae_to_alias '#'` → it's a room fan-out copy, exclude here.

Archive entry fields (real): `ae_drained_at`, `ae_from_alias`, `ae_to_alias`,
`ae_content`, `ae_deferrable`, `ae_message_id` (`ocaml/c2c_mcp.mli:409`). Rendering
reuses `C2c_history.format_entry` (`ocaml/cli/c2c_history.ml:26`).

Left = shard list (alias label + session_id short + count + orphan flag); right =
selected shard's entries newest-last.

```
┌ c2c watch ──── broker: ~/.c2c/repos/e0eb9c317019/broker ──── [P]eers  [D]Ms  [R]ooms ┐
│ DMs — shard: 535implr (cfef26df…)  32 entries          [3 shards · 1 orphan]          │
│                                                                                       │
│ shards (3)             │  [2026-06-13 14:02:05] coordinator1 -> 535implr             │
│ ▸ 535implr  cfef26df… 32│  ack — picking up slice S4, will DM SHA on green           │
│   wf2-escal wf2-esc…  18│                                                             │
│   opus1     opus1  ⚠2  │  [2026-06-13 14:02:31] 535implr -> coordinator1            │
│     (orphan: sid gone) │  on it. build clean in worktree, rc=0                       │
│                         │                                                             │
│                         │  ‹in-flight› [undrained] coordinator1 -> 535implr          │
│                         │  one more: bump zed pin before peer-PASS                   │
│                                                                                       │
│ #room rows hidden here (see Rooms)   ↑/↓ shard · j/k scroll · Enter→reply · / search  │
└───────────────────────────────────────────────────────────────────────────────────┘
```

`⚠` on the `opus1` shard marks an **orphan** (its `session_id` is no longer in
`registry.json`). `‹in-flight›` rows are merged-in undrained inbox entries.

### 3.3 Rooms tab — `history.jsonl` canonical, empty as the common case

**Source:** `Broker.list_rooms` (`ocaml/c2c_mcp.mli:524`, `[]` if rooms dir absent)
+ `Broker.read_room_history ~room_id ~limit` (`ocaml/c2c_mcp.mli:501`; `[]` when
`history.jsonl` is absent — **treat empty as the COMMON quiet-broker path**, not an
edge case) + `read_room_members` / member counts already inside `room_info`.

`room_info` real fields (`ocaml/c2c_mcp.mli:522`): `ri_room_id`, `ri_member_count`,
`ri_alive_member_count`, `ri_dead_member_count`, `ri_unknown_member_count`,
`ri_visibility` (Public | Invite_only), `ri_member_details`. `room_message` real
fields (`ocaml/c2c_mcp.mli:137`): `rm_from_alias`, `rm_content`, `rm_ts`.

The room timeline is read from `history.jsonl` (**canonical, untagged**); the
`#room`-tagged archive copies are NOT re-merged here (they'd duplicate history) —
dedup already done by sourcing the canonical file. Member liveness breakdown uses
the `ri_alive/dead/unknown` counts (real tristate).

```
┌ c2c watch ──── broker: ~/.c2c/repos/e0eb9c317019/broker ──── [P]eers  [D]Ms  [R]ooms ┐
│ ROOMS (2) — swarm-lounge  public  2 members (1●/0○/1?)                                 │
│                                                                                       │
│ rooms (2)              │  [2026-06-13 13:40:11] coordinator1                          │
│ ▸ swarm-lounge  pub  2 │  morning swarm — bake-off results in research/, glm51 top   │
│   relay-debug   inv  0 │                                                             │
│                         │  [2026-06-13 13:41:02] 535implr                            │
│                         │  joining — will take the watch-spec slice                  │
│                         │                                                             │
│                         │  (history.jsonl: 4 lines)                                  │
│                         │                                                             │
│ relay-debug → (no history) — empty room is normal     ↑/↓ room · Enter→post · / search│
└───────────────────────────────────────────────────────────────────────────────────┘
```

The `relay-debug` room shows the **empty-room default** explicitly (`(no history)`)
— a quiet broker is the expected state, never an error. `Enter` opens the post
line targeting the selected room (§4, `Broker.send_room`).

---

## 4. SEND path (D5) — in-process Broker call, NOT shell-out

### 4.1 Decision: call `Broker` in-process

`c2c watch` **is the same binary** as `c2c send`. The send path is therefore an
in-process Broker call, **not** a `c2c send` subprocess and **not** PTY/tmux typing:

- **DM:** `C2c_mcp.Broker.enqueue_message broker ~from_alias ~to_alias ~content
  ~ephemeral ()` (`ocaml/c2c_mcp.mli:368`) — exactly what `send_cmd` invokes at
  `ocaml/cli/c2c.ml:510`.
- **Room:** `Broker.send_room ?tag broker ~from_alias ~room_id ~content`
  (`ocaml/c2c_mcp.mli:503`) → returns `send_room_result { sr_delivered_to;
  sr_skipped; sr_ts; sr_warning }`.

**Justification over shell-out:** no fork; same broker root already resolved
(`C2c_utils.resolve_broker_root`, `ocaml/cli/c2c_utils.ml:25`); atomic inbox locks
already handled inside Broker; and we get the structured `send_room_result` /
`Invalid_argument` back directly to surface in the UI. Shelling out to `c2c send`
would reparse the error text and double the broker-root resolution.

> Note: this differs from D5 as worded in the TUI-review (which said "shell out to
> `c2c_tmux.py send`"). That guidance was for **PTY typing into a pane** (agent
> reasoning surface). Broker-**message** send is in-process. PTY/tmux typing is
> explicitly NOT in scope — D1 fixes this to the broker message layer.

### 4.2 `from_alias` resolution

`from_alias` = the watcher's own registered alias, resolved via the existing
`resolve_alias ?override broker` helper (`ocaml/cli/c2c.ml:149`), which maps
`C2C_MCP_SESSION_ID → alias` through `list_registrations`. For the operator's plain
shell (no session id), `c2c watch` exposes a `--from ALIAS` flag (mirrors
`send_cmd`'s `--from`, `ocaml/cli/c2c.ml:394`) — the alias must already be
registered, or `C2C_COORDINATOR=1` to bypass. If neither is set and no alias
resolves, the send line shows a clear "no sender alias — pass --from ALIAS" status
and refuses to send (no silent drop).

### 4.3 Error surfacing (MUST — these raise, do not assume success)

`enqueue_message` raises `Invalid_argument` on:
- **Unknown alias** (`ocaml/c2c_broker.ml:2130`): recipient not registered locally.
- **All recipients dead** (`ocaml/c2c_broker.ml:2137`): `"recipient is not alive: <alias>"`.
- **Reserved system `from_alias`** (`ocaml/c2c_broker.ml:2113`).
- **Self-send** is guarded by `send_cmd` at the CLI level (`ocaml/cli/c2c.ml:504`);
  replicate: refuse when `from_alias = to_alias`.

`send_room` returns `sr_warning = Some _` when the room has 0 members (NOT an
exception — a soft warning to show). The send wrapper in `c2c_watch_data.ml`
catches `Invalid_argument msg` and returns `Error msg`; `c2c_watch.ml` writes it
to the status line in red. **An unguarded send would crash the watcher.**

### 4.4 Input-line UX

Bottom row is an `LTerm_edit`/zed text input. Flow:
1. `Enter` on a selected Peer / shard / room → focus moves to the input line,
   pre-filled prompt `to 535implr ›` (DM) or `#swarm-lounge ›` (room).
2. Type body. `Enter` sends (in-process call). `Esc` cancels, returns focus to list.
3. On success: status line `✓ sent to 535implr` (DM) or
   `✓ posted to #swarm-lounge (delivered 1, skipped 1)` from `sr_delivered_to`/`sr_skipped`.
4. On `Error msg`: status line `✗ <msg>` in red, input retained for edit.
5. After a successful send, trigger an immediate data refresh so the new row shows.

Send is **explicit, single-target, confirmed-by-Enter** — no broadcast, no
multi-select in v1 (keeps the error surface bounded).

---

## 5. Live-update mechanism — poll + mtime (match `c2c deliver --watch`)

**Poll, not inotify, for v1.** `c2c deliver --watch` (`ocaml/cli/c2c_deliver_watch.ml:41-103`)
is already poll-based (`Unix.select [] [] [] interval` sleep loop, `:100`). Follow
that precedent: a refresh tick (default **1.0s**, `--interval` flag) that `stat`s
the four file classes and re-reads only on `mtime` change:

| Watched | Path | Reader |
|---|---|---|
| Roster | `registry.json` | `Broker.list_registrations` |
| DM shards | `archive/*.jsonl` + `<sid>.inbox.json` | `read_archive` / `read_inbox` |
| Room history | `rooms/<id>/history.jsonl` | `read_room_history` |
| Room set/members | `rooms/<id>/{meta,members}.json` | `list_rooms` |

Rationale (carried from research): poll matches the existing deliver-watch model,
avoids the external `inotifywait` subprocess dependency (only the separate
`c2c-deliver-inbox` daemon uses it), and is robust to file churn. The `*.jsonl`
archive/history files are **append-only** (atomic temp+fsync+rename writes) so a
reader always sees whole files and a re-read on mtime is safe.

**lwt integration:** because lambda-term is lwt-native, the refresh tick is an
`Lwt_engine` timer (`Lwt.pick [ LTerm.read_event term; refresh_timer ]`) inside the
event loop — no separate thread, no `c2c monitor`-style `Thread.create`. This is
the structural payoff of choosing the lwt-native lib.

> **inotify is the v2 upgrade**, only if 1s poll latency proves visibly laggy.
> Reserve it; do not build it in v1.

> **Do NOT byte-offset-tail `broker.log`** if an events feed is ever added — it
> rotates at 10 MiB (`Broker_log`, `C2C_BROKER_LOG_MAX_BYTES`) and a naive tail
> drops events across rotation. The `.jsonl` files don't rotate; only they are
> safe to mtime-tail. (Events feed is OUT of v1 scope.)

---

## 6. Key bindings + navigation/focus

Two focus modes: **list focus** (default) and **input focus** (after `Enter` on a
selection). Bindings are deliberately a small, conventional set.

| Key | List focus | Input focus |
|---|---|---|
| `Tab` / `Shift-Tab` | next / prev tab | — |
| `1` `2` `3` | jump to Peers / DMs / Rooms | (literal char) |
| `↑` / `↓` (or `k` / `j`) | move selection in left list | — |
| `PgUp` / `PgDn` (or `Ctrl-u`/`Ctrl-d`) | scroll detail pane | — |
| `Enter` | open compose line targeting selection → **input focus** | **send** (in-process) |
| `Esc` | clear search / dismiss status | cancel compose → **list focus** |
| `/` | start incremental search in active pane | — |
| `r` | force refresh now | — |
| `y` | copy selected `ae_message_id` / `session_id` / `room_id` to clipboard-line | — |
| `q` / `Ctrl-c` | quit (restore terminal — see §10) | — |

`/` search filters the active tab's left list (alias / shard / room substring) and
the detail pane (content substring). `y` writes the selected id to the status line
for copy (no external clipboard dep in v1).

---

## 7. Subcommand registration + tier

### 7.1 Registration (4-line change, zero architectural blockers)

Cmdliner dispatch is **synchronous** — there is no global lwt loop wrapping
`Cmd.eval`; each leaf that needs lwt calls `Lwt_main.run` locally (28+ sites, e.g.
relay serve `ocaml/cli/c2c.ml:4506`). A blocking/looping interactive subcommand is
already proven by `c2c monitor` (`ocaml/cli/c2c.ml:3512`, indefinite loop). `c2c
watch` runs its own `Lwt_main.run` over the lambda-term event loop and returns only
on quit.

1. New module `ocaml/cli/c2c_watch.ml` exposing `C2c_watch.watch_cmd`.
2. Add `c2c_watch c2c_watch_state c2c_watch_data c2c_watch_render` to `(modules …)`
   in `ocaml/cli/dune:3`.
3. Append `C2c_watch.watch_cmd` to the `all_cmds` list at `ocaml/cli/c2c.ml:12321`.
4. Add `"watch", Tier3` to `command_tier_map ()` in `ocaml/cli/c2c_commands.ml:20`.

**Name is free:** the only existing `watch` is the nested `c2c deliver watch`
(`ocaml/cli/c2c_deliver_watch.ml:135`) — no collision with top-level `c2c watch`.
`try_fast_path` (`ocaml/cli/c2c.ml:12078`) intercepts only a fixed allowlist
(help/commands/server-info/completion/skills/get-tmux-location/--version) so
`watch` falls through to normal dispatch — **no change to `try_fast_path`**.

### 7.2 Tier = **Tier3** (operator-visible, agent-hidden)

`tier_visible` (`ocaml/cli/c2c_commands.ml:117-120`) shows Tier1/Tier2 always and
Tier3/Tier4 only when `not (is_agent_session ())`. `is_agent_session`
(`:113-114`) is true iff `C2C_MCP_SESSION_ID` is set — set in managed agent
sessions, unset in the operator's plain shell. So **Tier3 = visible to the human,
hidden from agents**, which is correct: `c2c watch` is a full-screen interactive
operator tool, not an agent-callable command. **Do NOT leave it unmapped** —
unmapped defaults to Tier2 = always-visible-including-agents (`:129`), which would
wrongly expose a raw-mode TUI to managed sessions.

---

## 8. Phased BUILD order (de-risk; v1 is full-featured)

Even though v1 ships all 3 tabs + send, land it in slices so each is
peer-PASS-able and the risky pieces (the new dep, the data joins, the send error
surface, terminal teardown) are isolated.

- **B0 — Dep + skeleton + teardown.** Add lambda-term to dune/dune-project/opam;
  register `c2c watch` (Tier3); a minimal app that opens raw mode, draws one empty
  framed pane, and **cleanly restores the terminal on `q`/`Ctrl-c`/SIGINT** (§10).
  *Ships nothing useful but de-risks the dep solve + the #1 correctness hazard
  (terminal teardown) first.* Golden: a single empty-frame snapshot.
- **B1 — Data layer (pure, no UI).** `c2c_watch_data.ml`: `snapshot` builder over
  `list_registrations` + `read_archive`/`read_inbox` shard enumeration + `list_rooms`/
  `read_room_history`. Implements the `#room` `ae_to_alias` dedup filter, the
  orphan-shard detection, the empty-room default. **Unit-tested against synthetic
  broker fixtures** (§9) — validates the data model against the source format
  *before* any rendering. *Highest-value de-risk: the joins are where the bugs are.*
- **B2 — Peers tab (read).** Render roster + liveness tristate from B1's snapshot.
  Poll+mtime refresh loop (§5). Golden snapshots for populated + quiet broker.
- **B3 — DMs tab (read).** Shard list + detail, orphan badge, in-flight merge,
  `#room` rows hidden. Golden snapshots incl. an orphan-shard fixture.
- **B4 — Rooms tab (read).** Room list + canonical `history.jsonl` timeline +
  member tristate counts + empty-room default. Golden snapshots incl. an
  empty-room fixture (the common case).
- **B5 — Send (DM + room).** Input line, `from_alias` resolution + `--from`, the
  in-process `enqueue_message` / `send_room` calls, **and the full `Invalid_argument`
  / `sr_warning` error surface** (§4.3). Tested via the data-layer send wrappers
  returning `Error msg` (no live broker needed for the error paths). Land last —
  it's the only state-mutating slice.

Read tabs (B2–B4) before send (B5): a read-only browser is independently shippable
and the send error surface is the most failure-prone piece.

---

## 9. Testing an OCaml TUI

The pure render/state split (§2) is what makes this agent-maintainable — no agent
can see a real terminal, so the loop must be a **deterministic plaintext diff**.

- **Golden snapshot tests (primary).** `c2c_watch_render.render` is pure:
  `render ~viewport:(80,24) ~snapshot ~state → string`. A test builds a **synthetic**
  `snapshot` + a `state`, calls `render`, and asserts byte-equality against a
  checked-in golden file. Add a `test_c2c_watch_render` alcotest stanza to
  `ocaml/cli/dune` (mirrors the existing `test_c2c_history` stanza, `dune:38-41`).
  Fixtures must cover: populated broker, **quiet broker (0 alive, empty rooms — the
  corrections-doc reality)**, orphan shard, `#room`-dedup row, sparse-field
  registration row.
- **State-machine unit tests.** `c2c_watch_state` transitions are pure
  `(state, event) → state` — assert tab cycling, selection clamping at list ends,
  focus toggles, search filtering, input buffer edits. No terminal, no IO.
- **Data-layer unit tests.** Build a **synthetic broker dir** in a tmpdir
  (registry.json + archive/*.jsonl + rooms/*/history.jsonl), point `Broker.create
  ~root` at it, assert the `snapshot` projections: tristate mapping, orphan
  detection, `#room` filter, empty-room → `[]`. Reuse the broker-fixture pattern
  from `test_c2c_history`.
- **Live QA (manual, in tmux per CLAUDE.md).** Drive a real `c2c watch` in a tmux
  pane via `scripts/c2c_tmux.py` + `scripts/tui-snapshot.sh`; verify keys, refresh,
  a real send to a live peer, and clean teardown. This is the "tested in the wild"
  gate — required before peer-PASS per CLAUDE.md.

> **Fixture hygiene (MUST):** real `archive/`, inboxes, `keys/` are mode 0600/0700
> and hold real DM content. Golden/data fixtures are **synthetic only** — never
> copy live archive content to a world-readable tmp, or DM content leaks.

---

## 10. Risks + tradeoffs

| Risk | Mitigation |
|---|---|
| **`LTerm_widget` API self-described "not stable"** | Pin `lambda-term = 3.4.0`, `zed < 4.0`; isolate all LTerm use in `c2c_watch.ml` so churn touches one module; Plan-B = mosaic. |
| **Terminal left in raw mode on crash/SIGINT** (the #1 correctness hazard) | `Fun.protect`/lwt-finalizer restores cooked mode + shows cursor on quit AND on SIGINT/SIGTERM; landed in **B0 first** so every later slice inherits it. lambda-term's `LTerm.restore`/mode-stack handles this if wired in the finalizer. |
| **alias↔session_id non-1:1 join** misattributes threads | v1 = shard browser keyed on `session_id`, alias is a display label only, orphans shown explicitly. No A↔B thread reconstruction in v1. |
| **`#room` double-store** shows room chatter in DMs | DMs tab drops every `ae_to_alias` containing `#`; Rooms tab sources canonical untagged `history.jsonl`. Covered by a dedicated golden fixture. |
| **Send raises `Invalid_argument`** (unknown/dead/reserved) | Data-layer send wrapper catches → `Error msg` → red status line. Self-send + no-sender-alias guarded before the call. Never assume success. |
| **`registration_liveness_state` stats `/proc` per call** | Batch one `list_registrations` + liveness pass per refresh tick (not per-peer-per-render). At 1s poll over a small swarm this is cheap. |
| **New opam closure** (+uucp/uuseg) grows Railway/Pages build | TUI dep does not justify a push by itself (coordinator-gate); validate locally via `just install`. |
| **mosaic (Plan B) is v0.1.0 / single-maintainer / non-lwt** | Documented fallback only; choosing it now would foreclose the cheap lwt-shared live path and risks 0.x breakage. Stay on lambda-term unless its widgets bite. |
| **Stale opam repo** (2026-03-05) | `opam update` before locking the pin; will not change the notty/minttea facts. |
| **Live broker state shifts** between sessions | Spec is parametric over broker state (handles BOTH populated and quiet brokers); no mockup asserts a fixed snapshot as ground truth — they illustrate shape, not a live assertion. |

---

## Exec summary

`c2c watch` is a single-binary, lwt-native, **in-process** TUI over the c2c broker
with three live tabs — **Peers** (roster + Alive/Dead/Unknown tristate from
`registration_liveness_state`, `ocaml/c2c_broker.ml:1407`), **DMs** (per-`session_id`
archive **shards** — never an unsafe alias↔session_id join — with orphan shards shown
explicitly and `#room`-tagged rows filtered out), and **Rooms** (canonical
`history.jsonl`, empty-room treated as the common case) — plus **send** (D5) wired
straight to `Broker.enqueue_message` / `Broker.send_room`, not a shell-out, with the
`Invalid_argument`/`sr_warning` error surface explicit. The **library is
lambda-term 3.4.0** (the only released, dependency-stable TUI lib that installs on
c2c's OCaml 5.4.1 switch; notty/nottui/minttea all solver-fail), pinned with
`zed < 4.0`, with **mosaic 0.1.0 as the documented Plan B**. The code is **four new
modules** (`c2c_watch` event loop + lambda-term, `c2c_watch_data` read/send,
`c2c_watch_state` pure state machine, `c2c_watch_render` pure render) plus a 4-line
registration touch (`all_cmds` at `c2c.ml:12321`, `"watch", Tier3` in
`c2c_commands.ml:20` so it's operator-visible / agent-hidden). **Live update is
poll+mtime at 1s** (matching `c2c deliver --watch`, not inotify). Build lands in
**six de-risking slices** (dep+teardown → pure data layer → Peers → DMs → Rooms →
send-last). Testing leans on the **pure render/state split**: deterministic
golden-snapshot + state-machine + synthetic-broker data tests (an agent can review
plaintext diffs since it can't see a terminal), with manual tmux QA as the
"tested-in-the-wild" gate. The decisive correctness risk is **terminal teardown on
crash/SIGINT**, mitigated by landing the restore-on-exit finalizer in slice B0.
