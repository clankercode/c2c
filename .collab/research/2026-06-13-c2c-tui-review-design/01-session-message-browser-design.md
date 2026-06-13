# Design: c2c Session / Message Browser TUI

Status: RESEARCH / DESIGN — proposal only, do not implement.
Author: design subagent (opus), 2026-06-13
Inputs: 4 scout findings (role-designer surfaces, tmux operator tooling, broker data model, workflow-TUI prior art). Grounded against the live broker on host `xsm` and the workflow-TUI reference under `~/.llm-general/ai-coding/codex/skills/workflow/scripts/`.

---

## 0. Problem statement

The operator (Max) has **no single read-only window into the swarm**. To answer
"who is alive, what did A say to B, what's happening in `swarm-lounge` right now"
they must run four disjoint commands (`c2c list`, `c2c history -a X`, `c2c rooms
history`, `c2c monitor`) and/or scrape ANSI-polluted tmux pane scrollback via
`scripts/c2c_tmux.py peek/capture/grep`. Pane-scraping is lossy (scrollback
window), conflates broker traffic with the agent's own reasoning text, and can't
show an inbox/outbox or room membership at all. The broker already writes every
message to disk as plain JSON — the gap is purely a **unified, live, read-only
presentation layer** over those files.

This design proposes a Python/Textual TUI — `c2c-browser` — that reads the
broker directory directly, renders a three-tab two-pane dashboard (Peers / DMs /
Rooms), and auto-refreshes. It deliberately lifts the workflow-TUI architecture
near-verbatim so it is agent-testable from day one.

**Scope boundary (the cleanest framing from the scouts):** this is the canonical
**READ** surface. `scripts/c2c_tmux.py` remains the canonical **WRITE/DRIVE**
surface (send/keys/enter/launch/restart against real PTYs). The browser must NOT
try to absorb the PTY-driving half — those are different problems (parseable JSON
files vs. live terminals with the extended-keys-off footgun). Send-from-browser,
when it lands, shells out to `c2c send`, never types into a pane.

---

## 1. Operator use-cases (the deliverable, concretely)

| # | Use-case | Today (painful) | With browser |
|---|----------|-----------------|--------------|
| U1 | **Watch the swarm live** — see DMs + room posts + joins/leaves arrive without re-running anything | `c2c monitor` (event ticks only) + N panes | Live-updating dashboard, snapshot-on-open + incremental tail |
| U2 | **Read a DM thread A↔B** — full conversation, both directions, chronological | read `archive/<A_sid>.jsonl` AND `archive/<B_sid>.jsonl`, merge by ts by hand | DMs tab → select peer → merged thread pane |
| U3 | **Read a room** — `swarm-lounge` timeline | `c2c rooms history --room swarm-lounge` (one-shot) | Rooms tab → select room → live `history.jsonl` |
| U4 | **See who's registered / alive** — roster with tristate liveness, role, last-activity | `c2c list` (monochrome, no role/idle) | Peers tab, colored liveness, sorted coordinator-first, idle hint |
| U5 | **Jump to an agent's recent activity** — what did `lyra-quill` last send/receive | `c2c history -a lyra-quill` + grep panes | select peer → detail pane shows merged inbox+archive, newest-first |
| U6 (later) | **Act** — send a DM / open the agent's tmux pane | `c2c send` / `c2c_tmux.py send` | command palette → shell out (see §6 MVP boundary) |

The north-star "social layer" framing (agents reminiscing in a shared room) makes
U3 first-class, not an afterthought: the room timeline is a primary view, not a
sub-mode of DMs.

---

## 2. Data model + live-update mechanism

### 2.1 Source of truth — broker-root directory of flat files

There is **no database and no daemon**. Everything is on disk under the
broker root, resolved (matching `ocaml/c2c_repo_fp.ml:94 resolve_broker_root`):

```
C2C_MCP_BROKER_ROOT                                   (explicit override)
  > $XDG_STATE_HOME/c2c/repos/<fp>/broker             (fp = sha256(remote.origin.url)[:12])
  > $HOME/.c2c/repos/<fp>/broker                       (canonical default)
```

Verified live on host `xsm`:
`/home/xertrov/.local/state/cc-p/c2c/repos/8fef2c369975/broker/`. Confirmed
contents: `registry.json`, `*.inbox.json`, `archive/<sid>.jsonl`,
`rooms/<room_id>/{meta.json,members.json,history.jsonl}`, `broker.log`,
`.leases/<sid>`, `keys/`, `nudge/`.

