# Public-docs accuracy triage: #356-#359

- **Filed**: 2026-05-04T02:30:00Z by birch-coder
- **Status**: TRIAGE CLOSED — mixed: 1 FIXED, 3 NOT REPRODUCIBLE
- **Class**: documentation / accuracy audit

## Summary

Coordinator assigned a sweep of `docs/` pages for accuracy issues tagged
#356 (MCP tools cards advertise nonexistent tools / miss shipped surface),
#357 (Crush parity inconsistency), #358 (relay-quickstart Python-centric),
and #359 (Setup table Kimi/Codex misleading).

Results: 1 genuine issue found and fixed; 3 were not reproducible — docs
were already accurate at time of audit.

---

## #356 — MCP Tools section missing shipped `schedule_*` tools

**Finding**: `docs/commands.md` — the Schedule section had a CLI subsection
but no MCP tools subsection. The MCP tools `schedule_set`,
`schedule_list`, and `schedule_rm` are shipped in the OCaml broker
(`ocaml/c2c_mcp.ml` lines 182-200, handlers at lines 296-301) but
were undocumented in the MCP Tools section of `commands.md`.

**Fix**: Added the missing `#### MCP tools` subsection to the Schedule
section in `docs/commands.md`, including full argument tables for
`schedule_set`, `schedule_list`, and `schedule_rm`.

**Also audited**: The issue mentioned `authorize`, `resolve-authorizer`,
and `refresh-peer` as nonexistent MCP tools. All three ARE real CLI
commands (verified against built binary). They are correctly placed in
the CLI section of `commands.md`, not advertised as MCP tools. No
action taken — docs were accurate.

**Also audited**: `set_compact` and `clear_compact` — both ARE present
in the MCP tools section of `commands.md` (lines 367-384). No action
taken.

**Committed**: `c9e8caab` on branch `docs-mcp-tools-fix` in worktree
`.worktrees/docs-mcp-tools-fix/`. Cherry-picked to master as `763b6f53`.

**Status**: FIXED.

---

## #357 — Crush parity inconsistency

**Audit scope**: All `docs/` pages for Crush references.

**Finding**: Crush is consistently marked DEPRECATED across all
documents. `docs/index.md`, `docs/overview.md`,
`docs/clients/feature-matrix.md`, `docs/commands.md`,
`docs/get-started.md`, `docs/known-issues.md`, and
`docs/MSG_IO_METHODS.md` all show the same accurate picture:
`c2c start crush` refuses (exit 1), `c2c install crush` warns but
still configures.

**Status**: NOT REPRODUCIBLE — docs are already consistent and accurate.

---

## #358 — relay-quickstart Python-centric

**Audit scope**: `docs/relay-quickstart.md`.

**Finding**: The relay quickstart is not Python-centric. Only two Python
references exist in the file:

1. `tests/test_relay_connector.py` — a test reference in the Docker
   cross-machine test section ("this is what the Phase-3 integration
   tests do automatically — see `tests/test_relay_connector.py` for the
   in-process equivalent"). This is an accurate technical reference.
2. `scripts/onboarding-smoke-test.sh` — a shell script reference in the
   Step 4 verification section.

All setup commands, server commands, connector invocations, and
deployment notes use OCaml/shell throughout. No Python-specific
installation instructions, no `pip` references, no virtual environment
setup.

**Status**: NOT REPRODUCIBLE — docs are accurate.

---

## #359 — Setup table Kimi/Codex misleading

**Audit scope**: Setup table in `docs/index.md` (lines 104-111).

**Finding**: The Kimi row reads:

```
| Kimi | Notification-store push | `c2c install kimi` writes MCP config;
`c2c start kimi` spawns the notifier daemon for auto-delivery. |
```

This correctly distinguishes `install` (MCP config only) from `start`
(spawns the notifier daemon for auto-delivery). The Codex row similarly
distinguishes install from managed session. No misleading content found.

**Status**: NOT REPRODUCIBLE — table is accurate.

---

## Notes

- `docs/relay-quickstart.md` also correctly references
  `c2c relay identity init` and `c2c relay identity show` (Ed25519
  identity commands) which are OCaml CLI commands shipped in the binary.
- `c2c doctor docs-drift` (static audit) reports one pre-existing
  finding in `CLAUDE.md:252`: `c2c_verify.py` is a deprecated Python
  script — out of scope for this cluster.
- Worktree `.worktrees/docs-mcp-tools-fix/` retains the fix commit
  `c9e8caab` and is eligible for GC after cherry-pick confirmation.

— birch-coder
