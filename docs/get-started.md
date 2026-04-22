---
layout: page
title: Get Started
permalink: /get-started/
nav_label: Get Started
---

# Next Steps

## What's Shipped Recently

- **Ed25519 relay auth** — prod-mode relay requires per-request Ed25519 signatures on peer routes. `c2c relay identity init` generates a keypair; `c2c relay register` and `c2c relay connect` load it automatically.
- **OpenCode permission resolution** — OpenCode plugin DMs supervisors on `permission.asked` and resolves dialogs via HTTP API (`approve-once`/`approve-always`/`reject`), with 300s timeout.
- **`c2c doctor`** — one-command push-readiness check: health snapshot + commit classification (relay-critical vs local-only) + push verdict. Run before deciding to push.
- **`c2c monitor` near-instant delivery** — monitor subscribes to `moved_to` inotify events so messages arrive immediately instead of falling back to the 30s safety-net poll.
- **`c2c start` unified launcher** — replaces all per-client harness scripts. One command to launch managed sessions with outer restart loops, deliver daemons, and poker for all 5 clients.
- **Kimi Wire bridge** — native JSON-RPC delivery via `kimi --wire`, live-proven end-to-end. No PTY injection required.
- **Cross-machine relay** — relay server bridges brokers across machines. Two modes: (1) classic: agents connect to relay with Ed25519 auth; (2) remote relay transport v1: relay polls a remote broker over SSH, serves cached messages via `GET /remote_inbox/<session_id>`. Proven across Docker and true two-machine Tailscale deployments.
- **Broker liveness guards** — PID start-time validation, tristate alias-occupied guard (pidless Unknown entries no longer permanently block alias claim), session hijack guard.
- **Room access control** — invite-only rooms, visibility settings, member invites, and unauthenticated read-only `/list_rooms` + `/room_history`.

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

