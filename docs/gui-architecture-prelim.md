# c2c GUI — Preliminary Working Notes (coordinator1)

> This is a **scratchpad** written 2026-04-21 while the idea was fresh.
> The formal, structured version lives at `docs/gui-architecture.md`
> (planner1). This document captures everything I know + open questions
> for Max, in rough form. Expect contradictions; expect to throw half of
> it away. Fold the useful parts into the formal doc later.

## What we are building

A desktop GUI that does two things:

1. **Observer pane** — a human-readable, real-time view of *all* c2c
   activity: DMs, rooms, peer alive/dead transitions, sweep events,
   permission requests, statefile snapshots from managed agents, and
   (eventually) relay ingress/egress when the local broker is bridged
   over the relay.
2. **Human-as-peer** — the human registers as a c2c peer (alias of their
   choice) and DMs/rooms agents *using the same protocol the agents
   use*. No privileged admin path. The human is just another alias; they
   see exactly what a peer agent would see.

Stack: Rust + Tauri shell, Vite + React + shadcn/ui frontend. Cargo
workspace at `gui/` (not yet created).

## Why this matters / north-star fit

Today Max watches the swarm via tmux panes + `scripts/c2c-swarm.sh list`
+ ad-hoc `mcp__c2c__history` calls. That works but:

- It's tmux-native, not portable (no way to share a session with a
  non-terminal user).
- The agents' statefile (idle? on permission dialog? which model?) is
  only visible via `c2c statefile --tail`, which is one per agent.
- There is no single pane that shows *everyone's* activity at once.
- There is no way for Max to participate in rooms without running a
  full Claude/opencode session just to type into `swarm-lounge`.
- The GUI forces the broker to behave like a *real client*, not just an
  agent harness. Whatever asymmetries exist today (agent-biased
  assumptions) will surface fast.

It also sets up the path toward showing the c2c story to people who
will never install a CLI.

## What we already have that the GUI can consume

Much of the observability plumbing shipped in the last two hours of
swarm work, which is why this is the right moment to scope the GUI.

- **`c2c monitor --all --json`** (planner1, 3f661c1): NDJSON event
  stream. Event types today:
  - `message` (inbox write — DM or room fanout)
  - `drain` (peer polled their inbox)
  - `sweep` (GC sweep ran)
  - `peer.alive` / `peer.dead` (8f2e7e9, emitted on registry.json
    MOVED_TO diffs)
  - Reserved for later: `room.join`, `room.leave`, `room.invite`
  - Schema doc: `docs/monitor-json-schema.md`
- **`c2c statefile --tail [--instance NAME] [--json]`** (coder2-expert,
  3abb503): reads or streams the oc-plugin state snapshot (0.25s mtime
  poll).
- **Statefile protocol** (`docs/opencode-plugin-statefile-protocol.md`):
  plugin emits `state.snapshot` + `state.patch` (deep-merge) to
  `c2c oc-plugin stream-write-statefile`, which lands structured JSON
  in `~/.local/share/c2c/instances/<name>/oc-plugin-state.json`.
  Tracks `root_opencode_session_id`, agent idle, turn/step counts,
  TUI focus (permission/question/prompt/menu/unknown), provider/model.
- **`c2c history --session-id S`**: per-session archive of drained
  messages (JSONL, append-only, `<broker_root>/archive/<session>.jsonl`).
- **`c2c room history <room>`**: per-room history, already surfaces a
  reasonable shape for rendering.
- **Relay (`relay.c2c.im` v0.6.11)**: Ed25519-authenticated HTTP API,
  register / DM / room ops all proven live as of today. The GUI can
  talk to this directly if we want remote-only mode.

That's enough to draw a useful first pane without writing any new
broker-side code.

## Data flow sketch (first cut)

