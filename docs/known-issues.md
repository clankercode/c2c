---
layout: page
title: Known Issues
permalink: /known-issues/
---

# Known Issues

## Linux glibc floor for official release binaries (B190)

Official **Linux** release assets (`c2c-*-linux-x64.tar.gz`, `linux-arm64`, and the matching npm platform packages) are built on **Ubuntu 22.04** so the maximum required GLIBC symbol version stays at **2.35**.

| Distro | Typical glibc | Official release binary |
|--------|---------------|-------------------------|
| Ubuntu 22.04 / 24.04+ | 2.35 / 2.39+ | OK (with `libsqlite3` + `libgmp`) |
| Debian 12+ / RHEL 9+ | ≥ 2.35 | OK |
| Ubuntu 20.04 | 2.31 | **Fails** — build from source on the host |
| Alpine / musl | n/a | **Fails** — glibc-linked assets |

**Symptoms:**

```text
/c2c: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.38' not found (required by /c2c)
```

(or `GLIBC_2.35` / similar on hosts below the floor).

**Also required at runtime:** `libsqlite3.so.0` and `libgmp.so.10` (not statically linked).

**CI guard:** release builds run `scripts/check-glibc-max.sh 2.35` over shipped ELF binaries and a Docker smoke (`ubuntu:22.04` + those shared libs) on `c2c --version`.

**Local builds:** `just install-all` / host-built binaries inherit the builder's glibc. A rolling-distro build can require GLIBC 2.42 and fail even on Ubuntu 24.04. Prefer release assets, or build on a host no newer than your oldest target.

**Installer:** `docs/install.sh` preflights host glibc ≥ 2.35 on Linux and verifies the extracted binary before installing.

**Not yet shipped:** manylinux / fully static / musl artifacts for Ubuntu 20.04 and older.

---

## Codex Auto-Delivery (managed app-server + hook fallback)

**Managed Codex** (`c2c start codex` / `c2c new codex` on Codex ≥ 0.144): delivery is the **app-server** path (arrival-time inject, draft-safe, gated auto-turn for eligible local mail). Idle auto-turn is immediate; failed inject/auto-turn batches re-batch after ~2 minutes (B168). Full detail: [Client delivery](/client-delivery/).

**Vanilla / fallback:** hook-based, not XML sideband or PTY notify. `c2c install codex` writes `UserPromptSubmit`, `PostToolUse`, `SessionStart`, and `SessionEnd` hooks that run `c2c hook codex`. Those hooks can auto-register a vanilla Codex session, drain inbound broker messages, and surface them through `hookSpecificOutput.additionalContext`.

**Portable path:** explicit `mcp__c2c__poll_inbox {}` / `c2c poll-inbox` remains available when hook/app-server output is unavailable or after config changes that have not been picked up by a restarted Codex session. `c2c install codex` also configures c2c tools with `approval_mode = "auto"` so polling stays frictionless.

---

## Kimi Code Idle Delivery — REST Prompt Injection

When a Kimi Code TUI session is sitting idle at its prompt, PTY-based wake daemons are unreliable and **deprecated** (wrong PTY side, timing sensitivity).

**Current path:** `c2c start kimi` spawns the kimi notifier (`C2c_kimi_notifier`), which discovers the session id from `~/.kimi-code/session_index.jsonl` and POSTs inbound messages as user prompts to the Kimi Code local REST server (`/api/v1/sessions/{id}/prompts`). A tmux wake-prompt fires when the pane is idle. No PTY injection, no wire bridge. The legacy file-based notification-store is deprecated; unmanaged/serverless setups fall back to `c2c monitor`.

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

PTY-based wake daemons depend on Linux `/proc` and a PTY helper with `cap_sys_ptrace`. This path is **deprecated** — OpenCode uses the TypeScript plugin, Kimi uses REST prompt injection, Claude Code uses PostToolUse hook + `/loop`.

**Current path:** Broker-native `poll_inbox` works everywhere without PTY. Current production client integrations also avoid PTY injection: Claude Code uses PostToolUse hooks, Codex uses Codex hooks / managed app-server, OpenCode uses the TypeScript plugin, Grok uses CLI + Monitor + SessionStart hooks, agy uses CLI + hooks with agentapi wake via the deliver-watch sidecar, and Kimi uses REST prompt injection into the Kimi Code local server.

---

## OpenCode Plugin Delivery Is Proven

The TypeScript plugin path (`.opencode/plugins/c2c.ts` under the target project) is live-proven and the primary delivery path. In a dev checkout it symlinks to `data/opencode-plugin/c2c.ts`; in a binary-only install it is written from the embedded blob in the compiled `c2c` binary. Plugin uses a `c2c monitor` subprocess for near-real-time wake: the monitor watches the broker inbox directory with `inotifywait` and calls `promptAsync` when a new message arrives.

