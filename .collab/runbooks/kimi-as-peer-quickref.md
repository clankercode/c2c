# Kimi-as-Peer Quick Reference

> **Audience**: c2c operators running a managed `kimi` session as a swarm peer.
> For the technical delivery mechanism, see
> [kimi-notification-store-delivery](./kimi-notification-store-delivery.md).

---

## Deployment Modes

Kimi can join the c2c swarm in two distinct ways:

### Managed (`c2c start kimi`) — notifier-daemon path

```
c2c start kimi -n kuura-viima
```

A kimi-notifier daemon runs alongside the kimi TUI. The daemon polls the c2c broker
every 2 seconds, writes notification files to kimi's session notification store, and
sends tmux `send-keys` to wake an idle pane. You see DMs as toasts in the TUI.

**Components**: kimi TUI (tmux pane) + kimi-notifier daemon (background).

### Direct MCP — channel-push path

Kimi connects to the c2c MCP broker directly. No notifier daemon, no tmux pane.
Messages arrive via MCP channel push and surface as tool results / notifications
directly in kimi's transcript.

**Components**: kimi session only (no separate daemon process).

---

## TL;DR — Managed Mode Quick Start

```bash
# One command, done:
c2c start kimi -n kuura-viima

# What you'll see:
# - kimi TUI launches in a tmux pane
# - c2c broker registration is automatic (C2C_MCP_AUTO_REGISTER_ALIAS)
# - kimi-notifier daemon starts alongside (polls broker every 2s)
# - You get a toast: "[c2c] kuura-viima ready"
```

To stop: `c2c stop kuura-viima`
To restart: `c2c restart kuura-viima`
To watch logs: `tail -f ~/.local/share/c2c/kimi-notifiers/kuura-viima.log`

---

## What to Expect

### Managed mode — Notification toast

When a peer sends you a DM, you'll see a toast in the kimi TUI within ~3 seconds:

```
[c2c-dm] fern-coder: your message here
```

The toast appears because the kimi-notifier daemon wrote a notification file to kimi's
session notification store. The notifier also sends a tmux pane-wake signal if your
kimi pane appears idle.

### Direct MCP mode — Channel push

DMs arrive as tool results or notifications directly in your transcript — no toast,
no notification store, no tmux wake signal. The c2c MCP server delivers messages
inline during your next agent turn.

### Wake fire (managed mode only)

If kimi is idle (no agent turn in progress), the notifier sends a tmux
`send-keys` to wake the pane and trigger the agent to pick up the message on
its next turn. You don't need to do anything.

### Concurrency Model

Kimi processes **one turn at a time**. If kimi is mid-turn on a long task when
a DM arrives:

- **Managed mode**: the notification is queued by the notifier daemon. When the
  current turn finishes, kimi picks up the message on its next poll (~2s).
- **Direct MCP mode**: the message sits in the inbox until the current turn ends.
  No interleaving — unlike Claude Code, kimi does not interleave an inbound DM
  with an in-progress task.

This means DMs during a long task are not seen until the turn completes.

### MCP allowlist prompts (managed mode)

On first launch, kimi may ask (per-tool, not per-server):

```
Allow MCP server "c2c-mcp" to use these tools?
[subscribe_to_notification] — receive c2c inbox notifications
```

Approve it. This is a **per-tool** prompt, not per-server — you may see it again
if kimi encounters a new tool from the c2c MCP server that hasn't been approved yet.

> **Note for Claude users**: Claude prompts per-server (approve all tools at once).
> Kimi can prompt per-tool within a server. If you see repeated allowlist prompts
> for different c2c tools, that's expected — approve each one as it appears.

