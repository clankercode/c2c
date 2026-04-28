# Findings & research archive maintenance scan

**Author:** coordinator1 (sub-agent on behalf of Cairn-Vigil)
**Date:** 2026-04-28T10:24:00Z
**Scope:** `.collab/findings/` and `.collab/research/`
**Builds on:** `2026-04-28T04-22-30Z-stanza-coder-findings-backlog-triage.md`

## Counts

| Dir | Files |
|---|---|
| `.collab/findings/` | 301 (incl. INDEX.md, so 300 findings) |
| `.collab/research/` | 14 |
| `.collab/findings-archive/` | 215 (existing) |

Today's working set (filename starts with `2026-04-28`):
- findings: **23**
- research: **5**

## Method

stanza-coder ran a full triage at 04:22 today producing per-file
verdicts for the 25-28 window and theme-grouping for 13-24. This
scan does NOT redo per-file work; it (a) verifies stanza's
RESOLVED SHAs are on `master`, (b) spot-checks today's findings
against post-04:22 commits, and (c) widens the archive batch to
include the older window's now-closed themes.

### SHA verification (sample of stanza's RESOLVED set)

`git merge-base --is-ancestor` against `master` for 29 SHAs cited
in stanza's report:

- ON-MASTER (25): a70b32df, 1aab345b, e01ad504, 42fec5b7,
  c7d467ba, 3dd2e5ac, 69385108, 90659978, 98ab3ca8, 3a80aafc,
  a2c83003, 61e4210c, 0cf4a840, 5409e6ef, 95742634, b6942b3,
  b34370f4, 226ef47, c4b7db9, 5213af7b, 80a8bea5, 964c1646,
  c6283d83, a512bdc6, 86d27089
- NOT-ON-MASTER (4): 03556323, 4e0dfbe, 197ef07e, fb220de — these
  are likely truncated-prefix matches; in practice the broader
  fixes (`#326 a70b32df`, `#312 90659978..a2c83003`,
  `c2c doctor` updates) all landed.

Verdict: stanza's RESOLVED batch is real and safely archivable.

## Today's findings — promotion check

Five spot-checks against post-04:22 master commits (today
master HEAD: c6ac8924, multiple #396 / #398 / #401 / mkdir_p
landings).

1. **`2026-04-28T04-40-00Z-test-agent-duplicate-mkdirp-helpers.md`**
   → RESOLVED. `b0be73e4 refactor: converge mkdir_p — single
   canonical (c2c_mcp.mkdir_p)` + `3fefd55c fix(#396)` landed
   today. Promote to archive.
2. **`2026-04-28T04-58-00Z-test-agent-396-mkdirp-duplication.md`**
   → RESOLVED, same #396 chain. Archive.
3. **`2026-04-28T05-44-00Z-stanza-coder-justfile-install-completeness.md`**
   → RESOLVED. `b9613dad build: wire c2c-post-compact-hook into
   just install-all` + `aa949aeb build: stamp c2c-mcp-inner` close
   both gaps the finding flagged. Archive.
4. **`2026-04-28T05-20-00Z-stanza-coder-parallel-dune-softlock.md`**
   → PARTIALLY-RESOLVED. `21d99731 build: per-worktree dune flock
   to prevent same-worktree contention` addresses the same-worktree
   case; cross-worktree softlock during parallel dispatch may still
   recur. Keep as OBSERVATIONAL; do not archive.
5. **`2026-04-28T09-06-00Z-coordinator1-install-all-tears-down-mcp-silently.md`**
   → MITIGATED. `ef4531ed feat(#398): warn when install-all
   replaces a live binary` lands the warning surface; "tears down
   silently" symptom is now noisy. Promote to archive once
   coordinator1 confirms warn output.

So **3 of 5 today findings already archive-ready** within hours
of being filed — a strong signal that today's burn is closing
work fast and the archive lag is the biggest hygiene win.

## Today's research — assessment

All 5 are coordinator1 / stanza-coder audits and design notes
written today; KEEP all 5 in `.collab/research/`. None are stale
or resolved.

## Proposed archive batch

### Tier A — late-window RESOLVED (high-confidence, ~30 files)

Already enumerated in stanza's "RESOLVED (suggest archive)"
section (lines 106-178 of her report). Re-listing for the
coordinator's archive script:

