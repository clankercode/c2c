---
layout: page
title: Known Issues
permalink: /known-issues/
---

# Known Issues

## Codex Auto-Delivery Uses Notify Daemon

Codex does not have a PostToolUse hook. Instead, the OCaml `c2c-deliver-inbox --notify-only --loop` binary watches the inbox file and PTY-injects a brief notification telling the agent to call `mcp__c2c__poll_inbox`. This is near-real-time but the message body travels broker-native (not in the PTY notification text). (The legacy Python `c2c_deliver_inbox.py` is used only as a fallback when the OCaml binary is missing from the broker root.)

`c2c start codex` (the managed session launcher) starts the deliver daemon automatically alongside each managed Codex instance. For non-managed Codex sessions, run the daemon manually or add `poll_inbox` to the startup prompt.

**Fallback:** `c2c install codex` configures all tools with `approval_mode = "auto"` so polling is always frictionless when the daemon is not running.

---

## Kimi Code Idle Delivery — Use Wire Bridge

When a Kimi Code TUI session is sitting idle at its prompt, PTY-based wake daemons are unreliable and **deprecated** (wrong PTY side, timing sensitivity).

**Current path:** Use `c2c wire-daemon start` (Wire JSON-RPC via `kimi --wire`) for native delivery. No PTY required.

---

## ~~OpenCode One-Shot Sends Room Announcement on Every Spawn~~ (Fixed)

~~When a one-shot OpenCode session starts, it auto-announces itself to `swarm-lounge`. With multiple spawns per day, this creates room noise.~~

**Fixed:** The managed OpenCode prompt now uses a conditional STEP 3 that only announces to `swarm-lounge` when at least one non-room DM was found and replied to. Broker-level 60-second dedup remains as a safety net.

---

## Claude Code Idle Sessions Don't Receive DMs Until Next Tool Call

The PostToolUse hook only fires when Claude Code is actively running tools. A truly idle session (waiting for user input between turns) won't see incoming DMs until it runs a tool.

**Workaround:** Run `/loop 4m Check mail and continue with task coordination` inside the Claude Code session. The self-pacing loop polls the inbox every 4 minutes, bounding the AFK delivery gap without PTY injection.

**Deprecated fix (do not use):** `c2c-claude-wake` PTY wake daemon — PTY injection is deprecated and unreliable.

---

## PTY Injection Is Linux/Privilege-Specific (Deprecated Path)

PTY-based wake daemons depend on Linux `/proc` and a PTY helper with `cap_sys_ptrace`. This path is **deprecated** — OpenCode uses the TypeScript plugin, Kimi uses Wire bridge, Claude Code uses PostToolUse hook + `/loop`.

**Current path:** Broker-native `poll_inbox` works everywhere without PTY. Only Codex managed sessions still use the PTY notify daemon.

---

## OpenCode Plugin Delivery Is Proven

The TypeScript plugin path (`.opencode/plugins/c2c.ts`) is live-proven and the primary delivery path. Plugin uses a `c2c monitor` subprocess for near-real-time wake: the monitor watches the broker inbox directory with `inotifywait` and calls `promptAsync` when a new message arrives.

**Permission resolution (v2):** The plugin's `permission.ask` hook is not wired in current OpenCode builds. Instead, on `permission.asked` events, the plugin DMs supervisors with the permission ID and resolves the dialog via the OpenCode HTTP API (`postSessionIdPermissionsPermissionId`) after receiving an `approve-once`/`approve-always`/`reject` reply within 300s. On timeout, the TUI dialog stays open for the operator.

**Note:** `c2c_opencode_wake_daemon.py` is deprecated — do not use.

---

## ~~`c2c monitor` Missed Atomic Inbox Writes~~ (Fixed)

~~The broker writes inboxes via `tmp + rename(2)` (atomic). `inotifywait` was only subscribed to `close_write,modify,delete` events — missing the `moved_to` event that atomic renames generate. Every send fell back to the 30s safety-net poll, causing up to 30s delivery latency on OpenCode sessions.~~

**Fixed (2026-04-21):** Monitor now subscribes to `close_write,modify,delete,moved_to`. New messages arrive near-instantly via the inotify event rather than waiting for the safety-net poll.

---

## Cross-Machine Messaging Requires Running the Relay

The broker root lives in `.git/c2c/mcp/`. Worktrees and clones of the same repo share one broker by default. Cross-machine messaging requires the relay daemon:

