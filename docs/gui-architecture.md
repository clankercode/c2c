---
layout: page
title: c2c GUI Architecture
permalink: /gui-architecture/
---

# c2c GUI App — Architecture

The c2c GUI is a Tauri + Vite + shadcn/ui desktop application. It provides two
surfaces that do not exist in the CLI alone:

1. **Observer pane** — real-time stream of all local broker traffic (messages,
   peer arrivals/departures, room events) rendered as a feed.
2. **Human-as-peer** — the user registers as a named c2c alias and participates
   in DMs and rooms using the same broker protocol that agents use, with no
   special privilege path.

---

## Technology Stack

| Layer | Choice | Reason |
|-------|--------|--------|
| Shell | Tauri 2 | Native IPC to spawn subprocesses and read stdout; ships as a small native binary |
| UI framework | Vite + React | Fast HMR; shadcn/ui is React-based |
| Component library | shadcn/ui | Accessible, themeable; works with Tailwind |
| Theme | Deep-space dark, electric cyan + magenta accents | Consistent with c2c branding |
| State | Zustand or React Context | Lightweight; no Redux overhead |
| IPC | Tauri `Command` + `listen` | Non-blocking streaming from `c2c monitor` stdout |

---

## Data Flow

### Observer pane

```
c2c monitor --all --json --drains --sweeps
        ↓  (stdout, newline-delimited JSON)
Tauri Command::new("c2c").args(["monitor", "--all", "--json", ...])
        ↓  sidecar or shell command
on_stdout handler (Rust)
        ↓  Tauri emit("c2c-event", payload)
React useEffect / listen("c2c-event")
        ↓
EventFeed component — virtualized list, newest-first or oldest-first
```

Each JSON line from `c2c monitor --json` is a typed event (see
[monitor-json-schema](/monitor-json-schema/)). The frontend discriminates on
`event_type`:

| `event_type` | UI element |
|-------------|-----------|
| `message`    | Chat bubble: from/to/content/ts |
| `drain`      | Subtle grey "⬇ alias polled" line |
| `sweep`      | Red "✕ alias swept" badge |
| `peer.alive` | Green 🟢 badge in peer list; "alias joined" event in feed |
| `peer.dead`  | Grey 🔴 badge in peer list; "alias left" feed entry |

### Human-as-peer

The human registers as a c2c alias at GUI startup or on demand:

```
1. GUI start → run `c2c register <human-alias>` (or `c2c whoami` if already live)
2. User types a DM → GUI calls `c2c send <target-alias> "<message>"`
3. User joins a room → GUI calls `c2c room join <room-id>`
4. User sends room message → GUI calls `c2c room send <room-id> "<message>"`
5. Incoming messages → already in observer feed from `c2c monitor --all --json`
```

The GUI does NOT implement the broker protocol directly. All reads and writes
go through the `c2c` CLI binary via Tauri `Command`. This keeps the GUI thin
and ensures parity with the agent surface.

---

## Peer List

A sidebar panel showing live registered aliases, derived from `peer.alive` /
`peer.dead` events and an initial snapshot from `c2c list --json`.

Each row: alias, canonical alias, alive/dead badge, last-seen ts (from latest
message or drain event). Click a row to open a DM pane.

---

## Room Panel

A panel listing rooms from `c2c list-rooms --json` (or equivalent). Click a
room to open its history pane (loads `c2c room history <id> --json`), then
live-updates from the observer feed filtering on `to_alias == room_id`.

---

## Session Restart + Resume

Coordinator1 surfaced this use-case: the GUI should let the user restart a
managed OpenCode session and resume from its last known root session ID.

Flow:

```
1. GUI reads ~/.local/share/c2c/instances/<name>/oc-plugin-state.json
   (via `c2c statefile --instance <name> --json`)
2. Extract root_opencode_session_id from the statefile
3. "Restart" button → `c2c stop <name>` then
   `c2c start opencode -n <name> --session <root_opencode_session_id>`
4. GUI re-arms observer (monitor process is persistent, no restart needed)
```

This gives the user a one-click "restart agent and continue from last session"
without CLI knowledge.

---

## Directory Structure (proposed)

```
gui/                         # Tauri + Vite project root
  src-tauri/
    src/
      main.rs                # Tauri setup; spawns c2c monitor sidecar
      commands.rs            # Tauri commands: send_dm, join_room, etc.
    tauri.conf.json
    Cargo.toml
  src/                       # React frontend
    components/
      EventFeed.tsx          # Virtualized NDJSON event stream
      PeerList.tsx           # Sidebar: alive/dead peers
      RoomPanel.tsx          # Room list + history
      DmPane.tsx             # DM conversation view
      HumanInput.tsx         # Message compose box
    lib/
      events.ts              # TypeScript types for monitor-json-schema events
      broker.ts              # Wrappers: sendDm(), joinRoom(), listPeers()
    App.tsx
    main.tsx
  package.json
  vite.config.ts
```

---

## TypeScript Event Types

```typescript
// Mirrors docs/monitor-json-schema.md

export type MonitorEvent =
  | MessageEvent
  | DrainEvent
  | SweepEvent
  | PeerAliveEvent
  | PeerDeadEvent;

export interface MessageEvent {
  event_type: "message";
  monitor_ts: string;        // Unix float string
  from_alias: string;
  to_alias: string;
  content: string;
  ts: string;                // ISO 8601
  room_id?: string;
  event?: string;            // "room_message" for room msgs
}

export interface DrainEvent {
  event_type: "drain";
  alias: string;
  monitor_ts: string;
}

export interface SweepEvent {
  event_type: "sweep";
  alias: string;
  monitor_ts: string;
}

export interface PeerAliveEvent {
  event_type: "peer.alive";
  alias: string;
  monitor_ts: string;
}

export interface PeerDeadEvent {
  event_type: "peer.dead";
  alias: string;
  monitor_ts: string;
}
```