```
                                                 ┌──────────────────────┐
                                                 │   Tauri backend      │
                                                 │   (Rust)             │
┌────────────────────────┐   spawn + stdout       │                      │
│ c2c monitor --all --json│ ─────────────────────▶│ line parser → NDJSON │──┐
└────────────────────────┘                        │                      │  │
                                                 └──────────────────────┘  │
                                                                           │
┌────────────────────────┐   spawn per instance                            │
│ c2c statefile --tail   │ ─────────────────────▶  (one sub per agent)     │
└────────────────────────┘                                                 │
                                                                           │
┌────────────────────────┐   subprocess per action                         │
│ c2c send / send-room   │ ◀─────────────────────  (human-as-peer writes)  │
└────────────────────────┘                                                 │
                                                                           ▼
                                                 ┌──────────────────────┐
                                                 │ Tauri frontend (Vite │
                                                 │ + React + shadcn)    │
                                                 │                      │
                                                 │  • Swarm overview    │
                                                 │  • Room view         │
                                                 │  • DM view           │
                                                 │  • Statefile drawer  │
                                                 │  • Compose box       │
                                                 └──────────────────────┘
```

**Key decision in this sketch:** the GUI never speaks broker JSON-RPC
directly. It shells out to the `c2c` CLI. Pros: reuses every existing
auth/identity path; free cross-machine via relay when the CLI is
configured that way; no duplicated broker logic in Rust. Cons: startup
subprocess cost per action; stdin/stdout parsing; can't batch. For v1
that's fine.

**Alternative:** link against a Rust c2c client library (would need to
be written). Faster, but re-implements protocol. Skip for v1.

## Panes I want in v1

1. **Swarm overview** — top-level peer grid with alias, alive state,
   agent-idle badge, TUI focus badge, last message preview. Live-updated
   from `peer.alive` / `peer.dead` + statefile streams.
2. **Room view** (per room, tabs for joined rooms) — message stream like
   Slack/Discord, with compose box. `swarm-lounge` is default.
3. **DM view** (per peer) — similar. History from `c2c history`, live
   from monitor stream.
4. **Statefile drawer** (per agent, opens from Swarm overview) — shows
   `root_opencode_session_id`, current step, last event, TUI focus. Has
   a "Restart and resume" action that calls
   `c2c stop <name> && c2c start opencode -n <name>`.
5. **Broker health** (small sidebar widget) — what `c2c doctor` shows,
   refreshed every 30s.

v2+ ideas:

- Permission-request dialog surface: when an agent sends a
  `permission.asked` DM to its supervisor, the GUI can render it as a
  native modal with Allow-Once / Allow-Always / Reject buttons,
  sending the reply via `c2c send`. This is where the human-as-peer
  topology really shines — supervisors can drive agent permissions
  without a terminal.
- Cross-machine relay topology view.
- Event-log export / replay.

## Human-as-peer — registration

Open question #1 for Max: **what alias?**

Proposed: on first launch, GUI asks Max for an alias (default: system
username → "max"). It then runs `c2c register --alias max` and stores
the session ID in `~/.local/share/c2c-gui/identity.json`. Subsequent
launches re-use. This gives Max a stable alias visible to all agents.

Follow-up: the GUI should probably *write an Ed25519 keypair for the
human identity* so `max@<host>` is a cryptographically distinct peer
from any agent accidentally aliasing to "max" on another machine.
Planner1's canonical-alias work (`alias#repo@host`) is the substrate.

## Open questions for Max

1. **Alias / identity**: do you want a single "Max" alias across all
   hosts, or per-host (`max@laptop`, `max@desktop`)? My hunch is
   per-host, federated by relay.
2. **Launch story**: run alongside one of your `c2c start` managed
   instances, or stand alone (no agent is required — GUI can be the
   only running c2c client). I assume stand-alone.
3. **Local-only vs relay-by-default**: v1 I'd keep it local-only
   (same broker as agents on this box) and add a "connect remote"
   toggle later. Sound right?
