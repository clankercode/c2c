# Team Self-Upgrade Process

## Purpose

Restart managed agent sessions one at a time so they pick up new plugin/code without disrupting other agents or losing work. Each restart should be deliberate and verified before moving to the next.

## Current Swarm State

Re-check this before EVERY restart — pane assignments shift after each restart.

```bash
python3 scripts/c2c_tmux.py list
tmux list-panes -t 0 -F '#{pane_index}: #{pane_current_command} (pid #{pane_pid})'
```

| Alias         | Tmux Pane | Pane PID | Client PID | Notes                    |
|---------------|-----------|----------|------------|--------------------------|
| galaxy-coder  | 0:1.1    | 3481674  | 2888002    | active, doing GUI work   |
| jungle-coder  | 0:1.3    | 3480638  | 3018822    | restarted, session resumed but context may differ |
| ceo (me)     | 0:1.5    | 1128517  | 2967087    | this session             |

## Unknown/Unmanaged Panes (DO NOT TOUCH without explicit confirmation)

| Pane Index | PID    | Type  | Notes                                |
|------------|--------|-------|--------------------------------------|
| 2          | 3482110 | fish  | Old jungle-coder pane (detached)    |
| 4          | 3480613 | codex | Codex session                       |
| 6          | 3325285 | codex | Second codex / unknown               |

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

### Step 6: Restart the Agent — USE TMUX LAUNCH ONLY

```bash
# MUST use c2c_tmux.py launch — never run `c2c start` directly from bash.
# `c2c start` from bash does NOT register properly; the agent becomes a stray orphan.
# NOTE: launch reuses idle panes — always use --new-window to avoid pane conflicts.
python3 scripts/c2c_tmux.py launch opencode -n <alias> --new-window
```

**Session resume caveat**: `c2c_tmux.py launch` passes `--session` from `opencode-session.txt`,
which should trigger OpenCode's resume. However, session context (conversation history) may not
fully transfer — jungle-coder lost its conversation thread after a restart even with the same
`ses_*` ID. Always verify the agent remembers what it was doing.

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

1. ✅ **jungle-coder** (pane 0:1.3) — DONE, but session context was partially lost
2. **galaxy-coder** (pane 0:1.1) — next, confirm jungle-coder is stable first
3. **ceo** (me) — last, after galaxy-coder is confirmed stable

## Safety Rules

- **Never restart more than one agent at a time**
- **Always confirm relay health between restarts** (`c2c doctor` or `curl https://relay.c2c.im/health`)
- **DO NOT touch pane 2** (3482110) — old detached jungle-coder fish shell
- **DO NOT touch pane 4** (3480613) — Codex session, not OpenCode
- **DO NOT touch pane 6** (3325285) — unknown/second Codex
- **Use `--new-window` when launching** — avoids pane-reuse bugs that orphan sessions
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