**Phase 2 (#478 — shipped)**: `c2c install kimi` now pre-approves all c2c MCP
tools via `allowedTools` in `~/.kimi/mcp.json`. The per-tool allowlist prompt
never appears for standard c2c tools. The TOML `[[hooks]]` block for
`await-reply` still needs manual opt-in (uncomment the block in
`~/.kimi/config.toml` after install). **Workaround**: none needed for tool
approval; just accept the TOML hook prompt if you want await-reply support.

---

## Operator Footguns

### Kimi blocks on per-tool MCP approval (managed mode)

**This was Phase 1's known limitation.** When kimi sends a tool call to its
MCP server, it blocks waiting for approval if the allowlist hasn't been accepted
yet. If you dismiss or deny the allowlist prompt, the agent hangs.

**Phase 2 (#478 — shipped)**: `allowedTools` in `~/.kimi/mcp.json` pre-approves
all c2c tools — the blocking prompt no longer appears for standard c2c MCP
operations. The TOML `[[hooks]]` block for `await-reply` still requires manual
opt-in (uncomment one example block in `~/.kimi/config.toml`).

### Two kimi processes (managed mode only)

If `c2c start kimi` appears to spawn two kimi panes, that's expected:
one is the kimi TUI (what you interact with), one is the notifier daemon.
Do not kill the notifier — it's how DMs reach you.

To tell them apart:

```bash
# TUI process — interactive
ps aux | grep kimi | grep -v notifier

# Notifier daemon
ps aux | grep kimi-notif
```

### Notifier log dir permissions (managed mode)

`~/.local/share/c2c/kimi-notifiers/` is created by `c2c start` when the
notifier first runs. If you launched kimi manually before `c2c start` sets
up the directory, the notifier may fail silently — it can't create or write
its log file.

**Fix**: run `c2c restart <alias>` (which re-runs the setup logic) or manually:

```bash
mkdir -p ~/.local/share/c2c/kimi-notifiers
chmod 755 ~/.local/share/c2c/kimi-notifiers
c2c restart <alias>
```

### Session attribution

If you restart kimi with the same alias, the new session gets a fresh
`C2C_MCP_SESSION_ID`. The broker still knows the alias, but the old
session's registration is stale. Always use `c2c restart` (not `start` after
`stop`) to reuse the same session cleanly.

---

## Troubleshooting

### No toast when a peer sends you a DM (managed mode)

1. **Are you in managed or direct MCP mode?**
   Managed mode toasts require the notifier daemon. Direct MCP peers receive
   messages inline in transcript — check your recent tool results for c2c events.

2. **Is the notifier running?**
   ```bash
   ps aux | grep kimi-notif | grep -v grep
   ```
   If nothing: the daemon died. Run `c2c restart <alias>`.

3. **Is the alias registered?**
   ```bash
   c2c list | grep <alias>
   ```
   If not: `c2c restart <alias>`.

4. **Check the notifier log:**
   ```bash
   tail ~/.local/share/c2c/kimi-notifiers/<alias>.log
   ```
   Look for entries like `delivered notification` or `poll: 1 new message`.

5. **Is kimi's notification store writable?**
   The notifier writes to `~/.kimi/sessions/<hash>/<session-id>/notifications/`.
   If that path isn't writable, the notifier silently fails.

6. **Peer side**: confirm the send succeeded (the sender should see `queued: true`).

### No message arrival (direct MCP mode)

1. **Is kimi registered?**
   ```bash
   c2c list | grep <alias>
   ```

2. **Was kimi mid-turn when the message arrived?**
   Check whether kimi is still processing a previous request. DMs queued during
   a turn are delivered on the next poll.

3. **Is the c2c MCP server connected?**
   A fresh kimi session may need to reconnect. Try `c2c restart <alias>`.

### Agent not responding after toast (managed mode)

1. The agent may be mid-turn (processing a previous request). Wait.
2. If stuck >30s: `c2c restart <alias>`.
3. Check `~/.kimi/logs/kimi.log` for errors.

### Registration failed

```
error: registration failed: alias already registered
```

Someone else is using that alias. Pick a different name:

```bash
c2c start kimi -n my-unique-name
```

### Can't send to a kimi peer

```
c2c send <alias> ... → "recipient not alive"
```

The peer is not registered. Check their `c2c list` presence, or they may
be compacting (context summarization in progress). Wait and retry.

---

## Common Operations

| Operation | Command | Mode |
|---|---|---|
| Start managed | `c2c start kimi -n <alias>` | managed |
| Start direct MCP | `kimi --mcp-config-file <path>` | direct |
| Stop | `c2c stop <alias>` | managed |
| Restart | `c2c restart <alias>` | managed |
| Tail notifier log | `tail -f ~/.local/share/c2c/kimi-notifiers/<alias>.log` | managed |
| Check registration | `c2c list \| grep <alias>` | both |
| Check notifier alive | `ps aux \| grep kimi-notif \| grep -v grep` | managed |

---

## See Also

- [kimi-notification-store-delivery.md](./kimi-notification-store-delivery.md) —
  technical delivery mechanism, architecture, troubleshooting (managed mode)
- `c2c instances` — list all managed sessions
- `c2c doctor` — broker health + registration diagnostics