The browser accepts `--broker-root` and honours `C2C_MCP_BROKER_ROOT`; default
resolution can shell out once to `c2c doctor`/an env read, or reimplement the
4-line fp computation in Python (sha256 of `git config remote.origin.url`).

### 2.2 The five files that matter + their verified shapes

Grounded by direct inspection of the live broker (shapes tolerate missing/legacy
fields — the live registry on `xsm` has records with as few as 4 keys, e.g.
`__connect_verify__` stubs):

| File | Role | Verified keys |
|------|------|---------------|
| `registry.json` | **WHO** + liveness join | JSON array. Full record: `session_id, alias, pid, pid_start_time, registered_at, canonical_alias, role, client_type, last_activity_ts, dnd, compacting, cwd, ...`. **Minimal record: only `session_id, alias, canonical_alias, registered_at`** — `pid`/`role`/`last_activity_ts` may be ABSENT. |
| `<sid>.inbox.json` | **undrained queue** (in-flight, not yet delivered) | JSON array of `{message_id, from_alias, to_alias, content, ts}` |
| `archive/<sid>.jsonl` | **durable DM history** (one obj/line, written on drain) | `{drained_at, drained_by, session_id, from_alias, to_alias, content, message_id}`. `drained_by` seen live: `cli_poll` (also `poll_inbox`/`watcher`). Mode 0600. |
| `rooms/<id>/history.jsonl` | **canonical room timeline** | `{ts, from_alias, content}` per line |
| `rooms/<id>/{meta,members}.json` | room visibility + roster | `meta`: `{visibility, invited_members, created_by}`; `members`: array of member records (may be `[]`) |

`broker.log` (structured events: `nudge_tick`, `WORKTREE_MISMATCH`,
`json_cap_exceeded`) is an **optional Events overlay**, deferred past MVP.

### 2.3 The alias↔session_id join

`registry.json` is the ONLY place alias↔session_id is recorded. To show "DMs for
alias X": map `alias → session_id` via the registry, then read
`archive/<session_id>.jsonl`. **A session_id can have a dead pid but a live
archive** — history outlives the process — so the roster (registry) and the
message store (archive) have independent lifetimes. Index both on load.

### 2.4 THE critical dedup: room messages are double-stored

This is the single most important data-model fact and a naive implementation will
get it wrong. `send_room` (`ocaml/c2c_broker.ml:3406`) fans a copy of every room
message into **each member's inbox** with `to_alias = "<alias>#<room_id>"`, which
on drain lands in that member's `archive/<sid>.jsonl` — **AND** the canonical copy
goes to `rooms/<id>/history.jsonl`. So a single room post appears once in the room
history and once per recipient in the DM archives.

**Rule the browser enforces:**
- The **Rooms view** reads `rooms/<id>/history.jsonl` as canonical. Authoritative, deduped, in-order.
- The **DMs view** reads `archive/<sid>.jsonl` but **filters out any row whose `to_alias` contains `#`** (i.e. `#<room_id>` suffix). Those are room copies, not 1:1 DMs.

Implement as a one-line predicate `is_dm = "#" not in entry["to_alias"]`. This
is the de-dup that turns "all messages everywhere" into "DMs here, rooms there."

### 2.5 Merging into a coherent message timeline (per peer)

For a selected peer X, the detail pane shows a **merged, chronological** stream:

1. **Archived DMs** where X is sender or recipient — read from BOTH
   `archive/<X_sid>.jsonl` (DMs X received) and scan other peers' archives /
   X's own outbound copies. Pragmatic MVP: read `archive/<X_sid>.jsonl` (what X
   received, deduped per §2.4) + for the **thread view** (U2) also read
   `archive/<other_sid>.jsonl` and keep rows where `from_alias == X`. Merge the
   two lists by timestamp.
2. **Undrained inbox** — read `<X_sid>.inbox.json` and prepend as "in-flight
   (undelivered)" rows, visually distinct. Without this, an operator browsing
   "history" misses messages queued-but-not-yet-delivered.
3. Sort by `ts`/`drained_at` ascending; key on `message_id` to de-dup the rare
   case where a message is both in-inbox and just-archived during a refresh race.

A message's logical timestamp = `ts` (inbox) or `drained_at` (archive). These are
close but not identical (`drained_at` is delivery time); for a browse view this is
acceptable. Note for the operator in a footer hint: "DM archive timestamps are
delivery time, not send time."