4. **Platform priority**: Linux only for v1 (your daily driver),
   macOS + Windows later? Tauri makes this mostly free but the
   `c2c` binary has to be installed and on PATH. On macOS that's a
   non-trivial onboarding.
5. **Theme**: deep-space dark aesthetic from c2c.im, or something
   more neutral?
6. **Installation story**: `cargo install c2c-gui` (hacky), AppImage,
   Flatpak, or a `just gui-install` recipe that builds and symlinks?
7. **Telemetry / observability of the GUI itself**: log Tauri events
   to `~/.local/share/c2c-gui/gui.log` — fine, or do you want
   `--debug` only?
8. **Permission-dialog rendering**: do you want me to include the
   v2 supervisor-approval dialog in v1 scope, or strictly
   observer + chat first? It's high-value (you'd stop needing tmux to
   approve permissions) but it widens v1 scope.
9. **Who builds it**: as I said in the last message — do we spin up a
   dedicated `gui1` agent, or is this human-owned? I don't have a
   strong opinion; agents can carry it, but Tauri + React + shadcn
   is the kind of stack where human taste in the UI matters.
10. **Name**: "c2c" works for the broker but is maybe not a great
    product name for a GUI. "c2c-desktop", "swarm-view", "compass",
    etc. Do you have one in mind?

## Things I'm pretty sure about, open to challenge

- **Subprocess-based integration beats library integration** for v1.
  We've already proven the CLI is stable; duplicating into Rust
  is a rewrite we don't need.
- **`c2c monitor --all --json` is the spine.** Every pane subscribes
  to the same stream and filters client-side. One long-lived
  subprocess, clean fan-out inside Tauri.
- **No privileged role.** The human is just another peer. If we can't
  do it with the peer API, the peer API is missing.
- **Statefile + monitor compose nicely.** Monitor gives the message
  plane; statefile gives the per-agent cognitive plane. Together
  they are enough for a "what is the swarm doing right now?" view.

## Things I'm unsure about

- **Statefile is currently opencode-only.** Claude Code and Codex
  agents don't emit a statefile. The swarm view will show them as
  "message-plane alive, no cognitive state". That's honest but ugly.
  A minimal statefile for Claude Code (step count, last hook event)
  would close the gap. Probably a follow-up slice for whoever owns
  the Claude Code PostToolUse hook.
- **Relay-traffic visibility.** `c2c monitor` today watches the local
  broker dir. When a local broker is bridged to a remote relay, do
  inbound relay messages appear as local inbox writes (and thus show
  up in monitor)? If yes, the GUI already covers remote traffic for
  free. If not, we need `c2c relay tail` or similar. Planner1 should
  confirm.
- **Compose-box ergonomics.** Markdown? Mentions (`@alias`)? Slash
  commands (`/room list`)? I'd start plain text and iterate.
- **How to render long room histories without scroll-lag.** shadcn's
  ScrollArea + react-window virtualization is the default answer.
  Will need a perf pass once swarm-lounge has months of history.

## Answers from Max

* in progress *

## Rough milestones (order, not dates)

1. `gui/` cargo workspace + Tauri scaffolding.
2. Spawn `c2c monitor --all --json`, parse NDJSON, render messages
   in a dumb list. Prove the spine works.
3. Swarm overview pane backed by `c2c list` + monitor `peer.alive`.
4. Send path: compose box → `c2c send <alias> <text>` → optimistic
   render → confirm on monitor echo.
5. Room tabs + `swarm-lounge` view.
6. Statefile drawer + restart-and-resume.
7. Theme polish, event replay, permission dialog (v2).

## Parking lot

- Native notifications (libnotify / macOS UserNotifications).
- Systray + background mode so the GUI sees messages even when
  the window is closed.
- Export conversation to markdown.
- Drag-and-drop file send (huge protocol change — skip for v1).
- Multi-repo support (one broker per repo is a thing; the GUI may
  want a repo switcher).

---

*This is a working document. Fold into `docs/gui-architecture.md`
once questions are answered and decisions are locked.*
