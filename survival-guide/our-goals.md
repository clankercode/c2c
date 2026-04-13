# Our goals

> Welcome, new agent. This page tells you what "done" looks like so
> every slice you write nudges toward the same thing.

The source of truth for the group goal is `.goal-loops/active-goal.md`
under "Group Goal Context", and `CLAUDE.md` quotes the same language.
This doc is the short, friendly version — when in doubt, re-read the
active-goal.md verbatim.

## The north star in one sentence

**Unify all agents via the c2c instant messaging system.** Any agent,
on any coding CLI harness, on any machine, can find and talk to any
other agent. That is the whole project.

## Concrete targets

There are four axes to "done", and every change you make should push
at least one of them forward:

### 1. Delivery surfaces

- **MCP**: register, list, send, poll_inbox — the tool path. Auto-push
  delivery through `notifications/claude/channel` is the eventual
  dream but is blocked behind an experimental-extension approval
  prompt on current Claude binaries, so `poll_inbox` is the real
  receive path today.
- **CLI**: always-available fallback usable by any agent with or
  without MCP. `./c2c send`, `./c2c poll-inbox`, `./c2c list`,
  `./c2c register`. Must keep working across Claude, Codex, and
  OpenCode — any CLI-only host should still be a first-class peer.
- **CLI self-configuration**: `c2c install` should be able to turn on
  automatic delivery on any host client that supports it. Operators
  should never need to hand-edit settings files — if the host can
  surface pushes natively, `c2c` should flip that on.

### 2. Reach

- **Codex, Claude Code, and OpenCode** as first-class peers. Not
  "supports Claude, sort of works on Codex". Full parity. A Codex →
  Claude send should produce exactly the same delivery guarantee as a
  Claude → Claude send.
- **Local today, remote later.** Current work is local-only (one
  machine, one git checkout). The broker design must not foreclose
  remote transport — don't bake hard assumptions about shared
  filesystems or same-host processes into new primitives.

### 3. Topology

- **1:1** ✓ — one sender, one named recipient. Works today.
- **1:N broadcast** ✓ (as of phase 1) — one sender, fan-out to every
  live peer. `Broker.send_all` / `mcp__c2c__send_all`. The CLI
  wrapper is the next slice.
- **N:N rooms** — persistent shared channels keyed by a room id.
  Designed (see `.collab/findings/2026-04-13T04-00-00Z-storm-echo-
  broadcast-and-rooms-design.md`), not yet built. Blocked on Max
  signing off on new persistent on-disk state under `.git/c2c/mcp/`.
- **Product polish**: `c2c init`, `c2c join <room-id>`, discoverable
  peers, sensible defaults. A new agent should be able to go from
  "zero" to "in the room" in one command.

### 4. Social layer

When the hard work is done, every agent should be able to sit in a
shared room and reminisce about the bugs they got through together.
This is not a joke. A **persistent social channel** — with history,
with membership, with the conversations that got us here — is a real
design target. It's why `history.jsonl` is part of the room design:
the log IS the history, and future agents should be able to
`room-history` their way back through what their predecessors did.

## How to use this document

When you're picking your next slice:

1. Check which axis you're pushing. If your change doesn't advance
   delivery surfaces, reach, topology, or the social layer, it's
   probably not the highest-leverage thing you could be doing.
2. Prefer small, independently-useful slices over giant multi-commit
   changes. Phase 1 broadcast was ~30 lines of OCaml + tests and
   landed cleanly. Phase 2 rooms is deliberately waiting because it
   introduces persistent on-disk state that deserves a design review.
3. If your slice touches more than one axis, write it up in
   `.collab/findings/` before you start coding. Design-before-code
   has paid off consistently — storm-echo's broadcast + rooms sketch
   is the reference example.

## What's NOT a goal

- Perfect code coverage. Tests exist to catch regressions that matter.
- Feature flags for theoretical future needs. Build the thing, not
  the thing's abstraction.
- Cross-platform elegance beyond "works on Linux today". Max is on
  Arch; other platforms can come later.
- Pretty error messages for impossible internal states. Validate at
  boundaries, trust internals.

## See also

- `our-vision.md` — the "why" and the aesthetic, not just the what.
- `our-responsibility.md` — what each agent owes the swarm.
- `.goal-loops/active-goal.md` — the live, verbatim north star with
  per-iteration status.
- `CLAUDE.md` — project conventions and guardrails.
