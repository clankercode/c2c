# c2c TUI Review & Design — Index + Executive Proposal

**Date:** 2026-06-13 · **Status:** RESEARCH / DESIGN (no implementation) · **Driver:** orchestrator (Max-requested)
**Scope:** review + polish c2c's existing interactive surfaces; design a new *live agent-session / DM / room browser* TUI.

---

## TL;DR (read this first)

> **Build a read-only Python/Textual session-message browser, lifting the
> `workflow` skill's TUI architecture near-verbatim. Ship it standalone first;
> graduate to a `c2c watch` subcommand only if/when send-from-browser and
> single-binary distribution become hard requirements.** In parallel, do a few
> low-risk polish passes on the existing line-based formatters and *consolidate*
> the two diverged tmux operator tools.

The new browser is genuinely greenfield on the rendering side but sits on a
**fully-built read substrate**: every browseable fact already lives as flat
JSON/JSONL files under one broker-root directory. There is no DB and no daemon
to stand up — the browser just reads files (and, for the live feed, mirrors the
proven `inotifywait` recipe c2c already ships).

---

## 1. The landscape — what c2c has today, and the gap

### What exists
- **No TUI anywhere in c2c.** Every "interactive" surface is a one-shot
  Cmdliner subcommand printing fixed-width ASCII to stdout:
  `c2c list` / `sessions` (`ocaml/c2c_sessions_format.ml:66-101`, hand-rolled
  `%-Ns` columns, monochrome), `c2c history` (`ocaml/cli/c2c_history.ml:26-57`,
  flat reverse-chron per `session_id`), `c2c stats`, `c2c rooms`, `c2c monitor`
  (line-based live event ticks via `inotifywait`).
- **The "wizard" the operator remembers is NOT a TUI.** It is two unrelated
  things: (a) `c2c agent new` with no flags on a TTY — a numbered-menu readline
  loop (`ocaml/cli/c2c_agent.ml:126-203`), one-shot prompts, recursion-on-error,
  no cursor nav / back-button; and (b) `c2c agent refine` — an **LLM persona**
  (`.c2c/roles/role-designer.md`) spawned as a full coding-CLI session in a tmux
  pane (`run_ephemeral_agent ~mode:Pane`, `c2c_agent.ml:664-750`). Neither is a
  curses/Textual interface.
- **The only live window into the swarm today is tmux pane-scraping.**
  `scripts/c2c_tmux.py` (528 LOC) resolves alias→pane by **process-tree
  scraping** (regex on the `c2c start <client> -n <alias>` argv,
  `c2c_tmux.py:78,114-126`), then `capture-pane`s scrollback. A legacy
  `scripts/c2c-swarm.sh` still uniquely holds `restart`/`follow`/`grep`. Both
  are listed as canonical in CLAUDE.md (a documented footgun).

### The gap (what the operator cannot do today)
- **No single read-only view of the whole swarm.** To see all agents + their
  DMs + rooms you run `c2c list`, then `c2c history` per session, then
  `c2c rooms history` per room — N commands, no unified or live view.
- **Message inspection means scraping pane scrollback** — lossy (scrollback
  window), ANSI-polluted (needs `sed` stripping), and it conflates broker
  traffic with the agent's reasoning text. **No command anywhere shows an
  agent's actual broker inbox/outbox or room membership.**
- **No liveness / role / DND / compacting at a glance**, no thread/conversation
  abstraction, no DM-vs-room disambiguation (the `#room` suffix in `to_alias`
  is shown raw), no auto-refresh.

**This gap is exactly what the new browser fills.** Data-substrate detail
lives in [`01-session-message-browser-design.md`](01-session-message-browser-design.md) §2.

---

## 2. The data substrate (why this is cheap to build)

All state is flat files under **one** broker-root dir — resolve with
`C2c_repo_fp.resolve_broker_root()` (env `C2C_MCP_BROKER_ROOT` > `$XDG_STATE_HOME/c2c/repos/<fp>/broker` > `$HOME/.c2c/repos/<fp>/broker`, `fp = sha256(remote.origin.url)[:12]`). On this host:
`/home/xertrov/.local/state/cc-p/c2c/repos/8fef2c369975/broker/`.

| Class | File | Shape | Role in browser |
|---|---|---|---|
| **Who + liveness** | `registry.json` | JSON array of registration objects (`alias`, `session_id`, `pid`, `role`, `dnd`, `compacting`, `last_activity_ts`, `cwd`, `client_type`) | left roster pane; **only** alias↔session_id map |
| **Undrained DM queue** | `<session_id>.inbox.json` | JSON array of pending messages | merge into the message pane (in-flight) |
| **DM history (durable)** | `archive/<session_id>.jsonl` | one JSON/line: `{drained_at, from_alias, to_alias, content, message_id}` | the real DM record |
| **Room history (canonical)** | `rooms/<id>/history.jsonl` | one `{ts, from_alias, content}`/line | room timeline |
| **Room meta/members** | `rooms/<id>/{meta,members}.json` | visibility, member list | room tab |
| **Events** | `broker.log` | one JSON/line (rotated) | optional events feed |