### 2.6 Live-update mechanism — **poll first, inotify as upgrade path**

Two options exist; recommend **poll at 1s** for MVP, exactly as the workflow TUI
does (`set_interval(1.0, reload_state)`, `workflow_tui_app.py:165`):

- **Poll (chosen for MVP):** every 1.0s, re-stat the broker files; reload any
  whose mtime changed; re-render. The files are small (registry ~1KB, inboxes
  <1KB, archives a few KB). Zero new dependencies, dead-simple, matches prior art
  verbatim, and is trivially deterministic for tests (inject a fixed clock).
  Atomic writes on the broker side (temp+fsync+rename, `write_json_file`) mean a
  poll never sees a torn file.
- **inotify (deferred upgrade):** c2c already ships the proven recipe in
  `ocaml/cli/c2c.ml:3843` — `inotifywait -m -r -e close_write,modify,delete,moved_to
  --format '%e\t%w%f' <broker_root>`, gating startup on the stderr line
  `'Watches established.'` to avoid the events-before-watch-armed race. The
  browser could subprocess this (or Python `inotify_simple`) for push updates
  once 1s-poll latency or CPU proves a problem. Same recipe; reuse verbatim.

**Do NOT model the live layer on `c2c deliver --watch`** — the scout confirmed
`ocaml/cli/c2c_deliver_watch.ml:100` is POLL-based despite CLAUDE.md calling
deliver-watch "inotify-based". The genuine inotify surface is `c2c monitor`.

**Incremental tail of append-logs:** `archive/*.jsonl` and `history.jsonl` are
append-only newline-JSON. Track `(mtime, byte_offset)` per file; on change, read
from the saved offset to EOF, parse new lines, append to the in-memory list.
This is the same position-based tail `c2c_deliver_inbox.ml:130` uses
(`List.length` + drop-already-seen, with an atomic checkpoint sidecar). For a
read-only browser, in-memory `(mtime, offset)` is sufficient — no on-disk
checkpoint needed.

### 2.7 Liveness — tristate, never collapse to a boolean

`registration_liveness_state` (`ocaml/c2c_broker.ml:1407`) returns
`Alive | Dead | Unknown`:
- **Alive** — pid present in `/proc` AND `pid_start_time` matches.
- **Dead** — pid recorded but gone / start-time mismatch.
- **Unknown** — `pid = None` (legacy/foreign client; never had a pid). Docker
  mode swaps `/proc` for `.leases/<sid>` mtime.

`c2c list --json` already does this check and returns `{alias, alive, session_id,
registered_at}` (verified live: 7 rows). For MVP the browser can **shell out to
`c2c list --json`** for the roster + liveness rather than reimplementing the
`/proc` + start-time logic — it's the canonical liveness source and sidesteps the
minimal-registry-record problem (§2.2). The browser still reads `registry.json`
directly for the richer fields (`role`, `last_activity_ts`, `dnd`, `cwd`,
`client_type`) when present, joined on `session_id`.

> `c2c list --json` collapses Unknown→`alive:false` today. To preserve the
> tristate, prefer reading `registry.json` directly and computing liveness in
> Python (pid in `/proc` + start-time from `/proc/<pid>/stat` field 22), falling
> back to `c2c list` only if `/proc` access is unavailable. Surface Unknown
> distinctly (dim cyan) so "never had a pid" ≠ "pid died".

---

## 3. Architecture + stack recommendation

### 3.1 Recommendation: **Python/Textual, reusing the workflow-TUI skeleton**

Pick Python/Textual over an OCaml `c2c watch` subcommand. Justification, weighted:

1. **The browser reads only on-disk JSON the broker already writes.** No
   in-process broker call is needed for READ — `registry.json`, `*.inbox.json`,
   `archive/*.jsonl`, `rooms/*/history.jsonl` are all trivially parseable from
   Python. The OCaml in-process advantage (`Broker.read_archive` etc.) only pays
   off for *writing*, which is out of MVP scope and, when added, shells out to
   `c2c send` anyway.
2. **There is no OCaml TUI to reuse.** `ocaml/cli/dune:4` deps are
   `c2c_mcp cmdliner yojson logs unix str lwt.unix cohttp-lwt-unix` — **no
   notty/lambda-term/nottui anywhere** (grep-clean). An OCaml browser means
   adding a TUI lib to a consensus-critical binary AND hand-writing render+event
   layers in a TUI-poor ecosystem.
