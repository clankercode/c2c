# Idea: retire swarm-era config, kickoff strings, and related legacy

**Severity:** n/a (cleanup idea)
**Status:** idea only — **do not strip without a migration plan**
**Date:** 2026-07-14

## Context

After disbanding the agent-swarm experiment, several product surfaces still
carry swarm-era names and multi-agent process assumptions. Docs and
`AGENTS.md` have been reframed; code remains for compatibility.

## Candidates (consider, do not hard-delete blindly)

1. **`[swarm]` TOML table** in `.c2c/config.toml` (`restart_intro`, planned
   social-room / coordinator helpers). Still live. Prefer deprecate → rename
   → migrate rather than silent removal.
2. **Managed-session kickoff / restart intro strings** that tell agents to
   join rooms, post hellos, or follow swarm onboarding. Leave in place for
   now; consider shortening or operator-owned templates later.
3. **Coordinator / peer-PASS / sitrep CLI and runbooks** — runbooks already
   moved under `.collab/runbooks/deprecated/`. Code surfaces may remain useful
   as generic tools; evaluate separately.
4. **Default auto-join room** — tracked separately as rename bug for
   `swarm-lounge`.

## Non-goals

- Absolute removal of rooms, schedules, or multi-peer messaging — those are
  product features, not swarm process.
- Breaking existing configs on upgrade without a clear migration path.

## Related

- `.collab/findings/2026-07-14T00-00-00Z-rename-default-room-swarm-lounge.md`
- Root `AGENTS.md` / `CLAUDE.md` (solo-agent framing)
