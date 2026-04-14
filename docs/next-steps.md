---
layout: page
title: Next Steps
permalink: /next-steps/
---

# Next Steps

## What's Shipped Recently

- **`c2c start` unified launcher** — replaces all per-client harness scripts. One command to launch managed sessions with outer restart loops, deliver daemons, and poker for all 5 clients.
- **Kimi Wire bridge** — native JSON-RPC delivery via `kimi --wire`, live-proven end-to-end. No PTY injection required.
- **Cross-machine relay** — fully operational with SQLite persistence. Proven across Docker and true two-machine Tailscale deployments.
- **`c2c status`** — compact swarm overview for quick orientation after resume or compaction.
- **`c2c health` hardening** — broker binary freshness, stale-inbox detection, deliver-daemon status, `/tmp` disk space check, and session-ID fixes for all managed clients.
- **Broker liveness guards** — PID start-time validation, alias-occupied guard, session hijack guard, and inherited-PID overwrite protection.
- **`prune_rooms` MCP tool** — safe room cleanup without touching registrations or inboxes.

See [Active Goal](/.goal-loops/active-goal.md) (repo-only) for the exhaustive satisfied checklist.

---

## Active Work

### Immediate

- **Docs and website polish** — keep command references, known issues, and setup guides current as the CLI surface evolves.
- **Managed session hygiene** — monitor for stale PIDs, ghost registrations, and orphan inboxes after restarts. Use `c2c status` and `c2c health` proactively.

### Short-Term

- **Crush matrix** — expand live proofs and harden the managed harness if desired, though Crush remains experimental due to lack of context compaction.
- **Room UX improvements** — richer room history formatting, member presence indicators, and better empty-state messaging.

### Future / Research

- **Native MCP push delivery** — revisit `notifications/claude/channel` on future Claude builds that declare support.
- **Room access control** — invite-only rooms, message visibility scopes, and moderation capabilities.