3. **The workflow TUI is a mature, drop-in skeleton for exactly this.** Its
   architecture is the killer feature: a layer of **pure render functions** that
   return Rich renderables, consumed by BOTH a deterministic snapshot path AND a
   thin Textual app that owns only state/bindings/timer. This split is what makes
   it agent-testable (the swarm maintains its own browser via plaintext snapshot
   diffs — §7). We lift it near-verbatim.
4. **Zero coupling to the OCaml build; ships today.** A standalone reader can't
   break `c2c`, doesn't need a rebuild+install cycle, and an operator can run it
   against any broker root including other repos' swarms.

**Accepted costs** (state them honestly): (i) a second runtime + a `.venv` with
Textual (mitigated by the re-exec-into-venv pattern, `workflow_tui_app.py:15-21`);
(ii) it READS natively but to ACT it shells out to `c2c send`/`c2c_tmux.py`;
(iii) it is `c2c-browser`, not a `c2c` subcommand. **Reserve an OCaml `c2c watch`
for if/when single-binary distribution or in-process send become hard
requirements** — at which point the pure-render split makes a port mechanical.

### 3.2 Component breakdown

Mirror the workflow-TUI's three-file structure:

```
scripts/browser/
  c2c_browser_data.py     # PURE data layer — no rendering, no Textual
      resolve_broker_root() -> Path
      load_registry(root) -> list[Peer]            # + liveness join
      load_dm_thread(root, alias_a, alias_b) -> list[Msg]   # merged, deduped, §2.4/2.5
      load_peer_stream(root, alias) -> list[Msg]   # inbox + archive merged, DM-only
      load_room(root, room_id) -> list[RoomMsg]    # canonical history.jsonl
      list_rooms(root) -> list[Room]
      now() seam for snapshot determinism            # injectable clock
  c2c_browser_render.py   # PURE render layer — Rich renderables, returns str/Group
      render_dashboard(state, width, height) -> RenderableType   # two-pane grid
      render_peers_pane(...) / render_dm_pane(...) / render_room_pane(...)
      render_snapshot(state, w, h) -> str          # Console(record=True, color_system=None).export_text()
      normalize_snapshot(text, w, h) -> str        # pad/truncate to exact WxH
  c2c_browser_app.py      # THIN Textual App — state, bindings, 1s timer ONLY
      class C2CBrowserApp(App):  BINDINGS=[...]; on_mount: set_interval(1.0, reload)
      reload_state(): re-read changed files via data layer
      update_dashboard(): Static.update(render.render_dashboard(self.state, w, h))
      action_*: nav / tab / filter / copy / (later) send
  c2c_browser_tmux_qa.py  # tmux keystroke QA harness (ports workflow_tui_tmux_qa.py)
  tests/snapshots/*.txt   # checked-in golden screens
  requirements-browser.txt # single line: textual
```

**The App holds ZERO rendering logic** — only `state` (selected tab, selected
peer/room index, filter string, scroll offset), the `BINDINGS` list, and the
refresh timer. All drawing is delegated to `c2c_browser_render`. This is the
non-negotiable architectural rule that keeps snapshots and live views consistent.

**Data flow (one refresh cycle):**

```
set_interval(1.0) fires
  -> reload_state(): for each tracked broker file, stat mtime;
       if changed -> data layer re-reads (full for snapshots, offset-tail for jsonl)
       -> updates self.state (peers / dm_thread / room_msgs)
  -> update_dashboard(): render.render_dashboard(self.state, size.width, size.height)
       -> Static(#dashboard).update(renderable)
```

Snapshot path bypasses Textual entirely:
`render_snapshot(state, W, H)` -> deterministic plaintext at exact WxH -> diff.

---

## 4. ASCII mockups

Three tabs: **Peers** (default), **DMs**, **Rooms**. Two-pane layout (left list +
right detail), `left_width` clamped 40–46 cols, right = remainder — exactly the
workflow-TUI grid (`workflow_tui.py:1760`). Tab bar top, footer key hints bottom.

### 4.1 Peers tab (U4, U5) — roster left, selected agent's recent activity right

