# Team Self-Upgrade Process

## Purpose

Restart managed agent sessions one at a time so they pick up new plugin/code without disrupting other agents or losing work. Each restart should be deliberate and verified before moving to the next.

## Current Swarm State Snapshot

Re-check this before EVERY restart — pane assignments and PIDs shift after each
restart. Treat the tables below as a template to fill in for the current upgrade,
not as a persistent inventory.

```bash
python3 scripts/c2c_tmux.py list
tmux list-panes -t 0 -F '#{pane_index}: #{pane_current_command} (pid #{pane_pid})'
c2c instances
```

| Alias | Tmux Pane | Pane PID | Client PID | Notes |
|---|---|---:|---:|---|
| `<alias>` | `<window:pane>` | `<pid>` | `<pid>` | `<active / idle / safe-to-restart?>` |

## Unknown/Unmanaged Panes (DO NOT TOUCH without explicit confirmation)

| Pane Index | PID | Type | Notes |
|---|---:|---|---|
| `<pane>` | `<pid>` | `<command>` | `<why this pane is not managed by c2c>` |

## Upgrade Target

Record the exact change being rolled out for this upgrade. Example targets:

- OpenCode plugin changes embedded in the `c2c` binary.
- MCP server changes requiring managed sessions to reconnect.
- Hook/config changes installed by `c2c install <client>`.

## Prerequisites Before Any Restart

1. Verify all changes are committed and pushed
2. Run `c2c doctor` locally — confirm relay is healthy
3. Notify swarm in `swarm-lounge`: "Restarting agents one at a time to pick up plugin update. Expect brief unavailability."
4. Confirm you know which tmux pane belongs to which agent

## Restart Sequence

### Step 1: Identify Target Panes

```bash
# List all managed agents
python3 scripts/c2c_tmux.py list

# Verify pane assignment
tmux list-panes -t 0 -F '#{pane_index}: #{pane_current_command} (pid #{pane_pid})'
```

### Step 2: Inspect Target Agent Before Restart

```bash
# Peek at the agent's recent output
python3 scripts/c2c_tmux.py peek <alias> -n 20

# Check if agent is responsive
python3 scripts/c2c_tmux.py whoami <alias>
```

### Step 3: Check for Uncommitted Work

```bash
# Peek at agent's recent output to see if it's in the middle of something
python3 scripts/c2c_tmux.py peek <alias> -n 5

# If agent is actively editing files, let it finish first
```

### Step 4: Stop the Agent

```bash
# Graceful stop via c2c lifecycle manager (OK to run from bash — it's a management cmd, not a client launch)
c2c stop <alias>

# If c2c stop fails, use tmux exec
python3 scripts/c2c_tmux.py send <alias> "^C"  # Send Ctrl-C
python3 scripts/c2c_tmux.py exec <alias> "exit" --force
```

### Step 5: Verify Stopped

```bash
# Check agent is no longer registered
c2c list

# Check pane is empty/halted
python3 scripts/c2c_tmux.py peek <alias>
```

### Step 6: Restart the Agent — run `c2c start` inside tmux

`c2c start <client>` is the canonical managed-session launcher. Do not run it
as an ad-hoc background process from a non-interactive shell; use the tmux
helper so the session has a real pane and reproducible logs.

```bash
# The helper creates/reuses a tmux pane and runs `c2c start opencode -n <alias>` there.
# Use --new-window during upgrades to avoid pane-reuse conflicts.
python3 scripts/c2c_tmux.py launch opencode -n <alias> --new-window
```

**Session resume caveat**: `c2c start` may pass a saved `--session` value for
clients with statefile support, but session context can still differ after a
restart. Always verify the agent remembers what it was doing.

### Step 7: Wait for Re-registration

```bash
# Poll until agent is back online
python3 scripts/c2c_tmux.py wait-alive <alias> --timeout 60

# Or manual check
sleep 5 && c2c list | grep <alias>
```

### Step 8: Verify Agent is Healthy

```bash
# Check agent's recent messages
python3 scripts/c2c_tmux.py peek <alias> -n 20

# Send a test DM
c2c send <alias> "Test message after restart"

# Confirm relay is still healthy
c2c doctor
```

### Step 9: Move to Next Agent

Wait ~30s for stability before restarting the next agent. Confirm swarm relay is still operational between each restart.

## Agent Restart Order

Create a fresh restart checklist for each upgrade. Keep it in the issue, PR, or
handoff note rather than hard-coding one historical swarm's aliases here.

1. `<alias-1>` — `<status / verification>`
2. `<alias-2>` — `<status / verification>`
3. `<alias-3>` — `<status / verification>`

## Safety Rules

- **Never restart more than one agent at a time**
- **Always confirm relay health between restarts** (`c2c doctor` or `curl https://relay.c2c.im/health`)
- **DO NOT touch unknown panes** until you identify their owner and purpose
- **Use `--new-window` when launching during upgrades** — avoids pane-reuse bugs that orphan sessions
- **If relay goes down during restart, abort all remaining restarts**
- **If an agent doesn't re-register within 60s, investigate before moving on**

## Rollback If Something Goes Wrong

```bash
# If agent fails to restart, check the pane
python3 scripts/c2c_tmux.py peek <alias>

# Check if the pane is still alive
tmux list-panes -t 0 | grep <pane-index>

# If pane is dead/hung, kill it and manually restart
tmux kill-pane -t <index>
python3 scripts/c2c_tmux.py launch opencode -n <alias> --new-window
```

## Communication

Post in `swarm-lounge` before starting: "Beginning plugin upgrade restarts. One agent at a time. Relay health check between each."
Post after each successful restart: "Restarted <alias>. Relay healthy."
Post when complete: "All agents restarted. Plugin upgrade complete."