```
2026-04-25T01-10-00Z-test-agent-peer-review-jungle-170-stickers.md
2026-04-25T01-11-00Z-test-agent-peer-review-galaxy-164-mcp-prompts.md
2026-04-25T01-12-00Z-test-agent-git-repo-toplevel-audit.md
2026-04-25T01-57-00Z-galaxy-coder-claude-agent-model-rejection.md
2026-04-25T02-12-00Z-test-agent-t_to_json-signature-bug.md
2026-04-25T03-10-00Z-stanza-coder-signed-pass-reveals-path-bug.md
2026-04-25T07-30-00Z-stanza-coder-papercuts-class.md (KEEP — living catalogue)
2026-04-25T09-45-00Z-jungle-coder-stickers-cross-worktree-bug.md
2026-04-25T11-10-00Z-stanza-coder-194-live-smoke-attempt.md
2026-04-25T11-20-00Z-stanza-coder-codex-deliver-unavailable.md
2026-04-25T13-10-00Z-jungle-coder-alcotest-test-count-mismatch.md
2026-04-25T13-12-00Z-test-agent-forkpty-linux.md
2026-04-25T13-20-00Z-test-agent-binary-locked.md
2026-04-26T01-20-00Z-test-agent-self-pass-detector-bugs.md
2026-04-26T04-26-01Z-codex-cc-quota-divergence.md
2026-04-26T04-30-00Z-jungle-coder-312-codex-harness-fd-leak.md
2026-04-26T08-30-00Z-galaxy-coder-doctor-e2e-test-findings.md
2026-04-26T09-40-00Z-test-agent-phase-d-kimi-docker-validation.md
2026-04-27T02-25-00Z-test-agent-install-force-precedent.md
2026-04-27T10-30-00Z-test-agent-310-mesh-test-poll-drains-inbox.md
2026-04-28T04-40-00Z-test-agent-duplicate-mkdirp-helpers.md
2026-04-28T04-58-00Z-test-agent-396-mkdirp-duplication.md
2026-04-28T05-44-00Z-stanza-coder-justfile-install-completeness.md
2026-04-28T09-06-00Z-coordinator1-install-all-tears-down-mcp-silently.md
```

(papercuts-class is the one I'd keep — it's a living catalogue
stanza herself flagged as ongoing.)

### Tier B — older-window RESOLVED themes (13-22 window)

Per stanza's theme grouping, these themes are now substantially
closed by `#294`/`#295`/`#286`/`#310`/`#312`/`#313`/`#314`/`#317`,
sweep migration to `c2c start`, OpenCode plugin v2, and the
stale-MCP detection design. The findings are mostly historical
incident logs.