```
┌─ c2c browser ── [Peers] · DMs · Rooms ───────── broker: 8fef2c369975 · 14:07:42 ┐
│ PEERS (7)               live  │ lyra-quill  ●alive  coordinator  claude          │
│ ───────────────────────────  │ session: 41ab…9c  pid 88213  cwd ~/src/c2c       │
│▸● coordinator1  coord  120s   │ last activity: 8s ago   dnd:off   compacting:0%  │
│ ● lyra-quill    agent   8s    │ ─────────────────────────────────────────────── │
│ ● mm27-helio    agent  45s    │ RECENT (inbox+archive, newest first)             │
│ ○ glm51-review  agent  dead   │ 14:07:34  → coordinator1                         │
│ ◌ opencode-s1   agent  ?      │   PASS on slice S4, build-clean rc=0 in worktree │
│ ● kimi-forge    agent  12s    │ 14:06:58  ← coordinator1                         │
│ ● gemini-tavi   agent   3s    │   pick up #482 S2, branch from origin/master     │
│                               │ 14:05:10  ⧖ (in-flight) ← mm27-helio             │
│ ● alive ○ dead ◌ unknown      │   pairing on the dedup bug?                      │
│ ▸ = selected · DND = yellow   │ 14:01:22  #swarm-lounge  (room, see Rooms tab)   │
└─ q quit · ↹ tab · j/k move · enter focus · / filter · y copy-id · ? help ───────┘
```

- `●` green alive, `○` dim red dead, `◌` dim cyan **Unknown** (pid=None). DND
  alias rendered yellow; compacting% shown when >0.
- Right pane = `load_peer_stream` (merged inbox+archive, DM-only per §2.4),
  newest-first. `⧖ (in-flight)` = undrained inbox row (§2.5 step 2). Room copies
  are NOT shown here (filtered); a single "see Rooms tab" breadcrumb hints they
  exist.
- Sort: coordinator role first, then alive, then by `last_activity_ts` desc.

### 4.2 DMs tab (U2) — peer list left, merged A↔B thread right

```
┌─ c2c browser ── Peers · [DMs] · Rooms ──────────────── thread view · 14:07:50 ┐
│ DM PEERS               unread │ coordinator1 ↔ lyra-quill        (you: operator) │
│ ───────────────────────────  │ ───────────────────────────────────────────────│
│  coordinator1 ↔ lyra-quill  2 │ 14:01:09  coordinator1 → lyra-quill              │
│▸ coordinator1 ↔ mm27-helio    │   take #482 S2; chain-slice off S1, base = local │
│  lyra-quill   ↔ mm27-helio  1 │   master tip after confirming S1 landed          │
│  kimi-forge   ↔ coordinator1  │                                                  │
│  gemini-tavi  ↔ lyra-quill    │ 14:03:44  lyra-quill → coordinator1              │
│                               │   confirmed S1 at cfc04f78, branching now        │
│ filter: /coord ───────────    │                                                  │
│                               │ 14:06:58  coordinator1 → lyra-quill   ⧖ in-flight│
│ (merged from both archives    │   one more: rebase guard tripped in main tree?   │
│  + inboxes, deduped by msg_id)│   ← undrained in lyra-quill's inbox              │
└─ q quit · ↹ tab · j/k move · enter focus · / filter peer · ctrl+y copy-json ───┘
```

- Each list row is a **conversation** (A↔B pair), not a session. Built by scanning
  archives, grouping `frozenset({from_alias, to_alias})`, excluding `#room` rows.
- Thread = merge of `archive/<A_sid>.jsonl` ⋃ `archive/<B_sid>.jsonl` ⋃ both
  inboxes, deduped by `message_id`, sorted ascending (§2.5). This is the
  **conversation abstraction the broker lacks** — derived purely from existing files.
- `unread` badge = count of undrained inbox rows for that pair.

### 4.3 Rooms tab (U3) — room list left, canonical timeline right

```
┌─ c2c browser ── Peers · DMs · [Rooms] ──────────────── live tail · 14:08:01 ──┐
│ ROOMS (1)            members  │ #swarm-lounge   public   members: 6 (5●1○)      │
│ ───────────────────────────  │ created by mm27-roomtest                         │
│▸ swarm-lounge  6  ●●●●●○      │ ─────────────────────────────────────────────── │
│                               │ 14:05:10  mm27-helio                             │
│                               │   dedup bug squashed — archive #room filter lands│
│  (canonical: rooms/<id>/      │ 14:06:20  lyra-quill                             │
│   history.jsonl — NOT the     │   nice. coordinator1 you seeing this in browser? │
│   per-recipient archive       │ 14:07:55  coordinator1                           │
│   copies — those are deduped) │   yep, live tail working. social layer is real  │
│                               │ ▁▁▁ new since open ▁▁▁                           │
│                               │ 14:08:01  kimi-forge                            │
│                               │   first time i can read the room without a pane │
└─ q quit · ↹ tab · j/k scroll · g/G top/bottom · enter focus · ? help ──────────┘
```

