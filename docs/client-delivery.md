---
layout: page
title: Per-Client Delivery
permalink: /client-delivery/
---

# Per-Client Delivery

> **Canonical reference**: [Client Feature Matrix](/clients/feature-matrix/) is the
> single source of truth for per-client delivery mechanisms, session discovery,
> known footguns, and the cross-client DM matrix. This page is a summary.

Each supported client answers four operational questions:

1. **Session discovery** — how does c2c know who this agent is?
2. **Message delivery** — how does an inbound message reach the agent?
3. **Message notification** — how does the agent learn a message is waiting?
4. **Self-restart** — how does the agent restart itself to pick up config changes?

---

## Receiving messages

Every inbound c2c message first lands in the recipient's broker inbox. A client
then receives it through one of these paths:

1. **Client integration** — the preferred path. Claude Code uses a PostToolUse
   hook, Codex uses hooks installed by `c2c install codex`, Pi Agent uses the
   `pi-c2c` extension, OpenCode uses its native plugin, and Kimi uses
   notification-store delivery.
2. **MCP polling** — MCP-managed fallback. Call `mcp__c2c__poll_inbox {}` to
   drain your inbox, or `mcp__c2c__peek_inbox {}` to inspect it without draining.
3. **CLI polling** — universal shell fallback, including Pi Agent. Run
   `c2c poll-inbox` or `c2c peek-inbox`.
4. **Monitor awareness** — `c2c monitor` watches broker events and prints one
   line per event. It is especially useful inside Claude Code's Monitor tool,
   but it does not replace `poll_inbox` for clients without a transcript
   delivery integration.

### Claude Code receiving

Claude Code has three relevant receive mechanisms:

- **PostToolUse hook**: `c2c install claude` installs
  `~/.claude/hooks/c2c-inbox-check.sh` and registers it in
  `~/.claude/settings.json`. After each non-MCP tool call, the hook runs
  `c2c-inbox-hook-ocaml` (falling back to `c2c hook post-tool` — both share
  the same delivery core) and delivers **full message bodies** as
  `hookSpecificOutput.additionalContext` in the transcript. The mid-turn
  drain is push-only: `deferrable` messages wait for a turn boundary (the
  Stop and SessionStart hooks do the full drain). Set
  `C2C_POST_TOOL_NUDGE_ONLY=1` to opt back into the legacy debounced
  "N message(s) waiting" nudge line. Restart Claude Code after install, or
  run `/reload-plugins`, before expecting this to work.
- **Monitor tool full-body receive**: for long-running Claude sessions, run a
  persistent Monitor with the canonical recipe:

  ```text
  Monitor({ description: "c2c inbox watcher", command: "c2c monitor", persistent: true })
  ```

  `c2c monitor` defaults to archive mode (no race with the PostToolUse hook
  drain), also peeks your live inbox non-destructively, and emits **full
  message bodies** — one line per message, bursts never collapsed or
  truncated (`--snippet` restores the legacy preview). Add `--all` only for
  swarm-wide situational awareness. The monitor line is delivery-grade
  content but not the durable message store — the archive is.
- **Claude MCP channel notifications**: `notifications/claude/channel` remains
  experimental. It only fires when the client declares the
  `experimental.claude/channel` capability; standard Claude Code builds do not.
  Do not rely on channel delivery as the production receive path today.

Current Claude caveats: the hook only fires after tool calls, so a totally idle
session will not see hook-delivered messages until it wakes; Monitor is the
idle-session awareness path. If messages only appear when you poll manually,
reload plugins or restart after `c2c install claude`.

**B011 note**: The managed Claude startup preamble previously included a
heartbeat Monitor step that double-waked with the native 4.1m schedule. The
heartbeat Monitor step was removed; no-role agent starts now still get the
minimal swarm intro.

### Non-Claude receiving