**Two load-bearing gotchas the browser must handle** (full detail in 02):
- **Room messages are double-stored.** `send_room` fans a copy into each
  member's inbox tagged `to_alias="<alias>#<room_id>"`, which on drain lands in
  that member's `archive/<sid>.jsonl` **and** the canonical copy goes to
  `rooms/<id>/history.jsonl`. Treat `history.jsonl` as the canonical room view
  and **filter archive rows whose `to_alias` contains `#<room_id>` out of the DM
  view**, or the operator sees room chatter once per recipient.
- **A full A↔B DM thread is sharded.** B's side of A→B is only archived under
  B's `session_id`. To show a thread, map alias→session_id via registry and
  merge both `archive/<sid>.jsonl` files by `ts`/`message_id`.

**Live updates:** reuse the proven recipe verbatim —
`inotifywait -m -r -e close_write,modify,delete,moved_to --format '%e\t%w%f' <broker_root>`, gating startup on the stderr line `Watches established.`
(`ocaml/cli/c2c.ml:3843,3871`). Atomic writes (temp+fsync+rename) mean readers
always see whole files. **MVP can poll at 1 s** (files are tiny) exactly like the
workflow TUI's `set_interval(1.0, reload_state)`; inotify is the v2 upgrade.

---

## 3. The headline recommendation

### 3a. Build the new browser in Python/Textual, reusing the workflow-TUI stack
The `workflow` skill (`~/.llm-general/ai-coding/codex/skills/workflow/scripts/workflow_tui*.py`) is a mature, directly-instructive template. Its key idea, lift it whole:

> **A pure render layer** (`workflow_tui.py:1735 render_dashboard(...)` → Rich
> `Table.grid`/`Panel`/`Group`) consumed by **both** (a) a deterministic
> text-snapshot CLI path (`render_snapshot` → `Console(record=True, color_system=None).export_text()` → `normalize_snapshot` to exact WxH) **and**
> (b) a thin ~500-line Textual `App` (`workflow_tui_app.py`) that holds **only**
> state (selection/tab/filter), key bindings, and a `set_interval` refresh
> timer — **zero rendering logic**.

This split is what makes it **agent-testable**: snapshots are deterministic
plaintext diffs (14 checked-in golden screens + a tmux keystroke QA harness in
the prior art). The swarm can therefore maintain its own browser — essential,
since no agent can see a real terminal.

**Why Python/Textual over OCaml here:**
- The c2c binary's deps (`ocaml/cli/dune:4`) are `cmdliner yojson lwt cohttp`
  only — **no TUI library**. OCaml's TUI ecosystem (notty/lambda-term/nottui) is
  unused and far less ergonomic than Rich+Textual.
- The browser reads only on-disk JSON the broker already writes — trivially
  parseable from Python with **zero coupling to the OCaml build**. Ships today.
- We get to lift the workflow skeleton near-verbatim instead of writing a
  render+event layer from scratch in a TUI-poor ecosystem.

**Cost of the Python choice (eyes open):** a second runtime + a `.venv` with
Textual (the skill already does a `maybe_reexec_textual_venv` bootstrap,
`workflow_tui_app.py:14`); it can **read** but to **send/act** must shell out to
`c2c send` / `c2c history --json` rather than call Broker functions in-process;
and it is not (initially) a `c2c` subcommand.

Full design: [`01-session-message-browser-design.md`](01-session-message-browser-design.md).

### 3b. Polish — and CUT — the existing surfaces (cheap, isolated wins)
- **`c2c sessions/list`**: add liveness/role coloring + sorting (alive=green,
  dead=dim, dnd=yellow, compacting=cyan; coordinator first). Data
  (`registration_liveness_state`, `role`) is already in hand —
  isolated formatter change in `c2c_sessions_format.ml`.
- **`c2c history`**: decode the `to_alias` `#room` suffix into an explicit
  **DM vs `#room` badge** instead of raw `alias#room`.
- **`c2c agent` wizard**: wire up or **delete** the dead `role_designer_embedded`
  module (compiled-in, zero runtime consumers — `refine` errors if the on-disk
  role file is missing instead of falling back to the embedded copy). Add a
  discoverable `c2c agent wizard` entry; warn on alias-collision; strip the
  `.md`-suffix bug.
- **tmux tooling**: **decide on ONE tool.** Port `c2c-swarm.sh`'s unique verbs
  (`restart`, `follow`, `grep`) into `c2c_tmux.py` and demote the bash script.
  Once the browser owns the **read** half (list/peek/capture/grep), frame
  `c2c_tmux.py` as the canonical **write/drive** half (send/keys/launch/restart)
  and let it shed the read commands.

---

## 4. Phased plan

- **Phase 0 — Polish + consolidate (days, no new surface).** Liveness coloring
  in `sessions_format`, `#room` badge in `history`, the dead-module decision,
  port `restart`/`grep`/`follow` into `c2c_tmux.py`. Each is an isolated,
  separately-shippable slice with a checked-in golden-output test.