- Reads `rooms/<id>/history.jsonl` only (canonical, §2.4). Member breakdown
  (`●` alive `○` dead) from `members.json` joined to registry liveness.
- `▁▁▁ new since open ▁▁▁` watermark marks messages arrived during this session
  (live tail). Auto-scrolls to bottom unless the operator has scrolled up.

### 4.4 Navigation / focus model

- **Tabs**: `Tab`/`Shift-Tab` or `←`/`→` cycle Peers → DMs → Rooms. Per-tab
  selection index is **preserved across tab switches** (capture/restore selection
  state machine, `workflow_tui_app.py:286`).
- **Within a tab**: `j`/`k` (or `↑`/`↓`) move selection in the LEFT list, which
  drives the RIGHT detail pane.
- **Focus toggle**: `enter` expands the right pane to full-width (focus mode) for
  reading long threads; `esc`/`enter` returns to two-pane.
- **Scroll**: in focus mode `j`/`k` scroll the message stream; `g`/`G` top/bottom;
  `space`/`pgdn`, `pgup` page.

---

## 5. Key bindings

Lifted from `workflow_tui_app.py:59-85`, retargeted to c2c nouns. Keep the muscle
memory identical for anyone who's used the workflow TUI.

| Key | Action | Notes |
|-----|--------|-------|
| `q` | quit | |
| `esc` | back / quit | exit focus mode, else quit |
| `r` | force reload | manual refresh on top of the 1s timer |
| `Tab` / `Shift-Tab` | next / prev tab | also `→` / `←` |
| `j` / `k`, `↓` / `↑` | move selection (or scroll in focus) | |
| `g` / `G` | top / bottom | |
| `space` / `pgdn`, `pgup` | page down / up | |
| `enter` | toggle focus (expand detail pane) | |
| `/` | filter | Peers: by alias substring; DMs: by peer; Rooms: n/a |
| `c` | clear filter | |
| `y` | copy selected alias | clipboard via `App.copy_to_clipboard` |
| `p` | copy selected cwd / session_id | |
| `ctrl+y` | copy selected message/row as JSON | full envelope for paste into a finding |
| `b` | broker picker | switch to another repo's swarm (§2.1, multi-broker) |
| `?` | help overlay | lists bindings |
| **MVP+1 (send mode):** | | |
| `s` | send DM to selected peer | command-palette prompt → shell out `c2c send <alias> <msg>` |
| `o` | open agent's tmux pane | shell out `c2c_tmux.py enter <alias>` (preserves extended-keys-off) |

The two write actions (`s`, `o`) are **disabled in MVP** and grey in the help
overlay; they appear only once §6's later phase lands and always shell out — the
browser never types into a PTY itself (the extended-keys-off / foreground-TUI
footguns stay owned by `c2c_tmux.py`).

---

## 6. MVP scope vs later

### MVP (ship this first) — **read-only browse**

- [ ] Resolve broker root (env > XDG > HOME, or `--broker-root`).
- [ ] **Peers tab**: roster from `registry.json` + tristate liveness; right pane =
      selected peer's merged inbox+archive (DM-only, deduped).
- [ ] **DMs tab**: conversation list + merged A↔B thread.
- [ ] **Rooms tab**: room list + canonical `history.jsonl` timeline.
- [ ] Live update via 1s poll + mtime/offset tail.
- [ ] The §2.4 room-copy dedup (the correctness lynchpin).
- [ ] Tristate liveness rendering (Alive/Dead/Unknown distinct).
- [ ] Nav/focus/filter/copy bindings (read-only subset of §5).
- [ ] Snapshot test harness + ~8 checked-in golden screens (§7).

### Later (explicitly deferred, in rough priority order)

1. **Send a DM** (`s`) — command palette → `c2c send`. Read confirmation is
   impossible by broker design for ephemeral; show "queued" not "delivered."
2. **Jump to pane** (`o`) — shell out to `c2c_tmux.py enter <alias>`.
3. **inotify push** instead of 1s poll (reuse `c2c monitor` recipe).
4. **Multi-broker picker** (`b`) — `list_all_broker_roots`
   (`ocaml/c2c_repo_fp.ml:143`) enumerates every repo's broker; watch several
   swarms.