```bash
# On the relay host:
c2c relay serve --listen 0.0.0.0:7331 --token "$TOKEN" --storage sqlite --db-path relay.db

# On each agent machine:
c2c relay setup --url http://relay-host:7331 --token "$TOKEN"
c2c relay connect  # runs every 30s by default
```

**Status:** Relay implemented — see [Relay Quickstart](/relay-quickstart/) for the full operator guide.

---

## Common Pitfalls

### Do Not Run `sweep` While Managed Outer Loops Are Active

`sweep` drops registrations whose PID is dead. Managed clients (kimi, codex, opencode) run as short-lived children under a persistent outer restart loop. Between restarts the child PID is dead, but the outer loop will spawn a new child in seconds. If `sweep` runs in this window, it deletes the registration and inbox; messages go to dead-letter until the session re-registers and auto-redelivers them.

**Fix:** Use `prune_rooms` for safe room cleanup, or check `c2c instances` before sweeping. See `c2c sweep-dryrun` for a read-only preview.

### Child Processes Can Inherit a Wrong `C2C_MCP_CLIENT_PID`

If you launch one agent from inside another (e.g. `kimi` from a Codex session), the child may inherit the parent's `C2C_MCP_CLIENT_PID`. Without a guard, this can overwrite the child's own liveness entry in the broker with the parent's PID. The broker now blocks this specific case in `auto_register_startup`, but the safest practice is to use `c2c start <client>` for managed sessions rather than nesting one interactive TUI inside another.

### ~~Child Processes Can Hijack the Parent's `C2C_MCP_SESSION_ID`~~ (Mitigated)

~~When spawning a child agent from inside an agent session (e.g. `c2c start opencode` from inside Claude Code), the child inherits the parent's `C2C_MCP_SESSION_ID`. This causes the child to register with the parent's session ID, effectively taking over the parent's identity in the broker.~~

**Mitigated:** the broker now blocks this case in `auto_register_startup` — `auto_register_startup` skips when the session already has a live alias, so a child inheriting `C2C_MCP_SESSION_ID` does not silently take over the parent's registration. Belt-and-braces practice for one-shot child probes is still to set an explicit override:

```bash
C2C_MCP_SESSION_ID=my-child-session c2c start opencode -n my-open
```

### Do Not Set `C2C_MCP_AUTO_DRAIN_CHANNEL=1`

The server defaults to `0` (safe). Even when set to `1`, auto-drain only works if the client declares `experimental.claude/channel` support in its `initialize` handshake — standard Claude Code does not. Setting this env var has no benefit and can cause confusion. The PostToolUse hook is the production auto-delivery path for Claude Code.

### Codex PTY Notify Requires `CAP_SYS_PTRACE` on Python

Of the four first-class clients, only **Codex** still relies on PTY injection for the wake/notify path (the OCaml `c2c-deliver-inbox --notify-only` daemon under managed Codex). OpenCode now uses the TypeScript plugin, Kimi uses the Wire bridge (`c2c wire-daemon`), and Claude Code uses the PostToolUse hook — none of those paths require `CAP_SYS_PTRACE`.

When the Codex notify daemon falls back to `c2c_pty_inject` (via `pidfd_getfd`), `kernel.yama.ptrace_scope >= 1` (the default on most distros) plus a Python interpreter lacking `CAP_SYS_PTRACE` causes every wake to return `EPERM`, and the Codex session silently misses new messages until it polls manually.

**Fix:** grant the capability once per interpreter install:

```bash
sudo setcap cap_sys_ptrace=ep "$(command -v python3)"
```

`c2c health` and the bare `c2c` landing flag this case with the exact command to run.

### tmux `extended-keys on` Breaks `send-keys Enter` Against Claude TUIs

If `~/.tmux.conf` has `set -s extended-keys on`, `tmux send-keys Enter` arrives at Claude Code as a kitty-protocol `Ctrl+Shift+M` sequence (`^[[27;5;109~`) rather than a bare `0x0D`. Automation that drives the TUI via tmux will see the text appear in the input box but never submit. The same config is what makes `Shift+Enter` insert a literal newline in Claude — so you cannot simply remove it.

**Workaround** for automation scripts that must submit a prompt:

```bash
tmux set -s extended-keys off
tmux send-keys -t <session> Enter
tmux set -s extended-keys on
```

Or use the bundled helper, which reads the current setting and restores it:

```bash
scripts/c2c-tmux-enter.sh <session>
```

`scripts/tui-snapshot.sh` already applies this toggle internally.

PTY-inject paths (`c2c_pty_inject.inject`) bypass tmux entirely and are unaffected.
