---
name: stop-hook-poker-design
description: Max's design guidance for c2c poker stop hook behavior
type: reference
---

# Stop Hook / Poker Design (Max 2026-04-24)

**Context**: c2c poker should work easily in an agent's bash tool without blocking.

## Requirements

1. **Non-blocking**: run in agent's bash tool without blocking the agent
2. **PTY injection**: primary path when available
3. **tmux fallback**: if PTY injection unavailable but agent runs in tmux, detect session/window/pane and use tmux injection
4. **Fork-off**: poker process forks off after injecting PID, doesn't hold agent process
5. **Broad launch support**: works across variety of launch situations (as many as possible)

## Supported paths (desired)

- PTY injection (primary)
- tmux injection (fallback when PTY unavailable but tmux available)
- Any other practical similar methods

## Open questions

- How does poker detect which method to use?
- What is the signal mechanism for tmux detection?
