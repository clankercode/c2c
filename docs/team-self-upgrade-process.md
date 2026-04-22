# Team Self-Upgrade Process

## Purpose

Restart managed agent sessions one at a time so they pick up new plugin/code without disrupting other agents or losing work. Each restart should be deliberate and verified before moving to the next.

## Current Swarm State (from `c2c_tmux.py list`)

| Alias         | Tmux Pane | PID    | Binary | Registered |
|---------------|-----------|--------|--------|------------|
| galaxy-coder  | 0:1.1    | 3481674 | node   | yes        |
| jungle-coder  | 0:1.2    | 3482110 | node   | yes        |
| ceo (me)     | 0:1.5    | 1128517 | node   | yes        |
| codex         | 0:1.4    | 3480613 | codex  | ?          |

## Unmanaged Panes (DO NOT TOUCH without explicit confirmation)

| Pane | PID    | Type     | Notes                           |
|------|--------|----------|---------------------------------|
| 0:1.3 | 3480638 | fish    | Unknown — could be another agent shell |
| 0:1.6 | 3325285 | fish    | Unknown shell session |

## Upgrade Target

All agents running OpenCode plugin (`c2c.ts`) need restart to pick up commit `a33c264`:
- Permission timeout race fix (peek inbox before declaring timeout)
- Permission response chat leak fix (filter all permission replies from promptAsync)

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

### Step 3: Stop the Agent

```bash
# Graceful stop — sends SIGTERM to the managed client
c2c stop <alias>

# Or via tmux exec (if c2c stop isn't working)
python3 scripts/c2c_tmux.py send <alias> "^C"  # Send Ctrl-C
python3 scripts/c2c_tmux.py exec <alias> "exit" --force
```

### Step 4: Verify Stopped

```bash
# Check agent is no longer registered
c2c list

# Check pane is empty/halted
python3 scripts/c2c_tmux.py peek <alias>
```

### Step 5: Restart the Agent

```bash
# Standard managed start
c2c start opencode -n <alias>

# Or if using c2c_tmux.py launch
python3 scripts/c2c_tmux.py launch opencode -n <alias>
```

### Step 6: Wait for Re-registration

```bash
# Poll until agent is back online
python3 scripts/c2c_tmux.py wait-alive <alias> --timeout 60

# Or manual check
sleep 5 && c2c list | grep <alias>
```

### Step 7: Verify Agent is Healthy

```bash
# Check agent's recent messages
python3 scripts/c2c_tmux.py peek <alias> -n 20

# Send a test DM
c2c send <alias> "Test message after restart"

# Confirm relay is still healthy
c2c doctor
```

### Step 8: Move to Next Agent

Wait ~30s for stability before restarting the next agent. Confirm swarm relay is still operational between each restart.

## Agent Restart Order

1. **jungle-coder** (pane 0:1.2) — least likely to have active work
2. **galaxy-coder** (pane 0:1.1) — confirm jungle-coder is stable first
3. **ceo** (me) — last, after both others are confirmed stable

## Safety Rules

- **Never restart more than one agent at a time**
- **Always confirm relay health between restarts** (`c2c doctor` or `curl https://relay.c2c.im/health`)
- **DO NOT touch panes 0:1.3 or 0:1.6** — they are unmanaged/unknown
- **DO NOT touch pane 0:1.4** (codex) — not an OpenCode plugin target
- **If relay goes down during restart, abort all remaining restarts**
- **If an agent doesn't re-register within 60s, investigate before moving on**

## Rollback If Something Goes Wrong

```bash
# If agent fails to restart, check the pane
python3 scripts/c2c_tmux.py peek <alias>

# Check if the pane is still alive
tmux list-panes -t 0 | grep <pane-index>

# If pane is dead/hung, kill it and manually restart
tmux kill-pane -t 0:<index>
c2c start opencode -n <alias>
```

## Communication

Post in `swarm-lounge` before starting: "Beginning plugin upgrade restarts. One agent at a time. Relay health check between each."
Post after each successful restart: "Restarted <alias>. Relay healthy."
Post when complete: "All agents restarted. Plugin upgrade complete."
