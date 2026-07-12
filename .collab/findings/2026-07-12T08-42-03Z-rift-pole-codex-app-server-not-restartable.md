# Codex app-server sessions are not restartable through managed-instance lifecycle

**Severity:** high for I010 / `c2c restart-stale`
**Status:** open; prerequisite lifecycle work required
**Discovered:** 2026-07-12T08:42:03Z during I010 feasibility review

## Symptom

A live managed Codex app-server session cannot be enumerated and restarted by
the existing `c2c instances` / `c2c restart <name>` path.

## Discovery

- `C2c_codex_session.run_app_server` writes `codex-session.json` and
  `codex-app-server.json`, but not the normal managed-instance `config.json`
  and `outer.pid` consumed by `C2c_start.cmd_instances` and `cmd_restart`.
- `cmd_restart` begins with `load_config_opt`; an app-server-only session
  therefore fails before any restart action.
- The app-server TUI inherits the launcher's terminal. Spawning `c2c resume
  codex` from a batch/coordinator process would attach the replacement TUI to
  the wrong terminal rather than replacing the unit in its existing pane.
- The mapping is initially written before a Codex thread is discovered. The
  later discovered thread ID is not written back on the observed path; sampled
  live mappings lacked `thread_id`, so exact transcript resumption is not yet
  dependable.

## Root cause

The app-server launcher is a distinct lifecycle model that has not been folded
into the config-backed managed-instance abstraction. It lacks an in-place
self-reexec/control seam and durable late-bound thread-ID persistence.

## Required fix direction

Before I010 can claim Codex app-server support:

1. persist launcher identity and the discovered thread ID;
2. enumerate app-server units as managed restart targets;
3. add an in-place restart/self-reexec mechanism that retains the controlling
   TTY/pane and resumes the exact Codex thread;
4. gate Codex restart on authoritative app-server thread Idle state (active or
   unknown must skip unless explicitly forced);
5. prove ledger/inbox once-only delivery and recovery with a real tmux-managed
   Codex session.
# Fix status

Resolved by B153: app-server launchers now persist normal managed-instance
identity/PID state and late-discovered thread identity. Restart uses a persisted
control request consumed by the owning launcher, is authoritatively idle-gated
unless forced, and re-execs in place on the exact thread so the pane/TTY and
broker-ledger idempotency boundary are retained.
