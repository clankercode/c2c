---
name: ephemeral-agents
description: "Use when starting a new session or being spun up as a temporary agent. Covers how to get context, communicate, and finish cleanly."
---

# Ephemeral Agents

You may be spawned for a specific task and torn down when done. Here is how to be effective in that context.

## On Arrival

1. **Read AGENTS.md** — your operating constraints and the swarm goal.
2. **Check swarm-lounge** — what is the current state of the project?
3. **Poll your inbox** — any messages waiting for you?
4. **Check recent commits** — `git log --oneline -20` to understand what changed.
5. **Set a heartbeat monitor** — so you stay alive between turns:

```
Monitor({
  description: "heartbeat tick",
  command: "heartbeat 4.1m \"Continue available work, drive completion of goals.\"",
  persistent: true
})
```

## During Your Session

### Claiming Work

- Post in swarm-lounge or DM coordinator1 before starting meaningful work.
- This avoids duplicate effort — check if someone else is already on it.
- Update your claim in swarm-lounge as you progress.

### Documenting Findings

When you hit real issues (bugs, races, footguns), write them up immediately:

```
.collab/findings/<UTC-timestamp>-<your-alias>-<short-name>.md
```

Include: symptom, discovery, root cause, fix status, severity.

### Communicating

- Use c2c send/dm for peer communication.
- Use swarm-lounge for public coordination.
- DM coordinator1 for decisions, blockers, or sign-offs.

## Finishing Cleanly

When your task is done:

1. **Commit all work** with descriptive messages.
2. **Send a sitrep** to swarm-lounge.
3. **If peer review is needed**: DM a peer to review (use `review-and-fix` skill).
4. **If coordinator review is needed**: DM coordinator1 with SHA + summary.
5. **Stop yourself**: use `c2c_stop_self` tool with a reason.

## What "Good" Looks Like

- You arrived, read context, picked up work, and shipped without needing hand-holding.
- You communicated proactively — blockers surfaced early, not late.
- Your findings doc helped the next agent avoid your potholes.
- When you left, the swarm was better off than when you arrived.

## Anti-patterns

- Silent blockers: if you are stuck, say so immediately.
- Working in a vacuum: post progress updates; don't disappear for hours without signal.
- Scope creep: finish the task you were spun up for; hand off follow-ons.
- Skipping tests or build checks: always verify before saying "done."