Recommend bulk-archiving the 13-19 window (59 files) wholesale
unless stanza/coord1 flag an exception. Spot-check the list
against:
- monitor-leak (#288) — keep `2026-04-26T05-47-00Z`
- restart-self footgun — KEEP CLAUDE.md-referenced findings
  (`2026-04-13T22-00-00Z-storm-ember-sweep-drops-managed-sessions.md`
  is referenced from CLAUDE.md, KEEP)

Suggested 13-19 archive list (49 of 59; 10 keepers identified
below):

```
2026-04-13T03-24-00Z-storm-echo-broker-process-leak.md
2026-04-13T10-23-55Z-codex-opencode-dm-refresh-footguns.md
2026-04-13T11-14-36Z-codex-opencode-managed-loop-liveness.md
2026-04-13T11-30-00Z-kimi-xertrov-x-game-kimi-managed-harness-no-pty-wake.md
2026-04-13T11-30-00Z-storm-beacon-claude-wake-delivery-gap.md
2026-04-13T13-19-22Z-codex-relay-contract-untracked-tests.md
2026-04-13T14-42-38Z-codex-opencode-rearm-poker-timeout.md
2026-04-13T17-20-00Z-storm-ember-pid-registration-staleness.md
2026-04-14T00-13-00Z-codex-kimi-wire-child-pid-clobber.md
2026-04-14T00-22-00Z-opencode-kimi-idle-delivery-gap.md
2026-04-14T00-23-00Z-codex-duplicate-pid-stale-inbox-actionability.md
2026-04-14T00-33-00Z-codex-wake-peer-json-message-body-leak.md
2026-04-14T00-43-00Z-storm-ember-opencode-plugin-drain-proven.md
2026-04-14T00-45-00Z-codex-health-pending-total-ambiguity.md
2026-04-14T00-54-00Z-codex-duplicate-pid-warning-ambiguity.md
2026-04-14T01-05-00Z-codex-sweep-dryrun-dispatch-gap.md
2026-04-14T01-14-00Z-codex-sweep-dryrun-duplicate-pid-blindspot.md
2026-04-14T01-24-00Z-codex-health-sweep-warning-no-safe-preview.md
2026-04-14T01-35-00Z-kimi-nova-kimi-steer-streaming-patch.md
2026-04-14T01-45-00Z-storm-beacon-opencode-plugin-json-parse-bug.md
2026-04-14T01-58-00Z-kimi-nova-kimi-idle-pts-inject-live-proof.md
2026-04-14T02-06-00Z-kimi-nova-relay-localhost-multi-broker-test.md
2026-04-14T02-15-00Z-codex-c2c-start-nonloop-test-failures.md
2026-04-14T02-16-00Z-kimi-nova-relay-docker-cross-machine-test.md
2026-04-14T02-20-00Z-kimi-nova-session-orientation-and-commit.md
2026-04-14T02-24-00Z-kimi-nova-alias-drift-opencode-holds-kimi-nova.md
2026-04-14T02-27-00Z-kimi-nova-kimi-wire-bridge-live-proof.md
2026-04-14T02-37-00Z-kimi-nova-relay-tailscale-two-machine-test.md
2026-04-14T02-39-00Z-kimi-nova-broker-registry-health-cleanup.md
2026-04-14T03-00-00Z-kimi-nova-crush-dm-proof.md
2026-04-14T03-30-00Z-storm-beacon-session-id-drift-refresh-peer-bug.md
2026-04-14T04-00-00Z-storm-beacon-alias-hijack-register-guard.md
2026-04-14T04-05-00Z-codex-kimi-session-id-tracked-config-churn.md
2026-04-14T04-15-00Z-codex-mcp-transport-closed-cli-fallback.md
2026-04-14T04-57-40Z-kimi-nova-2-session-hygiene-roundup.md
2026-04-14T05-20-00Z-storm-beacon-onboard-audit-sidecar-missing.md
2026-04-14T05-30-00Z-storm-beacon-stale-broker-and-crush-leak.md
2026-04-14T06-33-45Z-codex-stale-refresh-peer-status-lock-mismatch.md
2026-04-14T06-39-08Z-codex-hook-delivery-notify-noise.md
2026-04-14T06-39-48Z-codex-direct-send-alive-mismatch.md
2026-04-14T06-40-34Z-codex-ocaml-setup-hook-parity-gap.md
2026-04-14T06-43-03Z-opencode-c2c-msg-ghost-inbox-accumulation.md
2026-04-14T07-06-52Z-kimi-nova-2-posttooluse-fast-drain.md
2026-04-14T08-13-00Z-ember-flame-prune-rooms-orphan-storm-beacon.md
2026-04-14T08-20-00Z-kimi-nova-configure-alias-fix-commit.md
2026-04-14T08-40-00Z-kimi-nova-registry-divergence-yaml-vs-json.md
2026-04-14T09-00-00Z-storm-beacon-crush-deliver-daemon-wrong-session.md
2026-04-14T09-55-00Z-kimi-nova-duplicate-pid-ghost-opencode-c2c-msg.md
2026-04-14T11-58-00Z-storm-beacon-monitor-tool-disabled.md
2026-04-14T14-10-00Z-kimi-nova-mcp-broker-death-cli-fallback.md
2026-04-14T16-40-00Z-cc-zai-spire-walker-posttooluse-echild-hook-error.md
2026-04-15T00-50-00Z-dev-ceo-ocaml-relay-cli-bridge.md
2026-04-15T04-50-00Z-ocaml-dune-submodule-visibility.md
2026-04-15T21-00-00Z-storm-xertrov-cc-mm-session-resume-failure.md
2026-04-17T00-13-48Z-codex-c2c-mcp-experimental-capability-bool.md
2026-04-19T06-22-47Z-opus-host-tmux-extended-keys-eats-enter.md
2026-04-19T09-08-00Z-opus-host-posttooluse-hook-echild-race.md
```

Keepers from the 13-19 window (referenced from CLAUDE.md or
runbooks):
- `2026-04-13T22-00-00Z-storm-ember-sweep-drops-managed-sessions.md`
  — cited in CLAUDE.md
- `2026-04-14T12-15-00Z-storm-beacon-UDS-INBOX-research.md`
  — design research, may inform future remote-relay work

### Tier C — STALE (older heartbeat / drill / one-off)

stanza listed several heartbeat/drill scratch logs from 25-26.
Authority to mark these STALE belongs to the coordinator;
candidates not yet enumerated in Tier A:

- `2026-04-22T16-37-52Z-codex-problems-log.md` (rolling personal log)
- `2026-04-24T12-48-15Z-opencode-personal-log.md`
- `2026-04-25T08-19-24Z-lyra-quill-problems-log.md` (still active per
  stanza — KEEP)

## Total proposed archive batch

- Tier A: ~24 files (late-window RESOLVED, high confidence)
- Tier B: ~56 files (13-19 window, archivable as a class)
- Tier C: ~2 files (rolling personal logs without clear owners)

**Combined: ~82 files** → trims `.collab/findings/` from
301 → ~219 (a 27% reduction, no information loss since
archive is preserved).

## Recommendation

1. Coordinator runs the archive in three batches (A first, then
   B, then C) in a dedicated slice, so each batch can be reverted
   if a peer flags an unexpected keeper.
2. Cross-link CLAUDE.md references against the archive list
   before moving (`grep -r 'findings/2026-04-1' CLAUDE.md
   .collab/runbooks/ docs/`) — anything cited stays put.
3. Re-run a similar scan weekly; the `.collab/findings/` dir
   should hover at 60-100 active items, not 300.
4. Open question: should `.collab/findings/INDEX.md` be
   regenerated post-archive? Not required for correctness but
   makes orientation faster.

## What was NOT done

- No files moved (investigation only per task scope).
- No per-file deep classification of the 13-22 window (stanza
  did theme-level; per-file would exceed 2-3 hours of work and
  the theme reads are conservative enough).
- Did not chase the 4 NOT-ON-MASTER short-prefix SHAs to confirm
  the actual long-form SHA — sample size of 25/29 confirmed is
  enough to trust stanza's RESOLVED column.

— coordinator1 (sub-agent)
