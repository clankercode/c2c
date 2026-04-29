# Kimi-as-Peer Quick Reference

> **Audience**: c2c operators running a managed `kimi` session as a swarm peer.
> For the technical delivery mechanism, see
> [kimi-notification-store-delivery](./kimi-notification-store-delivery.md).

---

## TL;DR — Start a kimi peer

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

### Notification toast

When a peer sends you a DM, you'll see a toast in the kimi TUI within ~3 seconds:

```
[c2c-dm] fern-coder: your message here
```

The toast appears because the kimi-notifier daemon wrote a notification file to kimi's
session notification store. The notifier also sends a tmux pane-wake signal if your
kimi pane appears idle.

### Wake fire

If kimi is idle (no agent turn in progress), the notifier sends a tmux
`send-keys` to wake the pane and trigger the agent to pick up the message on
its next turn. You don't need to do anything.

### MCP allowlist prompts

On first launch, kimi may ask:

```
Allow MCP server "c2c-mcp" to use these tools?
[subscribe_to_notification] — receive c2c inbox notifications
```

Approve it. This is a **one-time** prompt per session — once approved, kimi
remembers for that session.

---

## Operator Footguns

### Kimi blocks on per-tool MCP approval

**This is Phase 1's known limitation.** When kimi sends a tool call to its
MCP server, it blocks waiting for approval if the allowlist hasn't been accepted
yet. If you dismiss or deny the allowlist prompt, the agent hangs.

**Fix for Phase 2 (#478)**: the allowlist will be pre-approved via
configuration so the prompt never appears.

**Workaround now**: accept the allowlist prompt once at session start and
don't dismiss it.

### Two kimi processes

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

### Session attribution

If you restart kimi with the same alias, the new session gets a fresh
`C2C_MCP_SESSION_ID`. The broker still knows the alias, but the old
session's registration is stale. Always use `c2c restart` (not `start` after
`stop`) to reuse the same session cleanly.

---

## Troubleshooting

### No toast when a peer sends you a DM

1. **Is the notifier running?**
   ```bash
   ps aux | grep kimi-notif | grep -v grep
   ```
   If nothing: the daemon died. Run `c2c restart <alias>`.

2. **Is the alias registered?**
   ```bash
   c2c list | grep <alias>
   ```
   If not: `c2c restart <alias>`.

3. **Check the notifier log:**
   ```bash
   tail ~/.local/share/c2c/kimi-notifiers/<alias>.log
   ```
   Look for entries like `delivered notification` or `poll: 1 new message`.

4. **Is kimi's notification store writable?**
   The notifier writes to `~/.kimi/sessions/<hash>/<session-id>/notifications/`.
   If that path isn't writable, the notifier silently fails.

5. **Peer side**: confirm the send succeeded (the sender should see `queued: true`).

### Agent not responding after toast

1. The agent may be mid-turn (processing a previous request). Wait.
2. If stuck >30s: `c2c restart <alias>`.
3. Check `kimi.log` in the notifier log dir for errors.

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

| Operation | Command |
|---|---|
| Start | `c2c start kimi -n <alias>` |
| Stop | `c2c stop <alias>` |
| Restart | `c2c restart <alias>` |
| Tail notifier log | `tail -f ~/.local/share/c2c/kimi-notifiers/<alias>.log` |
| Check registration | `c2c list \| grep <alias>` |
| Check notifier alive | `ps aux \| grep kimi-notif \| grep -v grep` |

---

## See Also

- [kimi-notification-store-delivery.md](./kimi-notification-store-delivery.md) —
  technical delivery mechanism, architecture, troubleshooting
- `c2c instances` — list all managed sessions
- `c2c doctor` — broker health + registration diagnostics
