# Muse parity gaps: documented/installed-but-inert class (T2/T4/T6)

Date: 2026-10-13T09:22:36Z · Scope: muse-parity branch, tasks T2/T4/T6
(cf. #50: a wake/delivery path can be documented, installed, and inert)
Severity: MEDIUM overall (no mail loss; silent no-ops on three shipped
surfaces, each contradicting its own docs). Wake tier unaffected: muse
stays NONE at true idle, CONDITIONAL only while `c2c monitor` is armed.

## T2 — Skill refresh defined and tested, never called

- **Symptom:** after a `c2c` upgrade, muse sessions kept the old `/c2c`
  skill forever unless the operator re-ran `c2c install muse`. Docs
  claimed SessionStart "refreshes the skill on drift only" in the present
  tense.
- **Root cause:** `C2c_setup.refresh_muse_skill_if_stale` existed with
  unit tests, but had zero call sites in the muse SessionStart hook —
  unlike the claude/kimi arms, which refresh on SessionStart.
- **Fix:** the muse SessionStart path now calls it best-effort (drift-only
  write, skill file only — never `settings.json`, whose rewrite resets
  plugin trust). Muse snapshots its skill catalogue at session start, so
  the refreshed skill is read by the *next* session (the #83 lag class).
- **Severity:** LOW (stale guidance only, but self-contradicting docs).

## T4 — Schedules double-broken for default (no-MCP) muse

- **Symptom:** `c2c schedule set` for a managed muse session never fired,
  silently — no error, no self-DM, no log line an operator would find.
- **Root cause:** two stacked defects. (1) Managed start hardcoded
  `C2C_MCP_SCHEDULE_TIMER=1`, which suppresses the start-watcher fallback
  on the assumption an MCP server runs the Lwt timer — but default muse
  installs no MCP server, so *neither* owner fired. (2)
  `default_heartbeat_clients` excluded muse, so no builtin heartbeat
  self-DM existed either. The "=1 means enabled" reading inverted the
  actual semantics: for no-MCP muse it meant suppression.
- **Fix:** one shared ownership decision
  (`schedule_timer_enabled_for_instance` in `ocaml/c2c_start.ml`): the
  timer env is "1" only when an MCP server will actually run for the
  instance (muse: an `mcpServers.c2c` entry in muse settings), else "0"
  and the watcher owns firing; an explicit operator
  `C2C_MCP_SCHEDULE_TIMER` still wins. Muse added to
  `default_heartbeat_clients`. Honesty retained: a fired schedule is a
  self-DM enqueue, not a wake.
- **Severity:** MEDIUM (a user-facing feature was a silent no-op on the
  default install shape).

## T6 — Rooms auto-join was MCP-only, so default muse never joined

- **Symptom:** a default (no-MCP) muse session registered fine but never
  joined `C2C_MCP_AUTO_JOIN_ROOMS` rooms (product default `swarm-lounge`),
  so room mail never reached it and peers saw it absent from the room.
- **Root cause:** the only consumer of `C2C_MCP_AUTO_JOIN_ROOMS` was MCP
  server startup. The muse hook path — the default identity/registration
  path — had no auto-join at all, and install writes the env only inside
  the MCP config a default session never runs.
- **Fix:** muse SessionStart joins after successful register/adopt, under
  the just-resolved identity (a B361-adopted row joins as the managed
  alias, never a freshly minted one), reusing the same env parsing and
  `Broker.join_room` call; env absent falls back to the product default
  room, env pinned empty joins nothing, per-room failures are best-effort.
  Joining is an install-time operator setting taking effect at
  registration — not a message-triggered action (B098-safe).
- **Severity:** MEDIUM (rooms are a product surface; absence was silent).

## The class, and the guard

All three share the #50 shape: the mechanism existed, was installed or
documented, and was inert because exactly one wiring step was missing —
and nothing observable complained. The parity pass therefore asserts each
surface end-to-end at its real entry point (hook e2e for T2/T6, managed
env/ownership tests for T4) rather than unit-testing the helper alone:
a tested helper with no call site is how T2 shipped. When adding a muse
surface, grep for the call site, not just the definition.
