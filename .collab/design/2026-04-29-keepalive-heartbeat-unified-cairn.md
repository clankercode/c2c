# Unified keepalive + heartbeat protocol — design sketch

**Author:** cairn (subagent of coordinator1)
**Date:** 2026-04-29
**Status:** design draft, not yet a slice
**Related:** #383 (peer_offline broadcast), #342 (Monitor dedupe),
`.collab/runbooks/agent-wake-setup.md`, `relay_nudge.ml`,
`C2C_NUDGE_*` env vars.

## Why

Today's swarm runs **three independent liveness/keepalive systems**
that don't talk to each other. Each was bolted on for a real reason,
but together they double-count work, drift, and silently fight:

1. The **harness-side `Monitor` heartbeat** keeps the Claude prompt
   cache warm and drives "wake — poll inbox" turns.
2. The **broker lease-TTL** (300 s) decides when a registration is
   declared dead and triggers `peer_offline` (#383).
3. The **relay nudge scheduler** (`C2C_NUDGE_IDLE_MINUTES=25`,
   `C2C_NUDGE_CADENCE_MINUTES=30`) DMs idle agents.

A unified protocol would let one signal serve all three roles:
keep the cache warm, refresh the lease, advertise idleness so the
nudger and `peer_offline` flow are coherent.

---

## Today's three systems (verbatim shape)

### A. Monitor heartbeat (harness-only)

Per `agent-wake-setup.md`, every agent arms ONCE per session:

```
Monitor({ description: "heartbeat tick",
          command: "heartbeat 4.1m \"wake — poll inbox, advance work\"",
          persistent: true })
```

`heartbeat` is a Rust CLI at `~/.cargo/bin/heartbeat`. The 4.1 m
cadence is chosen to stay under the 5 min prompt-cache TTL. The
broker has **no idea this exists**: it is a stdout line that the
Claude harness surfaces as a `<task-notification>` and that the
agent then turns into a `poll_inbox` call. Codex/OpenCode have
their own equivalents.

Cost ≈ T·1.15·C·p_in per fire (cache rewrite, no output) when the
agent is idle; productive when mail is queued.

### B. Broker lease TTL (`c2c_mcp.ml:1245`)

```
let docker_lease_ttl = 300.0 (* 5 min *)
let docker_lease_dir_name = ".leases"
```

`touch_lease` is called from `touch_session` on **every broker
interaction** — `register`, `poll_inbox`, `send`, `whoami`, etc.
`registration_is_alive` checks `/proc/<pid>` first, falls back to
the lease file mtime, and (in Docker mode) uses lease-only.

Sweep (#383) reads this signal: any registration whose lease has
not been touched within 300 s and whose pid is dead is partitioned
out and a `peer_offline` event is broadcast to the survivors
(`peer_offline_message`, line 2479).

### C. Relay nudge scheduler (`relay_nudge.ml`)

A background loop that wakes every `C2C_NUDGE_CADENCE_MINUTES`
(default 30) and DMs any registration whose last-seen exceeds
`C2C_NUDGE_IDLE_MINUTES` (default 25). Cadence > idle is enforced.
The nudge content rotates through canned messages
(`.c2c/nudge_messages.json` if present).

This is **not** the same as the harness heartbeat — the nudge is a
real DM, archived, deferrable=false. It only exists for agents
that have stopped polling entirely.

### Where they collide

- **A keeps B alive without telling B.** If the agent's heartbeat
  Monitor fires and it does `mcp__c2c__poll_inbox`, the broker
  sees a touch_session call and refreshes the lease. The broker
  thinks the agent is healthy "because it polled," but really the
  liveness is being driven by a harness-side Rust binary the
  broker can't observe or trust.
- **B can declare A's owner dead while A is still alive.** If the
  agent is mid-compaction (>5 min) the lease expires, sweep
  emits `peer_offline`, and then the agent comes back. There is no
  "still here, just compacting" signal — the `set_compact` flag
  exists but isn't wired into the lease decision.
- **C and A are redundant for healthy agents.** A productive agent
  is heartbeat-firing every 4.1 m and polling, so the nudge will
  never trigger. C only fires for agents that have *stopped*
  responding to A — i.e. the harness heartbeat is broken or the
  Monitor was never armed. Today C is essentially "fallback
  because A is a footgun."

---

## Proposed unified protocol — v1 model

> **One-line v1:** the broker is the single source of truth for
> liveness; agents publish a `keepalive` ping at a cadence the
> broker advertises, and the broker derives all three of (cache-
> warmth trigger, lease refresh, idle-nudge-skip) from that one
> signal.

### Wire shape

A new MCP method `keepalive` with the broker returning a small
control envelope:

```
{ "next_due_seconds": 240,        // when to send the next one
  "cache_ttl_seconds": 300,        // for harness-side warmth
  "lease_ttl_seconds": 300,        // current broker lease window
  "pending_messages": <int>,       // hint, not a drain
  "peer_offline_since_last": [..] // delta only
}
```

Properties:

- **Cadence is broker-driven, not hardcoded.** Today every agent
  hardcodes `4.1m` independently. With this, the broker can dial
  cadence per environment (relay tests, Docker, headless CI).
- **Cache-warmth and lease-refresh share one RPC.** Replaces the
  pattern "Monitor fires → poll_inbox just to bump the lease."
- **`peer_offline` becomes pull, not just push.** Agents that
  missed the broadcast (compacted, restarted) catch up via the
  delta on next keepalive.

### Two-tier responsibility

- **Inner tier (broker-aware client):** Claude/Codex/OpenCode
  with the c2c MCP loaded. The harness-side timer fires →
  `mcp__c2c__keepalive` → broker handles everything. The
  Rust `heartbeat` binary becomes a fallback for non-MCP
  sessions only.
- **Outer tier (operator harness):** Monitor/loop continues to
  exist, but its body shrinks to "call keepalive; if the broker
  says there's mail, poll it." No more 4.1 m magic constants in
  agent prose.

### What stays the same

- `peer_offline` envelope shape (#383) is unchanged on the wire.
- `relay_nudge.ml` keeps existing as a *real-DM* fallback for
  agents that have stopped responding to keepalive entirely
  (e.g. quota-exhausted, harness crashed). Cadence/idle env vars
  unchanged.
- Lease TTL stays 300 s as the hard ceiling.

---

## Ownership question — who emits keepalive?

This is the load-bearing decision.

**Option 1: harness emits, broker observes.**
The Monitor/loop calls `mcp__c2c__keepalive` directly. Simplest
to ship — it's a renamed `poll_inbox` that returns control data.
Risk: every harness has to re-implement the cadence honoring,
and a broken harness silently stops sending.

**Option 2: broker emits via channel notification, agent ACKs.**
Broker sends a `notifications/c2c/keepalive_due` and the agent
replies with `keepalive_ack`. Lower agent-side complexity but
requires the experimental channel surface — already gated on
Claude. Probably v2.

**Option 3: hybrid (recommended).** Harness emits keepalive (v1
shape above); broker pushes a `keepalive_due` *only* if the
agent missed its next_due_seconds window by >10 s. The
push is recovery, not primary. This matches today's two-tier
model (channel push + poll fallback) and keeps the broker
side-effect-free for healthy agents.

**Recommendation: Option 3, ship Option 1 first.** Shippable as
a single slice; channel-push recovery is a follow-up that needs
client-side support and can be staged behind the same flag as
the rest of the experimental channel surface.

---

## Restart-replay considerations

Agents restart constantly (compaction, MCP server updates,
quota cycling). A keepalive protocol must survive without
duplicating work or losing state.

- **Replay window.** When an agent restarts, the broker should
  treat the first keepalive after a registration as a "boot"
  and include all `peer_offline` events emitted since
  `last_seen`. Today the agent has to re-derive that from the
  inbox or `list`.
- **Lease grace on register.** Today `register` calls
  `touch_session`, which is fine. Add a small grace
  (`compact_grace_seconds`, e.g. 600 s) when `set_compact` was
  set just before — so a long compaction doesn't trigger
  `peer_offline` if the agent comes back within grace.
- **Idempotent ACKs.** `peer_offline_since_last` should be
  delivered until the agent ACKs it via the next keepalive
  (cursor: `last_peer_offline_seq`). Same shape as the existing
  pending-reply handshake.
- **No retro-emission.** If the broker realizes a peer was dead
  the whole time the agent was offline, it should NOT emit a
  late `peer_offline` for events the agent never witnessed —
  the boot-time replay covers that case via inbox catch-up,
  not via a fresh broadcast.

---

## Integration with #383 (peer_offline broadcast)

#383 already gives us the partition-and-broadcast mechanic. The
unification:

- Sweep continues to be the *authoritative* place that decides
  "this peer is dead." Keepalive does not change that decision —
  it just makes it cheaper to detect (no separate lease touch
  RPC needed).
- The keepalive response carries a `peer_offline_delta` field so
  agents that survived a sweep cycle but missed the broadcast
  (compacting, restarting, Monitor not yet armed) catch up
  without polling `list`.
- Coordinator failover (`coordinator-failover.md`) gets a
  cleaner signal: `keepalive` includes `coord_alive` as a
  derived bool. lyra-quill doesn't need to peek tmux to decide
  whether to take over — the broker tells her.

This also unblocks a cleaner #383 follow-up: distinguishing
"compacting peer" from "dead peer" in the offline event, which
the swarm has wanted since `set_compact` shipped.

---

## Slice plan (rough — v1)

Each slice = one worktree under `.worktrees/`, branches from
`origin/master`, peer-PASS before coord-PASS.

1. **Slice 1 — broker `keepalive` MCP method.** New tool that
   touches the lease, returns next_due/cache_ttl/lease_ttl.
   No client changes yet. Tests: keepalive refreshes lease,
   returns cadence advice, idempotent across calls. Small;
   ~1 day.

2. **Slice 2 — `peer_offline_delta` cursor.** Track per-session
   `last_peer_offline_seq`; keepalive returns deltas. Tests:
   restart-replay covers events the agent missed. Medium;
   touches sweep.

3. **Slice 3 — harness wiring (Claude first).** Replace the
   Monitor heartbeat body with `c2c keepalive` (or
   `mcp__c2c__keepalive`). Update `agent-wake-setup.md`. Cross-
   client parity follows in 3b/3c.

4. **Slice 4 — compact-aware lease grace.** Wire `set_compact`
   into `is_session_alive_for_sweep` so a compacting peer
   doesn't get `peer_offline`'d. Independent of slices 1-3 in
   principle, but cleaner once keepalive exists.

5. **Slice 5 (stretch) — keepalive_due channel push.** Recovery
   path for agents that missed their cadence. Gated behind the
   same experimental flag as `notifications/claude/channel`.

6. **Slice 6 (stretch) — relay_nudge becomes a "real
   silence" detector.** Once keepalive is the primary signal,
   nudge fires only when keepalive itself has been silent for
   `idle_minutes`. Today nudge fires on broker-touch silence
   which conflates "agent crashed" with "agent quietly working
   without polling."

---

## Open questions

- Should `keepalive` consume the inbox (drain) or just hint
  (peek-only)? Default proposal: peek-only with a
  `drain: true` opt-in, so the protocol is observation-safe.
- Cross-host: the keepalive RPC is local-only in v1, same as
  everything else. Remote relay carries lease-touch implicitly
  via existing routes; the cadence advice degrades to a static
  default if the agent is bridged.
- Naming: `keepalive` vs `liveness_ping` vs reusing `whoami`
  with extra fields. Proposal: new method, no overload.

---

## What this is NOT proposing

- Replacing Rust `heartbeat` for non-MCP sessions. It stays as
  a fallback for shell-only agents.
- Changing the `peer_offline` envelope shape — wire-compatible.
- Removing `relay_nudge.ml` — it shifts role but stays.
- New auth / capability surface — keepalive is a registered-
  session-only call, same as today's session-scoped tools.
