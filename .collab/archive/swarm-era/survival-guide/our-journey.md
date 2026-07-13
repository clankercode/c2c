# Our journey

> A short oral history of how c2c got here, written for the next
> agent. `git log` has the full record; this page tells you what
> the log doesn't — the decisions, the dead ends, the shape of the
> problem as we learned it.

This is not exhaustive. It is deliberately the "if you only have
five minutes" version so you can orient before diving in.

## Phase 0 — The relay era

c2c started as a Python relay script (`relay.py`, `c2c_relay.py`,
`c2c_auto_relay.py`) that polled inbox JSON files and injected
messages into target Claude sessions via PTY. It worked, sort of.
The PTY injection path relied on an external `pty_inject` binary
and `pidfd_getfd` with `cap_sys_ptrace=ep` — fragile on every
axis. The registry was a hand-rolled YAML file (no YAML library —
see `c2c_registry.py`). Session discovery scanned multiple
`~/.claude-*/sessions/` directories.

Lessons banked in this era:
- Hand-rolled YAML is fine if the shape is flat.
- Atomic writes require temp-file + `fsync` + `os.replace`.
- Cross-process coordination needs real file locks
  (`fcntl.flock` on `.yaml.lock`).
- PTY injection is a last-resort delivery mechanism, not a
  primary.

## Phase 1 — OCaml MCP server

The port to an OCaml MCP server (stdio JSON-RPC) was the pivot
from "a pile of scripts" to "a protocol". First landing was
`f39584c add ocaml c2c mcp server`. Key design choices:

- **File-based broker.** `.git/c2c/mcp/` holds `registry.json`
  and per-session `<sid>.inbox.json` files. Every message is
  visible on disk. No databases, no queues, no mystery.
- **POSIX locking only.** `Unix.lockf` on sidecar `.lock` files.
  This matters because Python's `fcntl.lockf` interlocks with
  OCaml `Unix.lockf`, but `fcntl.flock` (BSD) does not.
  Cross-language safety depends on everyone picking POSIX.
- **Synchronous inbox drain after each RPC.** The MCP server
  drains the caller's inbox on every tool response, feeding
  queued messages back as a synchronous reply. Not async push.

## Phase 2 — Real-delivery reality check

The original plan was to deliver inbound messages to agents via
`notifications/claude/channel` — an MCP notification the host
would surface in the transcript. This *worked* on Claude Code
when launched with the experimental
`--dangerously-load-development-channels server:c2c` flag.

Problem: on Claude 2.1.104 the experimental extension is gated
behind an interactive approval prompt. No non-interactive
allowlist bypass exists. (See
`.collab/findings/2026-04-13T03-14-00Z-storm-echo-channel-bypass-dead-end.md`
for the full research thread.)

The accepted mitigation: **polling via `poll_inbox`**. Every
agent explicitly drains its inbox at each turn. Not as sexy as
transcript-level push delivery, but flag-independent, works on
every harness, and composes trivially with `/loop` and monitor
wake-ups. Committed as `f2d78bb add poll_inbox tool to c2c mcp
for flag-independent receive`.

## Phase 3 — The broker-hardening burndown

A run of quick-succession commits hardened the broker:

- `b6ef334` — liveness checks, registry lock, sweep tool,
  pid_start_time defense against pid reuse. Sweep drops dead
  registrations and their inbox files under the registry lock.
- `ec12859` — inbox file lock, alias dedupe on register,
  cross-process lockf. Closes the last known read-modify-write
  race class. 12-child concurrent enqueue fork test: 240/240
  × 5 runs clean.
- `f275f5b` — dead-letter slice. Sweep now dumps non-empty
  orphan inbox contents to `dead-letter.jsonl` before unlink,
  so accidentally-swept messages are still recoverable.
- `25ce639` — polling-client support: broker fallback send,
  broker-registry preservation across sync, auto-drain env gate.

Each of these came with a findings/ writeup about the bug that
motivated it. Read the findings directory if you want the "why"
behind any of these.

## Phase 4 — Cross-client reach

Codex joined the swarm via `run-codex-inst` (`12:47` today) —
Codex resume launcher with per-instance C2C session ids. First
cross-client send landed the same day: Codex → Claude round-trip
proven via `./c2c-send codex "..."` appending to
`codex-local.inbox.json`, Codex draining via `poll_inbox`.

OpenCode onboarding is designed in
`docs/superpowers/plans/2026-04-13-opencode-local-onboarding.md`
but not yet executed at time of writing.

Cross-client parity was the biggest non-obvious win. The
assumption "c2c is for Claude" baked in subtly through multiple
slices and had to be actively excised. The `broker is the hero`
principle in `our-vision.md` was written as a direct reaction
to this.

## Phase 5 — Topology expansion

1:N broadcast (`send_all`) landed as `17e367e c2c: broker send_all
fan-out primitive (phase 1 broadcast)`. Design sketch from
storm-echo: `.collab/findings/2026-04-13T04-00-00Z-storm-echo-
broadcast-and-rooms-design.md`.

N:N rooms — designed in the same sketch, not yet implemented at
time of writing. Waiting on Max's go-ahead because it introduces
persistent on-disk state under `.git/c2c/mcp/rooms/`.

## What you should take from this

- **Every big win in c2c started as a small finding.** The
  binary-skew detection slice, the drain-noise fix, the alias
  dedupe, the dead-letter preservation — each was a five-line
  writeup in `.collab/findings/` that became a ten-line
  OCaml patch plus a test. Keep writing findings.
- **The failure modes that bit us were never glamorous.**
  Pid reuse. Mtime granularity. Sidecar path mismatch
  (`.inbox.json.lock` vs `.inbox.lock`). Flock vs lockf on
  Linux. These are the interesting bugs, and you will find
  more of them.
- **Don't trust running processes to match source.** The
  longest-lived footgun in this repo is "the broker binary in
  memory is older than `master`". See the 03:56Z binary-skew
  finding. Always treat the live broker with some suspicion.
- **The group goal didn't start as the group goal.** It
  converged over iterations. The four axes in `our-goals.md`
  (delivery surfaces, reach, topology, social layer) were
  written down verbatim in `.goal-loops/active-goal.md` only
  after we'd already been stumbling toward them. If you think
  the goals are obvious, it's because previous agents wrote
  them down for you.

## See also

- `git log --oneline` — the definitive chronology.
- `.collab/findings/` — every bug we hit and how we fixed it.
- `.collab/updates/` — per-slice status logs.
- `.goal-loops/active-goal.md` — the current iteration.
- `our-goals.md` / `our-vision.md` — where we're going next.
