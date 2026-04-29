# Findings backlog triage 2026-04-28

**Author:** stanza-coder
**Date:** 2026-04-28T04:22:30Z

## Summary

- Total findings examined: **329** (`.collab/findings/*.md`)
  - 2026-04-25 .. 2026-04-28: **132** triaged in detail
  - 2026-04-13 .. 2026-04-24: **197** grouped by theme (per "prioritize 04
    + group older" rule)
- OPEN-ACTIONABLE: **8** late + ~6 themes from older window
- OPEN-OBSERVATIONAL: **9** late + ~5 themes from older window
- RESOLVED (suggest archive): **~30** late + the bulk of older 13-24 batch
  (resolved by sweep migration, broker-fp #294, send-memory #286, etc.)
- STALE: **~12** late (peer-review notes, heartbeat scratch, drill logs)
  + many older
- UNCERTAIN: **6** late

Note: report covers the full 329 but groups the older slab — full per-file
verdicts would exceed the 2000-word cap. The shape below should let
swarm-mates jump straight to the live items.

---

## OPEN-ACTIONABLE

Genuine bugs, code path still vulnerable, clear next step.

- **2026-04-28T03-35-00Z-stanza-coder-335-resume-drain-nudge-flood.md** —
  on `c2c start` resume, inbox dumps 18+ stale `[c2c-nudge]` lines that
  bury real DMs; affects opencode worse than claude. **Next:** filter
  expired/duplicate nudges in resume drain, or TTL them at write time
  (#335 is filed; needs a slice).
- **2026-04-27T02-19-53Z-stanza-coder-send-memory-handoff-no-dm.md** —
  intermittent #286 send-memory DM dropouts. #327 added broker.log
  diagnostic but root cause not yet found. **Next:** wait for next
  intermittent miss + correlate broker.log.
- **2026-04-26T11-56-18Z-stanza-coder-channel-tag-reply-illusion.md** —
  channel-tag transcript injection looks like a chat thread; agents
  reply in plain text and the reply never reaches sender. UX trap, not
  a code bug. **Next:** transcript wrapper that ends with explicit
  "to reply, call mcp__c2c__send" footer; or strip channel tag from
  visible transcript.
- **2026-04-26T09-50-00Z-galaxy-coder-295-opencode-first-msg-delivery-race.md** —
  #295 partially fixed (964c1646 session-id alias guard) but
  first-message race in OpenCode plugin not fully closed. **Next:**
  finish galaxy's investigation; this is the load-bearing path for
  cross-client DM.
- **2026-04-26T05-47-00Z-coordinator1-c2c-monitor-fork-bomb.md (#288)** —
  `c2c monitor --alias` leaks ~70 procs/alias; root of "MCP feels
  absent" reports. `b276550d feat(doctor): add c2c doctor monitor-leak`
  added detection but not prevention. **Next:** fix the spawn loop in
  whichever component re-spawns monitors without reaping.
- **2026-04-26T01-08-00Z-test-agent-mcp-outage.md** + companion
  **2026-04-26T01-25-00Z-coordinator1-test-agent-mcp-recovery-took-them-down.md** —
  `./restart-self` outside an outer-loop kills the inner client with
  no auto-restart. Documented in CLAUDE.md but the footgun is still
  live. **Next:** make `restart-self` refuse to run when no outer-loop
  wrapper or `c2c start` parent is present.
- **2026-04-25T08-19-24Z-lyra-quill-problems-log.md** — Codex agents
  do not receive automatic 4-min heartbeat ticks. **Next:** verify
  whether `c2c start codex` arms the heartbeat (the file says no);
  wire it if missing.
- **2026-04-25T08-17-00Z-test-agent-class-f-sweep-c2c-start-miss.md** —
  `sweep` only checks for legacy `run-*-inst-outer`, not `c2c start`
  managed sessions. Drops messages to dead-letter for recoverable
  sessions. **Next:** add `pgrep -f "c2c start"` to the guard.

## OPEN-OBSERVATIONAL

Symptom real, but speculative / low priority / no clear fix yet.

- **2026-04-27T14-00-00Z-galaxy-coder-self-review-guard-subagent.md** —
  Task-tool subagents inherit parent session alias, so peer-pass
  rejects them. Structural; documented as not-a-peer-PASS already.
- **2026-04-27T03-45-00Z-test-agent-poll-inbox-mystery.md** — `#310`
  multi-container; superseded by 2026-04-27T10-30-00Z which has the
  full root-cause chain (now mostly RESOLVED — see below).
- **2026-04-26T08-30-00Z-galaxy-coder-worktree-dune-build-root-fail.md** —
  `dune build --root /worktree` fails when launched from main repo
  cwd; workaround is `cd worktree && dune build`. Tooling friction,
  not a c2c bug.
- **2026-04-26T06-27-00Z-galaxy-push-incident-postmortem.md** —
  unauthorized stats-bot pushes to origin/master; pre-push hook
  shipped per the timeline. Awaiting Max guidance on origin
  reconciliation. Tracking-only.
- **2026-04-26T06-08-05Z-lyra-codex-mcp-stale-transport.md** — Codex
  MCP `Transport closed`; recovery via SIGUSR1 already documented.
  Recurrence pattern; no obvious code fix.
- **2026-04-26T03-58-00Z-jungle-coder-idle-nudge-status.md** —
  inventory of relay_nudge implementation, no bug; may want to
  fold into a runbook.
- **2026-04-26T00-38-17Z-lyra-cross-machine-onboarding-gaps.md** —
  cross-machine onboarding requires hosted-relay config not in repo;
  design-class observation, not actionable as a slice yet.
- **2026-04-25T07-30-00Z-stanza-coder-papercuts-class.md** — Class A-G
  living catalogue. Class E (shell-substitution warn) and Class F
  (sweep) have follow-up findings; rest still being patched as they
  surface.
- **2026-04-25T05-07-00Z-jungle-coder-agent-worktree-launch-gap.md** —
  agents can't `cd` themselves into a worktree post-launch; resolved
  by `c2c start --worktree` flag landing later this window —
  **possibly RESOLVED**, please verify.

## RESOLVED (suggest archive)

Underlying issue fixed in a later slice; finding can be moved to
`.collab/findings-archive/`.

Late window (2026-04-25 .. 28):

- 2026-04-27T02-00-00Z-test-agent-326-memory-list-shared-with-me — #326,
  fix `03556323` / `a70b32df` docs. Self-marked RESOLVED.
- 2026-04-27T10-30-00Z-test-agent-310-mesh-test-poll-drains-inbox —
  fixes landed `1aab345b`, `e01ad504`, `42fec5b7`, `c7d467ba` (#310
  Docker lease + test fixes).
- 2026-04-27T02-25-00Z-test-agent-install-force-precedent — workflow
  guidance; not a bug, archive as docs.
- 2026-04-26T08-41-00Z-test-agent-phase-c-test-findings — Phase C
  Docker tests, fixes landed in 3dd2e5ac.
- 2026-04-26T09-40-00Z-test-agent-phase-d-kimi-docker-validation — same.
- 2026-04-26T08-30-00Z-galaxy-coder-doctor-e2e-test-findings — fix in
  4e0dfbe / `c2c doctor` updated.
- 2026-04-26T08-17-00Z-test-agent-#286-peer-pass-fail — test
  registration; addressed before #286 landed (69385108).
- 2026-04-26T04-30-00Z-jungle-coder-312-codex-harness-fd-leak — fixes
  90659978, 98ab3ca8, 197ef07e, 3a80aafc, a2c83003 (#312 chain).
- 2026-04-26T02-37-00Z- + 2026-04-26T06-38-00Z- codex-exit-hang —
  partial; may need verification that #312 chain closed it.
- 2026-04-26T04-26-01Z-codex-cc-quota-divergence — patched per the
  finding's own status line.
- 2026-04-26T01-20-00Z-test-agent-self-pass-detector-bugs — `fb220de`
  case-insensitive needle fix.
- 2026-04-26T17-10-00Z-test-agent-codex-sandbox-broker-path —
  validation for #294; #294 landed (61e4210c). Archive.
- 2026-04-26-test-agent-failover-drill-consolidated — drill complete,
  runbook updated; archive as historical.
- 2026-04-26T10-35-00Z-stanza-coder-313-worktree-gc-manual-test-log —
  #313/#314 landed (0cf4a840, 5409e6ef). Archive.
- 2026-04-25T15-50-00Z-coordinator1-peer-review-partial-build-gap —
  peer-PASS rubric updates landed (#324 95742634). Archive.
- 2026-04-25T13-12-00Z-test-agent-forkpty-linux — pty Slice 1 build
  fix; build-green now. Archive.
- 2026-04-25T13-20-00Z-test-agent-binary-locked — install-guard
  handles "Text file busy" via atomic rm+cp (CLAUDE.md notes this).
  Archive.
- 2026-04-25T13-10-00Z-jungle-coder-alcotest-test-count-mismatch —
  alcotest tooling quirk; tests pass via `dune runtest`. Archive.
- 2026-04-25T11-20-00Z-stanza-coder-codex-deliver-unavailable —
  config.toml `[default_binary] codex` documented; CLAUDE.md captures
  the workaround. Archive.
- 2026-04-25T10-04-00Z-stanza-coder-class-e-proof-in-wild — Class E
  shell-substitution warn behavior verified working as designed.
- 2026-04-25T10-04-00Z-jungle-slice2-audit — closed by author.
- 2026-04-25T09-45-00Z-jungle-coder-stickers-cross-worktree-bug —
  fixed via #173 git_common_dir_parent migration.
- 2026-04-25T07-01-30Z-coordinator1-deferrable-flag-ignored-on-push —
  fixed via #303 (5213af7b, 80a8bea5).
- 2026-04-25T03-10-00Z-stanza-coder-signed-pass-reveals-path-bug —
  per-alias key path migration; per finding's status line.
- 2026-04-25T02-23-00Z-test-agent-ocaml-match-precedence-bug-165 —
  fixed in #165 chain.
- 2026-04-25T02-12-00Z-test-agent-t_to_json-signature-bug — fix
  landed; signature roundtrip test added.
- 2026-04-25T02-11-00Z-galaxy-Phase3-dune-bug — fix `b6942b3`.
- 2026-04-25T01-57-00Z-galaxy-coder-claude-agent-model-rejection —
  fix in c2c_role.ml Claude_renderer.
- 2026-04-25T01-17-30Z-coordinator1-cold-boot-hook-empty-payload —
  superseded by #317 (b34370f4 post-compact context injection).
- 2026-04-25T01-12-00Z-test-agent-git-repo-toplevel-audit — audit
  closed; remediations landed in #173 et al.
- 2026-04-25T01-11-00Z- + 2026-04-25T01-10-00Z- — peer-review notes
  with PASS verdicts. Archive as historical (or move to
  `.collab/peer-pass/` if that exists).
- 2026-04-25T00-43-00Z-coordinator1-dockerfile-opam-drift — fixed at
  226ef47 + c4b7db9.

Older window (2026-04-13 .. 24): the bulk of these are RESOLVED by
later work. Themes (and approximate counts) most-likely archivable:

- **Sweep / managed-session liveness** (~15 findings, days 13-22):
  largely subsumed by `c2c start` migration + #313/#314 worktree gc
  + sweep guard updates. Some still relevant — see Class F open item.
- **Broker path / .git RO sandbox** (~12 findings): closed by #294
  per-repo fingerprint broker root (61e4210c, 86d27089).
- **OpenCode plugin drain / first-message race** (~10): partly closed
  by #295 (964c1646); residual race tracked in galaxy's open finding.
- **PID staleness / alias hijack** (~8): closed by stale-MCP detection
  design (c6283d83) + a512bdc6 runtime identity.
- **Permission forwarding for Codex** (~6): repeatedly filed,
  partially addressed; see UNCERTAIN below.
- **Restart-self / outer-loop death** (~6): documented in CLAUDE.md;
  Class A-pattern still recurs but flagged.

## STALE

- All 2026-04-25T15-1[4-9]*-jungle-coder-heartbeat-* and
  -skills-lost-in-phase3 — short heartbeat scratch logs, content
  already absorbed into runbooks.
- 2026-04-26T01-35-00Z-galaxy-coder-mcp-disconnect — same
  symptom-class as the 01-08 outage finding, dedupes into #288.
- 2026-04-25T11-10-00Z-stanza-coder-194-live-smoke-attempt — smoke
  log; outcome captured in 2026-04-25T11-20-00Z deliver-unavailable
  finding.
- 2026-04-25T10-28-00Z-jungle-coder-per-agent-worktrees-lost —
  incident log of `git reset --hard` losing 5 commits; lesson
  absorbed into git-workflow runbook.
- 2026-04-25T10-16-37Z-lyra-quill-dune-verification-hang — one-off
  `dune build` hang; not reproduced since.

For the older 13-24 window, dozens of small day-of incident logs
(`heartbeat`, `pkill killed swarm`, `jungle vs jungel typo`) read as
STALE — info has migrated into CLAUDE.md and runbooks. Recommend a
sweep-archive of any 13-22 finding whose status line says FIXED /
documented / closed.

## UNCERTAIN

Need author follow-up before classifying.

- **2026-04-25T12-35-21Z-lyra-codex-permissions-recurrence.md** +
  **2026-04-25T10-47-04Z-lyra-codex-vs-opencode-perm-path.md** +
  **2026-04-25T10-41-45Z-lyra-codex-permission-forwarding-still-broken.md** +
  **2026-04-25T04-35-00Z-galaxy-coder-132-codex-permission-forwarding-gap.md** —
  four findings on Codex permission-forwarding gap. No commit log
  reference shows a fix landed. Need lyra-quill or galaxy to confirm
  whether #194 / #132 produced shipping code or if it's still open.
- **2026-04-25T07-55-00Z-coordinator1-c2c-restart-killed-jungle.md** —
  `c2c restart` SIGTERM path; coordinator1 to confirm whether
  cmd_restart was patched after this incident.
- **2026-04-25T15-14-27Z-jungle-coder-skills-lost-in-phase3.md** —
  short note about origin/master being at 7b68fde; needs check
  whether skills-loss has recurred since.
- **2026-04-25T05-07-00Z-jungle-coder-agent-worktree-launch-gap.md** —
  finding says "fix should be in #165"; #165 landed but unclear if
  the cwd-on-launch path covers all cases. Verify.
- **2026-04-25T09-04-00Z-jungle-slice1-orphan-inbox-gap.md** — Slice 3
  was supposed to address this; status unclear.

## Recommended next moves

1. Archive the ~30 RESOLVED late-window findings into
   `.collab/findings-archive/` in one batch (low-risk; status lines
   already say FIXED).
2. Sweep the older 13-24 window with a similar pass — most are
   absorbed by #294, #295, #286, #310, #312, #313/#314, #317, sweep
   migration, or have moved into runbooks.
3. The 8 OPEN-ACTIONABLE items above are real swarm work; #335
   resume-drain nudge flood is the freshest, then the recurring
   monitor-leak (#288) and OpenCode first-msg race (#295 residual).
4. The Codex permission-forwarding cluster (4 findings) needs an
   owner — currently nobody is driving it.

— stanza-coder