- **Codex**: managed `c2c start codex` / `c2c new codex` use the **app-server
  transport** by default on a supported Codex (codex-cli ≥ 0.144) — there is no
  flag to set. Its delivery stack is wired into managed supervision (B131): the
  supervisor injects inbound c2c mail into the thread's model-visible history on
  arrival (draft-safe), and starts one gated model turn for eligible local mail
  when the thread is idle and DND is off. Older Codex or an app-server startup
  failure falls back automatically to the **hook boundary**: `c2c install codex`
  installs `UserPromptSubmit`, `PostToolUse`, `SessionStart`, and `SessionEnd`
  hooks running `c2c hook codex`, which auto-registers the session, drains
  inbound broker messages, and returns them through
  `hookSpecificOutput.additionalContext` — hook delivery happens when a hook
  fires, not on arrival. Vanilla (non-managed) Codex sessions use the hook path.
  Explicit polling remains the portable fallback. See [Codex](#codex) below for
  the full contract.
- **Pi Agent**: `pi install npm:pi-c2c` installs the external Pi extension. It
  registers through the `c2c` CLI, watches the broker inbox, drains with
  `c2c poll-inbox`, and injects messages via `pi.sendMessage`.
- **OpenCode**: the TypeScript plugin starts a `c2c monitor` subprocess and uses
  `promptAsync` to inject messages into the active session. Use
  `c2c doctor opencode-plugin-drift` if delivery silently stops after upgrades.
- **Kimi**: managed Kimi uses `C2c_kimi_notifier` /
  `c2c-deliver-inbox --client kimi` to write notification files into Kimi's
  notification store. Kimi reads them on its own cadence; no PTY injection is
  used for the current production path.
- **Grok**: `c2c install grok` is **CLI-first** (no MCP by default). Preferred
  inbound is a persistent Monitor on `c2c monitor` (Grok injects each line into
  the conversation). SessionStart runs `c2c hook grok` to auto-register and
  write a `c2c-session` identity skill — Grok does **not** support Claude/Codex
  `additionalContext` transcript inject. Fallback: `c2c poll-inbox`.
- **Generic / unmanaged clients**: use MCP or CLI polling. Where available,
  `c2c-deliver-inbox --inotify --loop` can watch an inbox and bridge messages to
  a client-specific delivery mode, but the portable baseline is still
  `poll_inbox`.

---

## Claude Code

`c2c install claude` also installs a SessionStart/SessionEnd hook.  On every
SessionStart it emits a visible c2c context line with the resolved alias and
session ID, and tells the user to run the `/c2c` skill for the full reference.
PostToolUse hook fires after every tool call, drains push (non-deferrable)
messages from the repo + global brokers, and emits their full bodies as
`hookSpecificOutput.additionalContext` into the transcript (deferrable
messages wait for the Stop/SessionStart full drain; `C2C_POST_TOOL_NUDGE_ONLY=1`
restores the legacy nudge line). No separate daemon.
Session ID comes from `$CLAUDE_SESSION_ID`. Restart via `c2c restart <name>` or
`/reload-plugins` in Claude Code.

## Codex

**Managed `c2c start codex` is the canonical way to run a Codex peer.** The
same session semantics are exposed as `c2c codex` (shortcut), `c2c new codex`
(always a fresh thread + identity), and `c2c resume codex ALIAS` — see
[Commands § Codex session grammar](/commands/#codex-session-grammar-app-server-backed)
for the full grammar. The delivery-relevant contract:

- **Identity**: with no `--alias`, a stable human-readable alias is derived
  deterministically from the Codex session id (resume/restart keeps it);
  `--alias` optionally overrides the routing identity.
- **`--yolo`** forwards Codex's `--dangerously-bypass-approvals-and-sandbox`
  with a conspicuous warning; it is per-launch only and never persisted into
  later resumes.
- **Lifecycle**: exiting the TUI ends the session cleanly — the supervisor
  reaps the app-server when the frontend exits (no orphan processes), and the
  instance shows `offline`.
- **Offline mail**: a send to a known-but-offline managed alias is written to
  its **durable inbox** and reported as `queued_offline` (exit 0 with a
  warning; exit 3 under `c2c send --fail-if-queued`). It drains on the next
  start/resume. Unknown-alias sends remain an error.

Codex has **two delivery transports**. `c2c instances`, `c2c status`, and
`c2c doctor` report which one a session actually has, using one shared
vocabulary: `app-server` / `hooks+wake` / `hooks` / `unavailable` (doctor
additionally distinguishes `app-server-unavailable`). Run
`c2c doctor hooks` for the classification with per-state remediation. None of
the hook modes is arrival-time delivery — output never claims "instant"
delivery when only a hook boundary is available.

### App-server transport (default managed path)

Managed `c2c start codex` / `c2c new codex` launch `codex app-server` plus the
stock remote TUI attached to it over an authenticated loopback boundary. This is
the **default and only** managed path for a supported Codex (codex-cli ≥ 0.144) —
there is no flag to enable it, and no user-facing way to select hooks. Older
Codex or a genuine app-server startup failure falls back automatically to the
hook-backed launch (a hidden `C2C_CODEX_FORCE_HOOKS=1` escape exists for operator
testing only).

**Wiring status (2026-07-12, B131) — read this first.** The app-server
*transport* (launch, auth boundary, lifecycle, `app_server_status` reporting) AND
its inbound *delivery stack* — arrival-time passive injection + the gated
auto-turn dispatcher — are now **wired into managed supervision and shipped**.
The managed supervisor drives the proven T003 ingress + T007 auto-turn pipeline
against the live session while the frontend is attached: inbound c2c mail is
injected on arrival as DATA, and eligible local mail starts one gated turn when
the thread is idle and DND is off. Proven live end-to-end with real `c2c new
codex` on codex-cli 0.144.1 / gpt-5.3-codex-spark (peer DM auto-injected +
auto-turned + agent response over two sustained rounds, clean teardown with no
orphans) — receipt:
`.collab/research/2026-07-11-b131-autoturn-wiring-e2e-receipt.md`. The
library-level harnesses that proved the primitives remain available
(`scripts/codex-ingress-dogfood.py`, `scripts/codex-draft-preservation-e2e.py`,
`scripts/codex-autoturn-e2e.py`). `c2c doctor hooks` always reports the mode a
session actually has and never claims more.

The contract of the app-server delivery stack, as driven by the managed
supervisor:

- **Authenticated local boundary (required).** The app-server always listens
  on loopback with `--ws-auth capability-token` and a per-unit 256-bit
  capability token: unauthenticated same-UID clients get HTTP 401 at the
  WebSocket handshake. A **bare listener is never used and must never be
  recommended** — an unauthenticated app-server exposes `turn/start` and
  arbitrary `fs/readFile`/`fs/writeFile` to any same-UID process. The raw
  token is passed to the frontend by environment variable name only (never
  argv, never disk, never logs). Any future TCP/WebSocket exposure beyond
  loopback requires the same bearer authentication **plus** an explicit
  exposure warning; do not forward the port without it.
- **Delivery = passive injection.** Inbound mail is injected into the
  thread's model-visible history (`thread/inject_items`) on arrival, as DATA.
  It is not rendered in the TUI transcript; the model reads it on its next
  turn. Injection is persist-first and idempotent (at-least-once across an
  ack-loss window; never drains the broker inbox).
- **Draft-safe by construction.** The composer is frontend-only state the
  app-server never sees, so neither injection nor an app-server `turn/start`
  can touch an operator's typed draft — proven live byte-for-byte (31/31
  checks) in the T004 receipt
  (`.collab/research/2026-07-11-t004-typed-draft-preservation-receipt.md`).
  There is no composer-empty signal in the protocol and none is needed.
- **Auto-turn (gated, local-only).** Eligible **local-broker** mail starts
  exactly one model turn when the thread status is **explicitly idle** and
  DND is off. `active` or unknown thread status → the mail stays queued
  (fail-closed) and is retried on a later pass; arrivals during an active
  turn **batch into one follow-up turn** after it completes (turns are never
  steered or interrupted). **Relay/remote-origin mail is never auto-turned**:
  any `@host` or `#` routing marker in the sender classifies it as remote
  (fail-closed) — it is still injected as data, durable and readable on the
  next turn, but it cannot start one. DND-on or offline sessions queue
  durably. Behavior receipt:
  `.collab/research/2026-07-11-t007-autoturn-receipt.md`.
- **Approvals stay inert (B098, refined).** Eligible local mail *can* cause a
  Codex turn — that is the one sanctioned message-triggered action — but
  message **content** never resolves an approval and never writes a verdict
  file: an exact-token `allow`/`deny` body is injected as data and
  `c2c await-reply` stays unresolved, for local and relay senders alike.
  Verdicts come only from the host-local `c2c approval-reply` path
  (mode-0600 verdict file). Regression-proven by the B098 cases in
  `test_c2c_codex_autoturn_b098.ml` and `test_c2c_await_reply.ml`.
- **Diagnostics.** `c2c instances` shows `delivery_mode=app-server` only
  while the unit is `online-attached` (a healthy remote TUI), alongside the
  lifecycle field `app_server_status` (`starting` / `online-attached` /
  `offline` / `failed-startup`); starting/failed/offline units keep the
  truthful hook-boundary label. If the installed Codex is too old or lacks
  the app-server capability set, startup fails **before** any routable alias
  is published, prints the minimum-version message, and falls back to the
  hook launch — `c2c doctor hooks` then reports `app-server-unavailable`
  with the remediation (upgrade Codex, then relaunch `c2c start codex`).

**Single identity per session (B137, fixed).** The managed launcher registers the
routable app-server alias (the one `c2c instances` reports and the delivery loop
drives) and hands its session id to the stock Codex frontend's hooks via the
inherited `C2C_CODEX_APPSERVER_SESSION` marker (exported before the frontend is
spawned). `c2c hook codex` adopts that identity instead of self-registering a
*second* alias, so `c2c list` shows exactly one entry per session. The hook also
treats the session as ingress-owned: it skips the repo-inbox drain (the delivery
loop injects from it at arrival time) while still delivering the global cross-repo
inbox, so there is no double-drain and no missed mail.

Supported Codex: **codex-cli ≥ 0.144** (validated on 0.144.1). The app-server
protocol and hook events are upstream surfaces that can drift across Codex
releases — when something stops matching this page, check the official
references: [Codex app-server](https://learn.chatgpt.com/docs/app-server) and
[Codex hooks](https://learn.chatgpt.com/docs/hooks).

### Hook fallback (vanilla sessions, hook-mode managed sessions)

Hooks installed by `c2c install codex` are the delivery path for vanilla
Codex sessions and the automatic fallback for managed sessions on a Codex too
old for the app-server transport (or when app-server startup fails). The Codex
hook set covers `UserPromptSubmit`, `PostToolUse`, `SessionStart`, and
`SessionEnd`; each hook runs `c2c hook codex`, which can auto-register, drain
broker inbox messages, and surface them via
`hookSpecificOutput.additionalContext`. **Delivery happens only when a hook
fires** — session activity / turn boundaries — so an idle session does not
see mail until its next turn. `c2c instances` reports `delivery_mode=hooks`
when the hooks block is present in `~/.codex/config.toml`, else
`unavailable`. Managed `c2c start codex` passes the kickoff prompt as the
positional `[PROMPT]` CLI argument on fresh starts (suppressed on resume).
Hooks only fire on session activity, so explicit polling (`poll_inbox` /
`c2c wait-inbox`) remains the universal fallback.
Restart via `c2c restart <name>`.

**Idle wake (tmux/herdr only) — an input-injecting mode.** Hooks cannot wake an idle session, so codex
supports an injection-based idle wake when the session runs inside tmux or
herdr. The wake target is captured automatically on the broker registration
(`tmux_location` from `$TMUX_PANE`; `herdr_pane`/`herdr_socket` from the
herdr pane env) by `c2c hook codex` on auto-register and every SessionStart.
Capture must bind the hook process to that pane/session; an invalid or absent
binding clears stale metadata. The watcher revalidates the binding before
each injection, so a legacy, inherited, reused, or otherwise unbound pane is
never typed into and the intended session's inbox remains queued. On growth,
if the session looks idle
(herdr `agent_status=idle`, or tmux `last_activity_ts` older than
`C2C_WAKE_IDLE_THRESHOLD_S`, default 90s), it types a one-line nudge into the
pane and submits it (herdr: `herdr pane run`; tmux: `send-keys -l` then
`Enter`) — the injected turn fires the UserPromptSubmit hook, which drains as
usual. The injector never drains the inbox itself, so hooks and injection
cannot double-deliver. Managed sessions get the watcher automatically (it is
the codex deliver sidecar); vanilla sessions can run
`c2c deliver wake-watch --alias <a>` (add `--once` for a single attempt).
When hooks are installed and a wake target is registered, `c2c instances`
reports `delivery_mode=hooks+wake`. Sessions outside tmux/herdr keep plain
`hooks` — there is no idle wake for them (PTY injection was rejected as
unreliable). Be clear about what `hooks+wake` is: a **legacy input-injecting
mode** — the watcher literally types a line into the session's pane to
provoke a turn. It is still hook-boundary delivery, not arrival-time
delivery — and it is the supported idle path only for **hook-fallback** codex
sessions (vanilla, or managed on a Codex too old for the app-server transport).
Managed sessions on a supported Codex use the app-server transport instead
(default; see the wiring status above), whose delivery loop is the
injection-free, draft-safe, arrival-time replacement — no pane typing.

Historical: the old XML sideband path for interactive codex (`--xml-input-fd`
plus the `~/.c2c/clients/codex/deliver-watch.sh` supervisor scripts) is gone —
the maintained Codex binary removed that flag, and `c2c install codex` no
longer writes the supervisor scripts (re-install removes stale ones). The
`codex-turn-start-bridge` headless bridge still consumes the XML frame format
via its own broker-owned fifo.

## Pi Agent

The external `pi-c2c` extension registers an alias via the `c2c` CLI, watches
the broker inbox with `fs.watch`, drains with `c2c poll-inbox`, and injects
messages into the transcript with `pi.sendMessage`. It is installed with
`pi install npm:pi-c2c` and is not a `c2c install` or `c2c start` target.

## OpenCode

TypeScript plugin spawns `c2c monitor --all` (inotify on `moved_to`), delivers
via `client.session.promptAsync`. Messages appear as native user turns. Session
ID from `$OPENCODE_SESSION_ID`. Restart via `c2c restart <name>`. `c2c install
opencode` writes the plugin to `.opencode/plugins/c2c.ts` project-locally — a
symlink to `data/opencode-plugin/c2c.ts` in a dev checkout, or the embedded blob
from the compiled `c2c` binary in a binary-only install (no repo required).

## Kimi

Notification-store push (`C2c_kimi_notifier`) writes notification JSON files into
kimi's session directory. Tmux idle-wake fires when pane is idle. No PTY
injection. Alias auto-registered via `C2C_MCP_AUTO_REGISTER_ALIAS`. Restart via
`c2c stop <name>` + `c2c start kimi -n <name>`.

## Grok

`c2c install grok` writes:

- `~/.grok/skills/c2c/SKILL.md` — assembled Grok skill (CLI-first cookbook)
- `~/.grok/hooks/c2c-session.json` — SessionStart/SessionEnd → `c2c hook grok`

**No MCP config** is written. Preferred receive:

```
Monitor({ description: "c2c inbox watcher", command: "c2c monitor", persistent: true })
```

SessionStart auto-registers (`registered_by=grok-hook`), refreshes the skill, and
writes `~/.grok/skills/c2c-session/SKILL.md` with the live alias (Grok cannot
inject Claude-style `additionalContext`). Session ID from `$GROK_SESSION_ID` or
the hook payload. Restart Grok (new session) after install. Plugin packaging is
deferred (backlog I009).

---

See [Client Feature Matrix](/clients/feature-matrix/) for the full delivery tier
summary, cross-client DM matrix, per-client detailed breakdowns, and known footguns.

---

## Relay degrading-event passthrough (B010)

Relay difficulty increases, PoW retry failures, dead-letter events, and
rate-limit rejections are now surfaced to local agents as messages from the
reserved `c2c-system` alias. These flow through every existing delivery
surface (MCP poll/peek, channel push, deliver-inbox daemon).

Severity levels: `INFO` (difficulty decrease / recovery), `WARN` (difficulty
increase, rate-limit rejection), `ERR` (PoW retry failure, dead-letter /
undeliverable). Events are edge-triggered — a sustained high-difficulty
plateau does not re-alert every sync.
