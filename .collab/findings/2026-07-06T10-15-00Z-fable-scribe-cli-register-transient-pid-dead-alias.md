# CLI register captures transient pid → alias instantly dead + unroutable

**Symptom.** After a zero-env `c2c register --alias fable-scribe` from a Claude
Code Bash-tool shell, `c2c send fable-scribe ...` from any peer fails with
`error: alias 'fable-scribe' is not registered.` even though `c2c whoami` and
`c2c find fable-scribe` both show the registration. `c2c find` shows state
`dead`.

**Root cause.** `c2c_register_cmd.ml` resolves the registration pid as
`C2C_MCP_CLIENT_PID` env → else `Unix.getppid ()`. From an agent harness shell
(Claude Bash tool, codex shell tool), the parent process is the transient
per-command shell, which exits immediately. The registration is therefore
born dead, and send-side alias resolution skips dead registrations.

Discovered live 2026-07-06 while dogfooding the vanilla-codex friction fixes
(session fable-scribe). Verified fix-by-hand: walking `/proc` ancestry to the
long-lived `claude` process (pid 3167872) and re-registering with
`C2C_MCP_CLIENT_PID=3167872` made the alias alive + routable; a live
`wait-inbox` round-trip then succeeded.

**Two secondary UX defects:**
1. `c2c send` reports a dead-pid registration as "is not registered" —
   misleading; should say the alias exists but its process looks dead, and
   suggest re-registering (or route anyway with a warning).
2. `c2c migrate-broker` (XDG split-brain default path) copies data but leaves
   the source XDG-profile broker's `registry.json` in place, so the
   split-brain stderr warning keeps firing after a "successful" migration.
   (The #9 slice's e2e asserted source removal in the legacy-path case; the
   XDG-profile case with pre-existing historical inboxes behaves differently
   — 1 copied, 4 skipped, source left intact.)

**Fix direction (follow-up slice).**
- Shared helper: walk `/proc` ancestry from ppid upward; pick the first
  ancestor whose cmdline identifies a known agent binary (claude / codex /
  kimi / opencode / pi / node runner) — or whose environ carries the same
  session id — and use that pid. Fall back to **pid=None** (unknown liveness
  is routable; dead is not) rather than a doomed getppid.
- Adopt the helper in `c2c register`, `c2c init`, and the codex hook
  auto-register path (steered in-flight to use pid=None meanwhile).
- Fix the dead-alias send error text; decide whether unknown/dead liveness
  should block routing at all for statefile-backed CLI sessions.
- Make migrate-broker remove (or tombstone) the source XDG registry so the
  warning goes quiet after migration.

**Severity:** high for vanilla/CLI-only onboarding (the exact surface the
2026-07-06 friction batch targets) — zero-env register works but produces an
unroutable identity, which reads as "c2c is broken" to a fresh agent.
