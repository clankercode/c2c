# Hermes silent-card distribution handoff — 2026-10-23

## Ownership and scope

Base `d51e3bbd` already contains B378 (`335ec6a0`) and closes its backlog bug.
Its former worktree was clean. CLI DMs to `codex-thick-cache-ue0l` failed in both
sessions and repo brokers; `c2c list --global --json` contained no such alias.
No active B378 work was edited. This isolated branch updates canonical Hermes
skill/distribution safeguards, not the standalone repository or any deployment.

The actual Telegram sender is absent from this repository. Inspected companion
commit `0f909765945df3ab3aa2fe36a61698de8084cc40`, its shared SDK silent flag,
bidirectional all-chunk regression and `docs/upstream-silent-cards.md`.
Do not claim this upstream embed implements a sender that it does not ship.
Companion activation and its test counts were reported by the coordinator;
this worker did not rerun those tests or send a live canary.

## Result

- General-audience distribution comments at canonical plugin and skill entry.
- Canonical skill corrected for conditional wake, selected-ID ACK, current DATA
  envelope and companion-only silent-all-chunks contract.
- Read-only complete plugin/skill source-to-embed drift checker plus explicit
  optional installed-directory comparison; no profile discovery/mutations.
- Gate wired into `just check` and CI before build codegen can mask drift.
- Regression CLI test proves stale canonical skill, stale installed skill and
  a new omitted runtime module are rejected.
- Portable runbook and public client docs explain source → embed → rebuild →
  intended-profile install → supported reload, without user/LAN defaults.
- Canonical and embedded changelog updated; regenerated plugin embed.

## Verification

- RED: modifying canonical entrypoint without regenerating produced
  `embedded: stale __init__.py`, exit 1, and the positive gate test failed.
- GREEN: `just codegen-hermes-plugin codegen-changelog check-hermes-distribution
  codegen-changelog-check` passed. Mutation tests include their expected failures.
- Python focused suites: 72 cases, 7 skipped, passed; additional distribution
  plus actual-host-boundary module collection: 5 cases, 1 skipped, passed.
  These are separate commands with overlap, not a summed unique total.
- Fresh OCaml targets on x-tuf under `~/bb-src/c2c-hermes-silent-distribution`,
  `-j2`: setup Hermes 60 tests and changelog 23 tests passed.
- `git diff --check` passed. Full repository `just check`/full test suite not run.
- x-alpha DNS unavailable; used x-tuf. x-19 also did not resolve.
- No push, release, tag, runtime install, activation or canary in this lane.
- Parent to perform independent review, integration and any intended deployment.

## Protected edit denial (not retried)

Attempted tool: `functions.patch`, replace mode, target
`/home/xertrov/src/c2c/.worktrees/hermes-silent-distribution/AGENTS.md`.
It would insert a Hermes canonical skill/codegen workflow bullet immediately
before `Two build throttles exist`. The tool returned:

> BLOCKED: write to protected agent-instruction file(s) (AGENTS.md) requires approval but the approval request could not be delivered. The user has NOT consented to this write. Do NOT retry it or attempt the same edit via another path (terminal, execute_code, etc.).

No request ID, timestamp or pending-status field was returned. Event occurred
before the first successful generation/test batch, and before the coordinator's
10:37-era approval-race steering. Exact request time cannot be established from
this tool result; do not invent one. AGENTS.md remains untouched. No retry or
alternate write path used; workflow lives in the unprotected runbook and source
comments. Coordinator is investigating the separate expired-card race.
