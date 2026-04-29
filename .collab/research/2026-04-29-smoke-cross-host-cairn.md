# SUBAGENT-IN-PROGRESS — smoke-cross-host

**Subagent**: cairn (subagent of coordinator1)
**Started**: 2026-04-29
**Slice**: smoke-test gap C — cross-host rejection regression guard
**Worktree**: `.worktrees/smoke-cross-host/`
**Source audit**: `.collab/research/2026-04-29-smoke-coverage-audit-cairn.md` (Proposal C)

## Goal

Add a section to `scripts/relay-smoke-test.sh` that:

1. Registers a fresh smoke alias (already done by section 2 of the script).
2. Sends to `<alias>@unknown-relay` (a non-self host).
3. Asserts the relay rejects with `error: "cross_host_not_implemented"`.
4. Asserts a `dead_letter` row appears via `GET /dead_letter`
   (admin-bearer; degrades to `info` if `C2C_RELAY_ADMIN_TOKEN` is unset).

Catches the silent-drop bug class fixed in `492c052b` / `4450cf56` (#379).

## Acceptance

- New section runs against deployed relay `https://relay.c2c.im`.
- Sub-check 1 (rejection shape) is hard PASS/FAIL — the real
  regression-catcher.
- Sub-check 2 (dead-letter row) is admin-conditional — degrades to
  `info` when the admin token is absent.
- No bash regressions in the existing 7 sections (script is idempotent
  per-run via `smoke-$(date +%s)` alias).
- Commit: `feat(smoke): cross-host rejection + dead-letter row guard`
  with `--no-build-rc:doc-only` (bash-script-only change, no OCaml
  rebuild required).

## Status

DONE — committed `02a15fbc` on branch `smoke-cross-host` in
worktree `.worktrees/smoke-cross-host/`.

Verified against `https://relay.c2c.im`:
- Section 8 sub-check 1 PASSED: "cross-host send rejected with
  cross_host_not_implemented (#379 silent-drop guard)".
- Sub-check 2 degraded to `info` ("dead_letter row check skipped (set
  C2C_RELAY_ADMIN_TOKEN to enable)") — expected, no admin token in
  smoke env.

Pre-existing failure in section 4 (loopback DM Ed25519 signature) is
NOT introduced by this slice; tracked separately.

Ready for peer-PASS handoff: SHA `02a15fbc`.