**Permission resolution (advisory-only, B098):** The plugin's `permission.ask` hook is not wired in current OpenCode builds. On `permission.asked` events, the plugin sends an **advisory** DM to supervisors with the permission ID — a notification that a permission is pending, not a control channel. It does **not** wait for a reply and does **not** resolve the dialog from any inbound message: the old message-driven wait loop and the `postSessionIdPermissionsPermissionId` POST of a message-derived decision were removed. A permission-shaped reply DM is surfaced into the transcript as plain data (via `surfaceAdvisoryMessage`) after identity validation — never translated into a verdict. The permission gate is resolved **only** by OpenCode's own local permission UI (host-local). See [Pending Permission RPCs](/security/pending-permissions/) for the full authority-boundary contract.

**Note:** `c2c_opencode_wake_daemon.py` is deprecated — do not use.

---

## ~~`c2c monitor` Missed Atomic Inbox Writes~~ (Fixed)

~~The broker writes inboxes via `tmp + rename(2)` (atomic). `inotifywait` was only subscribed to `close_write,modify,delete` events — missing the `moved_to` event that atomic renames generate. Every send fell back to the 30s safety-net poll, causing up to 30s delivery latency on OpenCode sessions.~~

**Fixed (2026-04-21):** Monitor now subscribes to `close_write,modify,delete,moved_to`. New messages arrive near-instantly via the inotify event rather than waiting for the safety-net poll.

---

## Cross-Machine Messaging Requires Running the Relay

The broker root lives at `$HOME/.c2c/repos/<fp>/broker` (the canonical default; see root `CLAUDE.md` "Key Architecture Notes" for the full resolution order). Worktrees and clones of the same upstream share one broker by default. Cross-machine messaging requires the relay daemon:

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

`sweep` drops registrations whose PID is dead. Managed clients (kimi, codex, opencode, claude) run as short-lived children under a persistent outer restart loop. Between restarts the child PID is dead, but the outer loop will spawn a new child in seconds. If `sweep` runs in this window, it deletes the registration and inbox; messages go to dead-letter until the session re-registers and auto-redelivers them.

**Fix:** Use `prune_rooms` for safe room cleanup. Before sweeping, prefer `c2c instances --json` to confirm no managed sessions are mid-restart; if you need a process-level check, look for active `c2c start <client>` managed instances rather than the deprecated `run-*-inst-outer` scripts. See `c2c sweep-dryrun` for a read-only preview.

### Child Processes Can Inherit a Wrong `C2C_MCP_CLIENT_PID`

If you launch one agent from inside another (e.g. `kimi` from a Codex session), the child may inherit the parent's `C2C_MCP_CLIENT_PID`. Without a guard, this can overwrite the child's own liveness entry in the broker with the parent's PID. The broker now blocks this specific case in `auto_register_startup`, but the safest practice is to use `c2c start <client>` for managed sessions rather than nesting one interactive TUI inside another.

### ~~Child Processes Can Hijack the Parent's `C2C_MCP_SESSION_ID`~~ (Mitigated)

~~When spawning a child agent from inside an agent session (e.g. `c2c start opencode` from inside Claude Code), the child inherits the parent's `C2C_MCP_SESSION_ID`. This causes the child to register with the parent's session ID, effectively taking over the parent's identity in the broker.~~

**Mitigated:** the broker now blocks this case in `auto_register_startup` — `auto_register_startup` skips when the session already has a live alias, so a child inheriting `C2C_MCP_SESSION_ID` does not silently take over the parent's registration. Belt-and-braces practice for one-shot child probes is still to set an explicit override:

```bash
C2C_MCP_SESSION_ID=my-child-session c2c start opencode -n my-open
```

### Do Not Remove the `C2C_MCP_AUTO_DRAIN_CHANNEL=0` Override

The server default for `C2C_MCP_AUTO_DRAIN_CHANNEL` is `1` (ON) since #346. However, `c2c install` writes `C2C_MCP_AUTO_DRAIN_CHANNEL=0` into each client's MCP config to override this. Even when set to `1`, auto-drain only fires if the client declares `experimental.claude/channel` support in its `initialize` handshake — standard Claude Code does not — so in practice the drain has no effect there. Do not remove the `=0` override that install writes; the PostToolUse hook is the production auto-delivery path for Claude Code.

### Codex PTY Notify Capability Notes Are Historical

Codex no longer relies on the PTY notify path for production delivery. Use the Codex hooks installed by `c2c install codex`, plus explicit `poll_inbox` fallback, instead of granting `CAP_SYS_PTRACE` for Codex delivery.

Historical PTY helpers such as `c2c_pty_inject` may still be useful for diagnostics or older experimental paths. If you deliberately run those legacy paths on Linux with `kernel.yama.ptrace_scope >= 1`, they can still require `CAP_SYS_PTRACE`; that requirement does not apply to current Codex hook delivery.

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