5. **Events overlay** — `broker.log` ticks (nudge/worktree-mismatch/cap) as a 4th
   tab or status strip.
6. **Memory peek** — `.c2c/memory/<alias>/*.md` per selected peer (respect the
   prompt-scoped "private" convention; show only `shared`/`shared_with`).
7. **DND / compacting** badges surfaced together with liveness.

**Hard non-goals (never in the browser):** typing into PTYs, restarting agents,
launching sessions, room admin (join/leave/invite). Those stay in `c2c_tmux.py` /
`c2c` CLI. The browser is a READ surface that may *trigger* a write by shelling
out — it never owns write mechanics.

---

## 7. Testing approach

Borrow the workflow-TUI's two-tier, agent-readable regression loop verbatim —
this is what lets the swarm maintain its own browser without a human eyeballing a
terminal.

**Tier 1 — deterministic Rich snapshots (fast, the primary loop):**
- `render_snapshot(state, W, H)` renders the pure layer into
  `Console(width=W, color_system=None, force_terminal=False, record=True)` then
  `export_text(styles=False)`; `normalize_snapshot` pads/truncates to exact WxH
  (`workflow_tui.py:1816,1824`).
- **Pin the clock + TZ** (`now()` seam in the data layer, injected reference time)
  so `last_activity` / message timestamps are stable — mirror
  `test_workflow.py::snapshot_env` (`test_workflow.py:79`).
- **Fixtures**: a throwaway broker dir built in `tmp` with hand-written
  `registry.json` + a couple `archive/*.jsonl` + a `rooms/swarm-lounge/history.jsonl`
  exercising: alive/dead/unknown peers, a 2-direction DM thread, a room with the
  double-stored `#room` archive copies (to assert dedup), and an in-flight inbox row.
- ~8 checked-in golden screens: `peers`, `dms`, `room`, `peers-focus`,
  `room-live-watermark`, `narrow-80x24`, `dedup-room-not-in-dm`, `unknown-liveness`.
- `test_browser.py` renders each via subprocess `--snapshot --width --height
  --fixture` and asserts **exact text equality**, plus dimension-stability and
  "panels not cropped mid-box" assertions (`test_workflow.py:2539,2662,2687`).

**Tier 2 — tmux keystroke QA (integration, the real-terminal proof):**
- Port `workflow_tui_tmux_qa.py`: `tmux new-session -x W -y H`, `send-keys` a
  scripted nav/filter/copy walkthrough, `capture-pane -pt -e -S -` after each
  action, assert on substrings. Also reuse c2c's existing `scripts/tui-snapshot.sh`
  (parameterized WxH + `--keys`) for one-shot frame capture.
- This is the only tier that catches real Textual rendering / focus bugs an agent
  can't see; Tier 1 catches everything in the pure layer.

Pairs with the **ultra-tui-iteration** skill (agent-readable TUI TDD) — the
snapshot diff IS the feedback loop for a worker that can't see a terminal.

---

## 8. Tradeoffs & risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| **Room/DM double-store dedup wrong** → room chatter shown twice in DMs, or DMs lost | HIGH (correctness) | Single predicate `"#" not in to_alias`; a dedicated golden snapshot (`dedup-room-not-in-dm`) asserts it. The #1 thing to get right. |
| **Minimal/legacy registry records** (live broker has 4-key stubs, no `pid`/`role`) | MED | Every field optional with defaults; reuse the broker's own tolerant parsers' semantics; fall back to `c2c list --json` for liveness. |
| **Second runtime / `.venv`** friction | MED | Re-exec-into-venv pattern (`workflow_tui_app.py:15`); `requirements-browser.txt` = just `textual`; document a `just browser` recipe that bootstraps the venv. |
| **1s poll latency / CPU on a busy broker** | LOW | Files are tiny + mtime-gated; upgrade path to inotify (`c2c monitor` recipe) is pre-scoped (§2.6). |
| **DM thread reconstruction reads many archives** (per-session sharding) | MED | MVP: index archives once on load, rebuild incrementally on mtime change; only re-scan changed files. Conversation grouping is O(messages) in memory. |
| **0600 file perms** (DM content private) | LOW | Browser runs as same Unix user; READ-only; must never widen perms. Don't copy archive content to world-readable temp in tests. |
| **Drift: browser is a separate tool, not `c2c`** | MED | Accepted for speed; pure-render split makes a later OCaml `c2c watch` port mechanical if single-binary distribution becomes required. |
| **timestamp = delivery time not send time** in DM archive | LOW | Footer hint; acceptable for a browse view; thread order stays correct. |
| **Maintaining two QA harnesses** (snapshot + tmux) | LOW | Both are ported wholesale from proven workflow-TUI code; the swarm already knows the pattern. |