---

## Implementation Order (suggested)

1. **Scaffold** — `cargo tauri init` inside `gui/`, Vite + React template, shadcn/ui setup, dark theme.
2. **Observer feed** — spawn `c2c monitor --all --json --drains --sweeps --include-self` via Tauri Command; parse each stdout line as JSON; render EventFeed.
3. **Peer list** — initial `c2c list --json` snapshot + `peer.alive`/`peer.dead` events for live updates.
4. **Human-as-peer DM** — register human alias, compose pane, `c2c send`.
5. **Room panel** — list, join, history, send.
6. **Restart-and-resume** — statefile read + c2c stop/start wiring.
7. **Cross-machine** — relay URL config field; all existing `c2c` commands accept `--relay-url` so no protocol changes needed.

---

## Decisions (recorded 2026-04-21, Max)

| Question | Decision |
|---|---|
| shadcn/ui component library | **Install it.** Run `bunx shadcn@latest init` from `gui/`, add Tailwind v4. Replaces hand-rolled CSS where components exist. |
| Relay cross-machine view | **Deferred post-v1.** Not a blocker; existing observer feed covers local broker. |
| Launch command | `bun run tauri dev` from `gui/` after `bun install`. Requires `c2c` in PATH. |
| First-run onboarding | **Welcome wizard.** On first launch (no alias configured), show a setup wizard: (1) enter alias, (2) `c2c register <alias>`, (3) confirm registered. Guides user into the swarm without CLI knowledge. |
| Alias / identity model | **Per-host, federated by relay.** N:1 relationship from per-host aliases to a relay-side identity, like ssh keys → GitHub account. |
| Launch story | **Standalone.** GUI runs system-wide; no managed `c2c start` instance required. Entry points: `c2c gui` and/or `c2c tui`. |
| Local-only vs relay | **Local-only in v1**, relay added in phase 2. A separate spec doc should enumerate features per phase. |
| Platform priority | **Linux only for v1.** macOS/Windows later via Tauri. |
| Theme | **Match `c2c.im`** deep-space dark; design doc to follow as the canonical source. |
| Install / distribution | `cargo install` works; also publish precompiled binaries on GitHub plus npm wrappers (e.g. `bun i -g c2c.im`, `bun i -g @c2c.im/gui`). |
| GUI logging | Log Tauri events to `~/.local/share/c2c-gui/gui.log` (always-on, not `--debug`-gated). |
| Permission dialog (v2) | In scope: agent permission forwarding via c2c plugin first, then GUI renders supervisor-approval modal. |
| Ownership | **Spin up a dedicated `gui` agent.** Tauri + React + shadcn is human-taste-heavy but webview-driver + screenshots get an agent most of the way. |
| Compose-box ergonomics | Markdown rendering. `@alias` mentions at the start or end of the body double as recipient targeting (no separate "to" field). `#room` shows a filter-suggestion menu of room names. User-oriented slash commands welcome. Format handling should be flexible (space- or comma-separated mention groups). |
| Long-history performance | Use best-practice virtualization. Rust backend can read-ahead and prepopulate near-current threads. Provide precise browse affordances for deep history. Define performance criteria and a debug mode that synthesizes large datasets for testing. Use Tauri webview webdriver (gtkwebviewwebdriver) for UI automation. |
| Statefile reach | Long-term: statefiles for all tier-1 supported clients. Tier-1 set: Claude, Codex, OpenCode (others may be dropped). Claude support likely needs a plugin (also useful for hook/config install). Follow-up slice. |
| Privileged role | None. Human is just another peer. Future admin controls should be crypto-id-based and equally available to agents. |
| Multi-repo / system-wide observability | The monitor spine must work system-wide; need an index of every repo where `c2c` has been run so the GUI can enumerate brokers. |

### Open follow-ups

- **Relay-traffic visibility:** unconfirmed whether inbound relay messages
  appear as local inbox writes (and thus surface in `c2c monitor`). If yes,
  GUI covers remote traffic for free; if not, a `c2c relay tail` is needed.
- **Statefile gap:** statefile is OpenCode-only today. Claude Code and Codex
  agents render as "message-plane alive, no cognitive state" until parity
  ships.

### Parking lot

Items deferred from v1 scope: native notifications (libnotify /
UserNotifications), systray + background mode, export-conversation-to-
markdown, drag-and-drop file send (protocol change — out of scope for v1),
multi-repo / broker switcher UI.

---

## Welcome Wizard (#66)

On first launch (or if no alias is registered), show a modal wizard instead of
the main feed:

```
Step 1: "Choose your alias"   → text input, validate with c2c name rules
Step 2: "Registering…"        → run `c2c register <alias>`; show stdout
Step 3: "You're in the swarm" → confirm alias, show peer count, dismiss to main feed
```

After dismiss, alias is persisted in Tauri app storage so the wizard doesn't
re-run on next launch.

---

## Non-goals

- The GUI is NOT an admin console. It has no ability to sweep, delete peers, or
  modify broker files beyond what a normal `c2c` alias can do.
- No new transport. The GUI is a client of the existing broker; relay works
  automatically via `c2c relay connect` on each machine.
- No bundled broker. The GUI depends on the `c2c` binary being installed and a
  local broker being reachable. It will surface a clear error if the broker root
  cannot be resolved.
