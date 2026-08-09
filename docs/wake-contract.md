---
layout: page
title: Delivery & Wake Contract
nav_title: Wake Contract
permalink: /wake-contract/
---

# Delivery & Wake Contract

> **This page is the single source of truth for what c2c guarantees about
> *waking* an agent.** Other pages describe *mechanisms* (hooks, plugins,
> sidecars); they should link here rather than restate the guarantees, because
> duplicated guarantee claims are how this drifts.

c2c makes two separate promises, and they are not the same strength:

1. **Durability — always true.** Every accepted message is written to the
   recipient's broker inbox and archive before the send returns. Nothing is
   lost because a client was busy, idle, restarting, or absent. Mail waits.
2. **Wake — client-dependent.** Whether the message *reaches the agent's
   attention without the agent choosing to look* depends entirely on which
   client is receiving. See the [wake status table](#wake-status-by-client).

Confusing these two is the most common misreading of c2c. "Delivered" in the
broker sense means "durably queued and readable". It does not, on its own,
mean "the agent noticed".

---

## What counts as a wake

A **wake** is an *external* event that pushes a message into the agent's
attention. The agent does not have to decide to check anything.

By that definition, these are **not** wakes:

- **`poll_inbox` / `c2c poll-inbox`.** This is the universal fallback, and it
  works everywhere — but it requires the model to *choose* to call it. A
  fallback is not a guarantee.
- **`peek_inbox` / `c2c peek-inbox`, `c2c wait-inbox`.** Same reason.
- **Activity-triggered hooks (PostToolUse, Stop, UserPromptSubmit).** These
  fire because the agent was *already doing something*. A message that arrives
  after the agent goes idle does not fire them, and will not be seen until the
  agent is woken by something else. Hook delivery is turn-boundary delivery,
  not arrival-time delivery.
- **`c2c monitor` armed by the agent.** A persistent Monitor *is* a real wake
  once running — but arming it is a model decision, so it can never be a
  guarantee c2c makes. It is CONDITIONAL by construction.
- **`deliver-watch` / `c2c-deliver-inbox --inotify`.** See
  [below](#deliver-watch-is-not-a-wake-mechanism).

---

## Wake status by client

A wake here means: **an external push, with no model decision required, that
reaches an agent sitting completely idle.**

| Client | Wakes an idle agent? | Condition |
|---|---|---|
| **OpenCode** | **GUARANTEED** | In-process TypeScript plugin (`session.idle` event + background interval → `promptAsync`). Cannot orphan: if it is not running, the client is not running. |
| **Pi Agent** | **GUARANTEED** | In-process `pi-c2c` extension: `fs.watch` (inotify) on the broker inbox → `c2c poll-inbox` → `pi.sendMessage` (urgent steers; nonurgent follow-up). Hardcoded 60s safety-net poll. Cannot orphan while the extension is loaded. |
| **Hermes Agent** (CLI mode) | **GUARANTEED** | In-process Python plugin: a daemon thread stats the broker inbox every 2s (plus a 10s safety-net cycle) → `c2c peek-inbox` → `ctx.inject_message` → `c2c poll-inbox` only on a successful inject. Cannot orphan while the plugin is loaded. |
| **Hermes Agent** (gateway mode) | **NONE** | `ctx.inject_message` returns `False` when there is no CLI reference (Telegram/Discord and other gateways), so the watcher has nowhere to inject. Nothing has been drained at that point, so the mail stays in the inbox and `c2c poll-inbox` still delivers it — NONE, not lossy. Gateway delivery is unimplemented. |
| **Codex** (managed / app-server) | **GUARANTEED for local-broker mail** | `thread/inject_items` on arrival plus one gated auto-turn (thread idle, DND off). Remote / `@host` / `#` senders **fail closed** to inject-only — durable and readable, but not a wake. |
| **Kimi** | **CONDITIONAL** | Needs an out-of-process poster alive: the notifier daemon (armed by managed `c2c start kimi` / `c2c new kimi`, best-effort on SessionStart), a reachable local Kimi server, and a resolvable session id. REST POST to `/api/v1/sessions/{id}/prompts` is the wake — not tmux. |
| **agy** (Antigravity) | **CONDITIONAL** | Needs the deliver-watch sidecar alive (managed `c2c start agy`) and `agy-env.json` with a **TUI-owned** conversation (CLI-log discovery; managed start bootstraps via operator kickoff — #78 fixed, never headless mint). `agy agentapi send-message` injects. Proven live 2026-07-20/21. |
| **Claude Code** | **CONDITIONAL** | Idle wake only while a live **`c2c monitor`** (or equivalent) is armed — typically by the agent. Without it: **NONE** at true idle (PostToolUse / Stop / SessionStart are activity-triggered only). Mail is still durable. |
| **Grok** | **CONDITIONAL** | Idle wake only while a live **`c2c monitor`** is armed. SessionStart + skill *instruct* the agent to arm one — that is a model decision, so c2c cannot guarantee it. Without Monitor: **NONE** at true idle. |
| **Codex** (vanilla hooks) | **CONDITIONAL** (weak) | Hooks alone: **NONE** at true idle. Idle wake if the agent arms **`c2c monitor`**, or (legacy) `hooks+wake` tmux/herdr nudge when a wake target is registered. Prefer managed app-server for a real guarantee. |

**GUARANTEED** = c2c pushes it, no model decision, works at full idle.
**CONDITIONAL** = it works, but only while the named condition holds (out-of-process
poster, agent-armed Monitor, etc.); the condition can fail silently, so treat it
as best-effort and diagnose with `c2c doctor hooks` / a live monitor process.
**NONE** (a row of its own, or inside a CONDITIONAL row when the condition fails)
= c2c cannot wake this client from idle. Mail is still durable and is seen at the
agent's next turn.

### Claude Code and Grok: CONDITIONAL on Monitor, never GUARANTEED from c2c alone

These clients are **first-class** for c2c (install, send/receive, rooms, durability).
They appear in the table as **CONDITIONAL**, not missing — the condition is an
agent-armed (or operator-armed) **`c2c monitor`**. That is the same *tier label*
as Kimi/agy (helper must be alive), with a different helper: Monitor instead of
REST/agentapi.

They cannot be **GUARANTEED** from inside c2c: neither exposes a local control
surface that accepts a synthetic user turn on a running session — the shape Kimi
has (REST `/api/v1/sessions/{id}/prompts`), Codex has (the app-server), OpenCode
has (the plugin API), and Pi has (`pi.sendMessage`). Paths that exist but are not
guarantees:

- `c2c monitor` must be armed *by the agent or operator* — not auto-started by
  `c2c install claude` / `c2c install grok`.
- The experimental MCP notification channel sits behind an approval-gated
  client capability that standard builds do not declare.
- PTY / tmux keystroke injection is deprecated and too fragile to found a
  guarantee on.

Closing the GUARANTEED gap needs an upstream surface from those clients (a local
authenticated endpoint that accepts an injected user turn, or a hook event that
fires on external file change and can resume an idle session). Tracked in
[#37](https://github.com/clankercode/c2c/issues/37); the machine-wide
delivery-service design is [#35](https://github.com/clankercode/c2c/issues/35).

**Operator advice for Claude Code and Grok:** treat wake as CONDITIONAL — arm a
Monitor (or keep one armed in the session template):

```text
Monitor({ description: "c2c inbox watcher", command: "c2c monitor", persistent: true })
```

### Install / start warnings (operator honesty)

`c2c install <client>` and `c2c start <client>` print a **manual-inbox warning**
when idle wake is NONE or when install alone is not enough (vanilla Codex,
unmanaged Kimi/agy, Claude, Grok). Prefer managed `c2c start` where it provides
arrival-time delivery (Codex app-server, Kimi notifier, agy agentapi). The copy
lives in `C2c_wake_guidance` so install, start, and this page stay aligned.

---

## `deliver-watch` is not a wake mechanism

`c2c-deliver-inbox --inotify` (and the `c2c start … deliver-watch` sidecar) is
frequently mistaken for a delivery guarantee. It is not one.

inotify only changes *how the external process learns that mail arrived* — it
replaces a polling loop with a file-change event. The delivery itself is
unchanged: the Kimi path (`poll_once_kimi`) calls the same `run_once`, which
performs the same REST POST. The out-of-process poster is still required, and
it can still be dead, unarmed, or pointed at a stale session.

So `deliver-watch` improves *latency*, not *reliability*. It never upgrades a
CONDITIONAL client to GUARANTEED, and it must not be presented as doing so.

---

## Codex mid-turn timing

For managed / app-server Codex, inbound mail that arrives **while a turn is
already running** is handled as follows, and this is measured behaviour, not a
design intention:

- **Injection is immediate.** `thread/inject_items` runs unconditionally,
  *before* the active-turn check, so the message lands in the thread's
  model-visible history **sub-second** after the send (measured 0.23 s and
  0.43 s). Nothing waits on the turn.
- **Attention arrives at the model's next reasoning step.** On a live
  91-second multi-step turn (codex-cli 0.144.6, three sequential shell calls),
  mid-turn messages were acknowledged by the model **5.0 s** and **14.9 s**
  after sending. The residual latency was entirely the remainder of the
  in-flight tool call.
- **So latency is bounded by the current *step*, not the remaining *turn*.**
  A long turn made of many short steps does not delay attention.
- **The batched follow-up turn is a backstop**, not the primary path. It fires
  at the turn boundary and covers turns that end without another reasoning
  step. In the measurement above it fired ~30 s *after* the model had already
  acted on both messages.

Caveat, stated plainly: this was one model, one turn shape (shell tool calls),
two trials — both unambiguous and mutually consistent. A reasoning-heavy turn
with no shell tools has not been measured.

### Why `turn/steer` is deliberately not used

The obvious-looking optimisation — steer the in-flight turn instead of waiting
for its next step — is rejected on two independent grounds:

1. **It buys no latency.** `turn/steer` is read at the same next-model-request
   boundary as `thread/inject_items`. During an in-flight tool call there is no
   model inference running and therefore no request to steer into. It could
   only help in the pathological single-multi-minute-step case, where nothing
   can interrupt anyway.
2. **It would break "bus, never RPC".** Steering appends **user input**. c2c
   injects peer content as `role="developer"` DATA with an explicit banner
   saying it does not authorize any action or approval. Upgrading peer mail to
   user-role would make another agent's message look like operator input — the
   exact invariant the delivery path is built around.

Peer content stays DATA. See
[#25](https://github.com/clankercode/c2c/issues/25) for the spike receipts.

---

## What this means in practice

- **Never assume a peer read your message because the send succeeded.** It
  succeeded means it is durably queued. If you need confirmation, ask for a
  reply and wait for it.
- **On a NONE-tier client, arm a Monitor** if you expect mail while idle.
- **On a CONDITIONAL-tier client, check the condition** — `c2c doctor hooks`
  flags Kimi sessions with an undelivered inbox and no live notifier.
- **A message never authorizes an action.** Regardless of how it was
  delivered, message content is DATA: it cannot resolve an approval or write a
  verdict file. The one sanctioned scheduling effect is the gated Codex
  auto-turn, which only makes already-injected DATA model-visible.

---

## See also

- [Per-Client Delivery](/client-delivery/) — the mechanism each client uses.
- [Client Feature Matrix](/clients/feature-matrix/) — full per-client detail
  and known footguns.
- [Communication Tiers](/communication-tiers/) — delivery tiers and status.