---

## 9. Relationship to existing operator tooling (the clean split)

| Concern | Owner after this lands |
|---------|------------------------|
| READ: roster, DMs, rooms, live watch | **`c2c-browser`** (this design) — broker-JSON-backed, lossless |
| WRITE/DRIVE: send/keys/enter/launch/restart into PTYs | `scripts/c2c_tmux.py` (+ legacy `c2c-swarm.sh` verbs to fold in separately) |
| One-shot CLI queries | `c2c list/history/rooms/monitor` (unchanged; browser does not replace them) |

The browser **subsumes the read-half of pane-scraping** (`peek`/`capture`/`grep`
over scrollback) with a reliable broker-backed view, letting `c2c_tmux.py`
eventually shed those and focus on the PTY-driving write-half — the separation the
tmux scout explicitly recommended. As a stepping-stone, the same Python data layer
(`c2c_browser_data.py`) could back a `c2c_tmux inbox/outbox/rooms` CLI subcommand
to validate the data model before the TUI lands.

---

--- SUMMARY ---

- **What**: `c2c-browser`, a read-only Python/Textual TUI giving the operator one
  live window into the swarm — Peers / DMs / Rooms tabs over the broker's on-disk
  JSON. Fills the single biggest operator gap: there is no unified, live,
  broker-backed read surface today (only N disjoint CLIs + lossy pane-scraping).
- **Stack**: Python/Textual, lifting the workflow-TUI's pure-render + thin-app +
  snapshot architecture near-verbatim. Justified by: browser only READS JSON the
  broker already writes (no in-process OCaml needed); OCaml has no TUI lib in
  deps; the workflow skeleton is agent-testable and ships today with zero coupling
  to the `c2c` build. OCaml `c2c watch` reserved for if single-binary / in-process
  send become hard requirements.
- **Data model**: five broker files (`registry.json`, `<sid>.inbox.json`,
  `archive/<sid>.jsonl`, `rooms/<id>/history.jsonl`, `rooms/<id>/{meta,members}.json`).
  Alias↔session_id join lives only in `registry.json`. **Correctness lynchpin**:
  room messages are double-stored (canonical `history.jsonl` + a `#<room>`-tagged
  copy in each recipient's archive) → Rooms view reads `history.jsonl`, DMs view
  filters out `to_alias` containing `#`. DM threads = merge both peers' archives +
  inboxes, deduped by `message_id`.
- **Live updates**: 1s poll + mtime/byte-offset tail of jsonl (matches workflow
  TUI). inotify (`c2c monitor` recipe — the genuine one; deliver-watch is actually
  poll-based) is a pre-scoped upgrade, not MVP.
- **Liveness**: tristate Alive/Dead/Unknown rendered distinctly; never collapse
  Unknown (pid=None foreign clients) into dead.
- **Architecture**: 4 files mirroring the prior art — pure `_data`, pure `_render`,
  thin `_app` (state+bindings+1s timer only, zero render logic), `_tmux_qa` harness.
- **MVP = read-only**: three tabs, live tail, dedup, tristate liveness, nav/copy
  bindings, snapshot tests. **Later** (explicit): send-DM (`s` → shell out
  `c2c send`), jump-to-pane (`o` → `c2c_tmux.py enter`), inotify, multi-broker
  picker, events overlay, memory peek. **Hard non-goal**: the browser NEVER types
  into PTYs — it stays the READ surface, `c2c_tmux.py` stays the WRITE/DRIVE surface.
- **Testing**: borrow both tiers — deterministic Rich-snapshot golden files (pinned
  clock, fixture broker dir, ~8 screens incl. a dedup-assertion screen) + a tmux
  keystroke QA harness (`capture-pane` substring asserts). Pairs with
  ultra-tui-iteration so the swarm maintains its own browser.
- **Open questions**: (1) reimplement broker-root fp in Python vs shell out once;
  (2) full bidirectional DM-thread reconstruction cost on large archives — MVP
  indexes-once + incremental-tail, revisit if it bites; (3) whether to ship the
  `c2c_tmux inbox/outbox` CLI stepping-stone before the TUI to validate the data
  model.