- **Phase 1 — MVP browser (read-only, poll-refresh).** Standalone
  Python/Textual reader. Two-pane layout, three tabs (**agents | dms | rooms**),
  `set_interval(1.0)` reload, snapshot CLI path + golden screens from day one.
  Resolves the roster from `c2c list --json` / `registry.json`, reads
  `archive/*.jsonl` + `rooms/*/history.jsonl`, dedups the room double-store,
  merges in-flight `*.inbox.json`. Copy-id / copy-path / copy-json bindings.
- **Phase 2 — Live + thread abstraction.** Swap poll for the `inotifywait`
  recipe (push updates); add the merged A↔B DM **conversation** view; distinct
  Alive/Dead/Unknown/DND/compacting treatment; multi-broker picker
  (`list_all_broker_roots`) for operators watching several repos.
- **Phase 3 (conditional) — Subsume / send.** Add a command-palette "send DM to
  selected agent" (shell out to `c2c send`) and a "jump into this agent's pane"
  action (must reuse `c2c-tmux-enter.sh`'s extended-keys-off Enter toggle
  verbatim — a correctness-critical incantation). **Only here** evaluate an
  OCaml `c2c watch` rewrite for in-process Broker access + single-binary
  distribution.

---

## 5. Key DECISIONS for Max (this is what needs a call)

1. **Stack — Python/Textual (recommended) vs OCaml `c2c watch`.**
   Python ships fastest by lifting the workflow skeleton; OCaml gives a true
   subcommand + in-process Broker API but means building a TUI layer from
   scratch in a TUI-poor ecosystem. **Recommend Python now, reserve OCaml for
   Phase 3** if send + single-binary become hard requirements.
2. **MVP scope — 3 tabs (agents | dms | rooms) read-only.** Cut for v1:
   send-from-browser, the wizard-as-form, `broker.log` events tab, multi-broker
   picker. **Decision: is read-only + 3 tabs the right v1 line?**
3. **Read-only vs send.** Read-only is the fastest path to the "browse live
   sessions + DMs + rooms" deliverable and side-steps the live-vs-cached / TUI
   submit-key hazards. **Decision: defer send to Phase 3, or is send table
   stakes for v1?**
4. **Standalone tool vs `c2c` subcommand.** Standalone = zero OCaml-build
   coupling, ships today; subcommand = discoverable + in-process readers but
   couples to the OCaml build and the TUI-poor ecosystem. **Recommend standalone
   now; revisit at Phase 3.**
5. **One tmux tool (kill the divergence).** Port the 3 unique verbs into
   `c2c_tmux.py` and demote `c2c-swarm.sh`? **Recommend yes** — CLAUDE.md
   advertising both is a live footgun.

---

## 6. Document map

- **`00-README.md`** (this file) — index + executive proposal.
- **`01-session-message-browser-design.md`** — concrete browser design: data
  substrate (§2), component list, ASCII mockups, key bindings, snapshot/QA harness.
- **`02-existing-tui-polish.md`** — review + polish/cut plan for the existing
  surfaces (role wizard + tmux tooling) and the read/write split.
- **`03-open-questions-and-corrections.md`** — **READ THIS**: the adversarial
  critics' factual corrections to 00/01 (the mockups use stale/fabricated data;
  `c2c list --json` already preserves liveness tristate), the sharper v1, and
  the decisions Max must make.
- **`raw-findings/`** — the 4 scouts' + 2 critics' structured JSON.

> ⚠️ **Correction notice:** 00 and 01 were written before the critique pass.
> Their ASCII mockups depict a busy 7-agent swarm that does **not** match the
> live broker (0 alive, no room history, empty `members.json`), and 01 §2.7's
> "reimplement liveness in Python" rationale rests on a false premise. Treat
> `03-open-questions-and-corrections.md` as authoritative where they conflict.

---

## Exec summary (for the orchestrator)

c2c has **no TUI today** — every interactive surface is a one-shot ASCII
Cmdliner command, and the operator's only live window into the swarm is
**lossy tmux pane-scraping**; nothing anywhere shows an agent's actual broker
inbox/outbox or room membership. That gap is the deliverable. **Recommendation:
build a read-only Python/Textual session-message browser, lifting the `workflow`
skill's pure-render-layer + thin-Textual-App + golden-snapshot architecture
near-verbatim** — it sits on a fully-built read substrate (flat JSON/JSONL under
one broker-root dir; no DB, no daemon) and reuses c2c's proven `inotifywait`
live recipe. **Two gotchas are load-bearing:** room messages are double-stored
(dedup via the `#room` `to_alias` tag) and DM threads are sharded per
recipient-`session_id` (merge both archive files). **Phase plan:** P0 polish +
consolidate the two diverged tmux tools, P1 MVP (3 tabs agents|dms|rooms,
poll-refresh, snapshot-tested), P2 live+thread+multi-broker, P3 (conditional)
send + an OCaml `c2c watch` rewrite. **Five decisions need Max:** stack
(Python now / OCaml later), MVP scope (3 tabs read-only), read-only-vs-send,
standalone-vs-subcommand, and killing the `c2c_tmux.py` ↔ `c2c-swarm.sh`
divergence. Details in 01/02; open questions to land in 03.
