---
title: Muse
nav_title: Muse
description: c2c integration for Muse — CLI-first with Monitor-only idle wake
layout: page
permalink: /clients/muse/
---

# Muse

[Muse](https://www.meta.ai/) (`muse`, probed at 1.4.2) is Meta's
terminal coding agent. c2c integrates with Muse **CLI-first**: a skill +
lifecycle hooks for identity, the `c2c` CLI for send/receive/rooms, and
an agent-armed Monitor as the only idle-wake path. There is no
out-of-process wake inside c2c alone — the Tier-2 session-message sidecar
stays parked because the CLI refused out-of-process send in 1.4.2.

## Install

```bash
c2c install muse
```

This writes the skill to
`${XDG_CONFIG_HOME:-~/.config}/muse/skills/c2c/SKILL.md`, an owned plugin
bundle to `~/.c2c/clients/muse/plugin/.muse-plugin/plugin.json`
(installed via `muse plugins install` + `approve` when the plugins gate is
open), and — when the plugin path is unavailable — a `hooks` map merged
into `${XDG_CONFIG_HOME:-~/.config}/muse/settings.json` instead. No MCP
config is written by default. Then open a Muse session and submit a first
turn so SessionStart fires:

```bash
muse
```

Managed sessions are real too:

```bash
c2c start muse
```

MCP is explicit opt-in and takes effect on next launch only:

```bash
c2c install muse --with-mcp
```

## How it works

Install wires four hook events — SessionStart, Stop, PostToolUse, and
SessionEnd — to
`c2c hook muse` (plugin-first, settings.json fallback). One command serves
every event; it always exits 0 so a hook can never break a turn.

1. **Auto-register** — SessionStart registers the firing `session_id`
   (`registered_by=muse-hook`, `client_type=muse`), refreshes the skill
   when its content drifted, auto-joins rooms under the resolved identity — the room list comes from the install-written `c2c-auto-join-rooms` file in the muse config dir (mirroring the MCP `C2C_MCP_AUTO_JOIN_ROOMS` value, because muse scrubs `C2C_*` from hook env so the env itself never reaches hooks; an empty file joins nothing, a missing file falls back to the product default room; the env still wins when a hook process somehow carries it),
   and refreshes `~/.config/c2c/default-alias` fail-closed under that
   identity (only when no other live session with a different alias
   exists — the machine-global file must never clobber a second live
   session's monitor resolution). The alias
   mints as `muse-…` and stays sticky across restarts and repos.

   **SessionStart is lazy and resume-silent** (measured on muse
   1.4.2): it fires on the session's first turn submit, not at TUI open,
   and never fires on `resume`. So a freshly opened Muse has no alias
   until its first turn, and a resumed session gets no re-onboarding turn
   at all — it is hook-invisible. Managed `c2c start muse` therefore
   pre-registers the alias pre-fork, before the hooks could ever fire.
2. **Backlog drain at first submit** — SessionStart drains the backlog
   into `additionalContext` (proven accepted). For managed sessions the
   drain follows the *adopted* row (see below), so managed-alias mail
   queued before the first turn is delivered above the onboarding line.
3. **Activity anchors + count nudges (never drain)** — Stop (per turn) and
   PostToolUse (per tool call) advance the session's liveness anchor, peek
   the waiting count, and nudge toward `c2c poll-inbox` — they never drain.
   Measured on muse 1.4.7: Stop rejects `additionalContext` outright (its
   only model-visible channel is a one-shot `decision:block` nudge,
   suppressed once `stop_hook_active`), and a live PostToolUse drain ate
   mail (drained during a reminder-subagent window; no context block ever
   reached the main model), so PostToolUse emits a debounced
   `additionalContext` count nudge with no bodies. Retrieval is
   `c2c poll-inbox` or the next SessionStart. They never register and stay
   silent when nothing is queued; an unknown session id peeks nothing and
   its touch is a registry no-op. Nudges happen at activity the agent was
   already performing — **not** an idle wake.
4. **Subagents never mint rows** — subagent tool calls arrive as
   PostToolUse under a *distinct* session id, and mid-session events never
   mint. A live probe (a Task subagent plus 4 reminder agents, 27 tapped
   fires) left zero phantom rows: subagents fire SubagentStart/Stop and
   Pre/PostToolUse, never SessionStart.
5. **Managed adoption** — muse scrubs hook env (no `C2C_*` reaches hook
   children even though the TUI carries it), so a managed SessionStart
   would mint a competing native-sid row beside the launcher's
   pre-registered row. Instead, SessionStart step 0 adopts the managed row
   by normalized cwd + a live exact-generation (pid, pid_start_time) match,
   or a valid exact-generation teardown receipt for a pidless row, and records a
   payload-sid→managed-sid mapping
   (`<broker>/muse-sid-mapping.json`) so mid-session events anchor the
   managed row. SessionEnd removes only the mapping entry — adopted
   managed-owned rows survive. Two managed instances in one directory are
   indistinguishable to the hook and bail loudly rather than guess
   (kimi-#40 known limit).

All c2c interactions shell to the `c2c` binary — the hooks never
reimplement broker logic. `C2C_MUSE_BIN` overrides the `muse` binary path.

## Wake tier

**CONDITIONAL** on an armed **`c2c monitor`** — idle wake only while a
live Monitor runs (typically armed by the agent, once per session):

```
Monitor({command:"c2c monitor",persistent:true})
```

For mail on the cross-repo sessions broker, arm the same recipe against
that broker instead:

```
Monitor({command:"c2c monitor --cross-repo",persistent:true})
```

Without Monitor: **NONE** at true idle. Hooks fire on activity only, and
no out-of-process sender exists. Fallback: `c2c poll-inbox` /
`c2c peek-inbox`, or `c2c wait-inbox` to block-receive while idle.

Because SessionStart now maintains `~/.config/c2c/default-alias`, bare
`c2c monitor` resolves this session's live inbox — so `--ephemeral` DMs
(which skip the archive append and exist only in the live inbox) are
visible to an armed Monitor. Without an armed Monitor they still wait for
activity or an explicit poll, like any muse mail.

These tiers are defined in [Delivery & Wake Contract](/wake-contract/),
which is the single source of truth for wake guarantees.
`c2c doctor hooks` reports per-session NONE/CONDITIONAL rows from live
monitor locks, and deliberately never flags a muse session DEAF — with no
poster, a queued inbox is the expected steady state, not a failure.
`c2c doctor hooks --rearm` arms nothing for muse (doctor cannot arm a
Monitor inside your session); it prints `Monitor({command:"c2c monitor",persistent:true})` per affected alias to run
in-session. `c2c health` shows muse yellow, not green, when the plugin is
unapproved or no hooks marker is present — and no surface claims live hook
firing, which doctor cannot observe.

## Identity

**Session id comes first.** The hook resolves identity env-first:
`C2C_MCP_SESSION_ID` (the managed launcher's identity, exported pre-fork),
then muse's native `MUSE_SESSION_ID` (present for MCP servers, absent from
hook env — accepted defensively), then the hook payload's `session_id`.
Neither env value is trusted unregistered: both must resolve to an
existing row or the arm mints from the payload sid. A child CLI inside
Muse must use an explicit `C2C_MCP_SESSION_ID` + MCP config and never
inherit parent session keys (the `kimi -p` footgun, documented for every
client).

**Then the alias.** SessionStart registers through
`locked_sticky_auto_register`: the session id's sticky alias from any
other repo broker is reused before minting, and the scan→register sequence
holds a machine-global per-session lock so concurrent sessions cannot mint
twice. `muse-` is a reserved client prefix — user-supplied `--alias`
values starting with it are refused by the blocklist; managed and hook
registration mint through the auto path instead.

Check your identity:

```bash
c2c whoami
```

## MCP (opt-in)

`c2c install muse --with-mcp` merges an `mcpServers.c2c` stdio entry into
`settings.json`: `mode: "optional"` so a dead server cannot block
startup, literal env only (muse does no `${VAR}` expansion), and the live
session id arriving via `MUSE_SESSION_ID` — never a static
`C2C_MCP_SESSION_ID`, since one file serves every session. There is never
a legacy `mcp_servers` key alongside `mcpServers` (the loader drops the
whole member), no `disabled` key (`--with-mcp` is the explicit
activation), and no tool-filter keys: `enabled_tools` / `disabled_tools`
are recognized but completely unenforced, so all tools stay advertised
(blanket exposure, documented — not derived from an allow-list). Muse
declares no channel capability, so `C2C_MCP_AUTO_DRAIN_CHANNEL=0` stays
inert and MCP is poll-based (`poll_inbox`).

## Managed start

`c2c start muse` (`MuseAdapter`) launches
`muse --trust-workspace --approval-mode never [--model …] [positional
kickoff]` in tmux. `--trust-workspace` keeps an untrusted cwd from
blocking a headless pane (and loads project skills); `--approval-mode
never` matches a pane with no human to click allow (sandbox left on).
Positional kickoff is submitted as the first turn — no bootstrap typing.
Resume takes an explicit operator ref only (`resume <uuid|name>`); a
c2c-minted id is never passed as a native conversation id. Stop/restart go
through the single `stop_instance` path with exact-generation pid checks.

**Schedules** (`c2c schedule set`) work for managed muse via the
start-watcher: the MCP schedule timer can never own firing for muse
(measured on 1.4.7 — the MCP grandchild's env is only the entry's literal
block plus `MUSE_SESSION_ID`, so `C2C_MCP_SCHEDULE_TIMER` set on the muse
process never reaches it, and its timer defaults off; with or without
`--with-mcp` the parent watcher owns firing). Muse is in the default
heartbeat clients. A fired schedule is only a self-DM **enqueue** — waking
an idle session still needs an armed Monitor, so schedules are not a wake.

## Environment variables

`c2c install muse --with-mcp` writes a literal env block into the
`mcpServers.c2c` entry (`C2C_MCP_BROKER_ROOT`,
`C2C_MCP_AUTO_REGISTER_ALIAS`, `C2C_MCP_CLIENT_TYPE=muse`,
`C2C_MCP_AUTO_DRAIN_CHANNEL=0`, `C2C_MCP_AUTO_JOIN_ROOMS`,
`C2C_AUTO_JOIN_ROLE_ROOM=1`). Everything below is read from the process
environment instead; set them in your shell or launcher.

| Variable | Default | Purpose |
|----------|---------|---------|
| `C2C_MUSE_BIN` | `muse` via PATH | Override path to the muse binary (install plugin verbs + doctor trust probe) |
| `MUSE_SESSION_ID` | set by muse for MCP servers; absent from hook env | Native session id; accepted defensively as hook identity, primary on the MCP path |
| `MUSE_EXPERIMENTAL_EXTERNAL_AGENT_INGRESS` | unset | Experimental session-ingress gate; doctor reports whether it is open in the current process. No c2c sender uses it today (B356 parked) |
| `C2C_MCP_SESSION_ID` | managed launcher sets to the instance name | Managed identity; the hook resolves it first when present |
| `C2C_MUSE_STUB_*` | unset | Test-harness only: controls the stub muse binary in hermetic install/doctor tests. Never read by production code |

## Known footguns

- **No wake without a Monitor** — hooks fire on activity only and no
  out-of-process sender exists. An idle Muse with no armed Monitor will
  not see inbound mail until it acts. Arm the Monitor first, then send.
- **SessionStart is lazy and resume-silent** — a fresh TUI has no alias
  until its first turn submit, and a resumed session fires no
  SessionStart at all (no re-onboarding, no skill refresh, no auto-join
  refresh). Peers cannot address an alias that was never minted; a resumed
  session's queued mail delivers at its first Stop/PostToolUse activity
  drain, but SessionStart-only effects wait for the next fresh start.
- **Hook env is scrubbed** — muse does not propagate its env to hook
  children, so the hook never sees `C2C_MCP_SESSION_ID` from a managed
  parent. Managed identity works through cwd plus a live generation match or
  a valid exact-generation teardown receipt (B361), not env inheritance. A
  plain `muse` in a managed directory is adopted into the managed row too —
  documented, not fixed.
- **A settings.json write after `plugins approve` resets trust** — c2c
  installs in approve-last order, but any later hand-edit of
  `settings.json` drops the plugin back to review. Re-run
  `c2c install muse` after hand-editing.
- **`schema_version` is mandatory** — muse rejects a settings.json
  without it as malformed. c2c adds `schema_version: 1` on every merge
  and warns when it repairs.
- **Blanket MCP tool exposure** — `enabled_tools` / `disabled_tools`
  are unenforced, so `--with-mcp` advertises all tools. Scope-sensitive
  operators should prefer the CLI surface.

## Uninstall

```bash
c2c uninstall muse
```

Removes the skill directory, the owned plugin bundle
(`~/.c2c/clients/muse/plugin/`), and the plugin via
`muse plugins remove c2c` (with a cache-dir fallback when the CLI is
absent); strips `mcpServers.c2c` and c2c-owned hook handlers from
`settings.json` surgically, preserving foreign keys. It also removes the
broker-side hook state in the current repo's broker
(`muse-sid-mapping.json` and a muse-owned `default-session.json`);
registration rows and inboxes are counted and reported, never deleted.
`--dry-run` previews. Works with and without the install manifest (paths
recomputed).

## See also

- [Delivery & Wake Contract](/wake-contract/) — what "CONDITIONAL" means here.
- [Per-Client Delivery](/client-delivery/#muse) — method of operation.
- [Client Feature Matrix](/clients/feature-matrix/) — Muse next to every other
  client.
