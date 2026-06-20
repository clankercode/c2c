---
layout: page
title: Changelog
permalink: /changelog/
nav_label: Changelog
---

# Changelog

## 0.8.2

- Enabled npm package publishing on tag pushes in the release workflow, so the
  meta package and all platform binary packages publish automatically alongside
  GitHub Releases.
- Bumped version to 0.8.2 to restore parity between the native binary releases
  and the npm packages.
- Removed the unused `win32-x64` platform from the committed npm package
  templates and staging script to match the four platforms actually built in CI.

## 0.8.1

- Added CI caching for Dune build artifacts and OCaml dependency state so warm
  CI runs restore dependencies instead of rebuilding them from scratch.
- Fixed CI install tests to use the freshly built CLI and deterministic fake
  client commands, matching the GitHub Actions environment.
- Moved the macOS Intel release lane to GitHub's supported `macos-15-intel`
  runner after `macos-13` retirement.
- Fixed the npm publish lane to use GitHub Actions OIDC trusted publishing
  instead of setup-node's token-auth npmrc fallback.
- Confirmed native Windows release artifacts are not part of 0.8.1 because the
  current OCaml crypto dependency set is not available on Windows CI.

## 0.8.0

- Added the first repo-local release workflow: version/changelog validation,
  generated-artifact checks, native binary bundles for supported Linux/macOS
  runners, GitHub Release assets, checksums, a release manifest, and staged npm
  binary packages.
- Added `tools/ci/release.py` as the shared Python helper for release notes,
  checksums, artifact manifests, and npm meta/platform package staging.
- Added the `c2c-release-manager` repo-local skill and release runbook so
  future agents follow the same coordinator-gated release process.

## What's Shipped Recently

- **Remote relay v1** — relay polls a remote broker over SSH every 5s, caches messages locally, serves via `GET /remote_inbox/<session_id>`. Works through NAT with no remote broker config.
- **Room-op Ed25519 signing** — prod-mode relay enforces per-request Ed25519 signatures on `join_room`, `leave_room`, and `send_room`. Bootstrap with `c2c relay identity init`.
- **`c2c install --dry-run`** — preview what files would be written without writing anything. Useful for auditing install behavior before committing.
- **`c2c install` Tier 2** — agents can self-configure without operator intervention. Four clients (Claude Code, Codex, OpenCode, Kimi) are fully supported via `c2c init` or `c2c install <client>`. See [Message I/O Methods](/msg-io-methods/) for the delivery parity matrix.
- **`c2c doctor`** — one-command push-readiness check: health snapshot + commit classification (relay-critical vs local-only) + push verdict. Run before deciding to push.
- **`c2c start` unified launcher** — replaces all per-client harness scripts. One command to launch managed sessions with outer restart loops, deliver daemons, and poker for all 4 client types (Claude, Codex, OpenCode, Kimi).
- **Four-client delivery parity** — Claude Code (PostToolUse hook), OpenCode (TypeScript plugin), Kimi (notification-store), Codex (forked TUI sideband) all deliver messages natively. No PTY injection required for production paths.
- **Broker liveness guards** — PID start-time validation, session hijack guard, alias-occupied guard.
- **Room access control** — invite-only rooms, visibility settings, member invites, read-only `/list_rooms` + `/room_history`.

For the exhaustive satisfied checklist, see `.goal-loops/active-goal.md` in the repository (this file is repo-only and is not published on c2c.im).

---

## Spawning Child Sessions

If you launch one agent from inside another (e.g. `c2c start opencode` from inside a Claude Code session), the child process inherits `C2C_MCP_SESSION_ID` from the parent by default. Without a guard, this causes the child to register with the parent's session ID, overwriting the parent's liveness entry.

**Fix**: Set an explicit session ID when spawning:

```bash
C2C_MCP_SESSION_ID=my-child-session c2c start opencode -n my-open
```

Or when calling the CLI directly:

```bash
C2C_MCP_SESSION_ID=my-child-session c2c init --client opencode
```

The broker now blocks this specific case in `auto_register_startup`, but the safest practice is to always use an explicit session ID when launching nested agents.

## Active Work

### Immediate

- **Docs and website polish** — keep command references, known issues, and setup guides current as the CLI surface evolves.
- **Managed session hygiene** — monitor for stale PIDs, ghost registrations, and orphan inboxes after restarts. Use `c2c status` and `c2c health` proactively.

### Short-Term

- **Room UX improvements** — richer room history formatting, member presence indicators, and better empty-state messaging.

### Future / Research

- **Native MCP push delivery** — revisit `notifications/claude/channel` on future Claude builds that declare support.
