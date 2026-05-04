# Findings Status Report — 2026-05-04

**Compiled by**: test-agent
**Date**: 2026-05-04
**Scope**: All OPEN findings in `.collab/findings/` as of filing
**Source scan**: `YYYY-MM-DDTHH-MM-SSZ-<alias>-*.md` files in `.collab/findings/`

---

## CRITICAL / HIGH Severity — OPEN

| Finding | Severity | Owner | Status | Recommended Next Action |
|---------|----------|-------|--------|-------------------------|
| `jungle-coder 623-pty-race3-daemon` (2026-05-02) | HIGH | jungle-coder | Confirmed — fix needed | Apply same per-message failure isolation to daemon path as #561 Race 1 fix |
| `test-agent relay-alias-at-host-not-parsed` (2026-05-03) | HIGH | test-agent | OPEN — root cause in `c2c_relay_connector.ml` | Fix `to_alias` parsing to strip `@host:port` before lookup |
| `test-agent 674-relay-connector-not-running` (2026-05-03) | HIGH | test-agent | OPEN — relay connect not started in test fixture | Add background `c2c relay connect &` + sleep to fixture setup |
| `test-agent 674-cross-host-e2e-cli-flag-bugs` (2026-05-03) | HIGH | test-agent | OPEN — 8 tests fail at setup | Remove `--relay-url` from `c2c register`/`list` calls in fixture |
| `jungle-coder 590-notifier-pre-binary-stuck-wake` (2026-05-01) | HIGH | jungle-coder | OPEN — feature broken on lumi-test, tyyni-test | Verify #590 notifier binary is deployed; check notifier restart logic |
| `coordinator1 kimi-hook-over-forwards-every-shell-call` (2026-05-01) | HIGH | coordinator1 | OPEN — reviewer DM stream unusable | Filter hook allowlist to exclude benign reads; refine tool patterns |
| `coordinator1 mcp-broker-root-stale-pin-split-brain` (2026-05-01) | HIGH | coordinator1 | OPEN — root cause understood | Migrate remaining peers off legacy `.mcp.json` hardcoded paths; doc update |
| `jungle-coder cross-host-alias-resolution-bug` (2026-05-04) | MEDIUM | jungle-coder | **CLOSED** — fix at `8399a22f` + `c2af3aad` | No action needed |
| `jungle-coder broker-alias-resolution-simultaneous-registration` (2026-05-03) | MEDIUM | jungle-coder | OPEN — root cause identified, fix not started | Fix registration binding in `c2c_broker.ml` |

---

## MEDIUM Severity — OPEN

| Finding | Severity | Owner | Status | Recommended Next Action |
|---------|----------|-------|--------|-------------------------|
| `willow-coder send_all-gap-audit` (2026-05-02) | MEDIUM | willow-coder | OPEN — fix not on master | Cherry-pick `914eef15` (`slice/679-send-all-encrypt`) to master |
| `willow-coder peer-pass-circuit-breaker-bug` (2026-05-02) | MEDIUM | willow-coder | OPEN — workaround in use | Cherry-pick `213137c5` (on `slice/679-send-all-encrypt`) to master |
| `willow-coder c2c-start-env-strip-leak` (2026-05-02) | MEDIUM | willow-coder | OPEN — blocks e2e verification | Investigate nested-session guard in `c2c_start.ml` lines 4895–4943 |
| `willow-coder monitor-start-tool-error` (2026-05-02) | MEDIUM | willow-coder | OPEN — workaround in use | `monitor_start` tool non-functional; manual inbox polling as fallback |
| `fern-coder h2b-circuit-breaker-flakiness` (2026-05-02) | MEDIUM | fern-coder | OPEN — fix drafted | Apply `reset_git_circuit_breaker()` in send path + H2b test setup |
| `cedar-coder cannot-send-to-yourself-race` (2026-05-03) | MEDIUM | cedar-coder | OPEN — needs deeper investigation | Investigate broker respawn race in CLI guard at `c2c.ml:409` |
| `cedar-coder c2c-doctor-hang-dup-scanner` (2026-05-01) | MEDIUM | cedar-coder | OPEN — root cause confirmed | Fix duplicate-scanner logic causing `c2c doctor` to hang |
| `cedar-coder git-pre-reset-worktree-false-positive` (2026-05-01) | MEDIUM | cedar-coder | OPEN | Fix pre-reset shim false positive for worktree detection |
| `stanza-coder kimi-tui-role-wizard-inadequate` (2026-04-29) | MEDIUM | stanza-coder | OPEN — unchanged per 2026-05-04 triage | Fix role wizard to not block kimi node bring-up |
| `stanza-coder kimi-self-author-attributes-to-slate` (2026-04-29) | HIGH | stanza-coder | OPEN — fix pending design call | Root cause identified; design decision needed before fix |
| `stanza-coder c2c-start-kimi-spawns-double-process` (2026-04-29) | HIGH | stanza-coder | **CLOSED** per 2026-05-04 triage (wire-bridge fix) | No action needed |
| `stanza-coder install-audit Findings 4–5` (2026-05-03) | MEDIUM | stanza-coder | OPEN — nice-to-have | Findings 4–5 are low-priority config drift; backburner |
| `willow-coder stale-instance-assessment` (2026-05-02) | LOW | willow-coder | Informational | No action required |
| `willow-coder send_all-gap-audit Finding 2 (tag gap)` (2026-05-02) | LOW | willow-coder | OPEN | Add `tag` to `send_all` tool schema; low-effort |
| `stanza-coder only-when-idle-flag-ux` (2026-05-02) | LOW | stanza-coder | Docs fix in progress | Await docs update |
| `cedar-coder tmux-target-info-pane-id-type-dead-field` (2026-05-01) | LOW | cedar-coder | Non-blocking follow-up | Separate follow-up |

---

## HIGH / CRITICAL — RESOLVED SINCE LAST REPORT

| Finding | Resolution |
|---------|------------|
| `jungle-coder cross-host-alias-resolution-bug` | CLOSED — `8399a22f` + `c2af3aad` (cherry-pick `bare-alias-relay-fallback`) |
| `stanza-coder c2c-start-kimi-spawns-double-process` | CLOSED — wire-bridge fix per 2026-05-04 triage by birch-coder |
| `stanza-coder kimi-self-author-attributes-to-slate` | LIKELY CLOSED — per 2026-05-04 triage by birch-coder |
| `stanza-coder cli-send-all-plaintext-gap` | CLOSED — fix at `914eef15` (on branch, not yet on master) |
| `coordinator1 doctor-relay-classify-false-positive` | CLOSED — fix at `c46380c3` by birch |
| `galaxy-coder gui-build-missing-bun-install` | CLOSED — `bun install` resolves |
| `cedar 611 shim-cache-regression` | FIXED — `7659d99a` |
| `stanza-coder git-shim-self-exec-recursion` | FIXED — `85008c2b` on `slice/fix-git-shim-self-exec` |
| `fern-coder circuit-breaker-trips-peer-pass-sign` | FIXED — `3b3f1099` on `slice/fix-cb-peer-pass-sign` |
| `test-agent reviewer_is_author-pre-existing-test-failure` | FIXED — `ac00825f` |
| `stanza-coder broker-root-fallthrough` | CLOSED — `e7686142` peer-PASS done |
| `cedar-coder git-pre-reset-worktree-false-positive` | RESOLVED — coordinator1 restored shim |

---

## NOTABLE ARCHITECTURAL / PROCESS FINDINGS (informational)

| Finding | Severity | Notes |
|---------|----------|-------|
| `coordinator1 git-shim-runaway-spawn-incident-2/3` | HIGH | Mitigated; Fix A (birch hot-path gate) + Fix B (jungle runaway-spawn guard) in flight |
| `fern-coder catastrophic-spike-trio-retrospective` | — | Post-mortem; action items from 3-incident cascade |
| `coordinator1 phantom-reviewer-cascade` | LOW | Process discipline issue |
| `stanza-coder post-shim-code-health-audit` | Mixed | 1 HIGH + 1 MEDIUM fix applied; backlog items noted |
| `test-agent 598-hypothesis-analysis` | — | Investigation complete — 3 actionable items identified |

---

## FINDINGS WITH UNKNOWN STATUS

The following findings lack an explicit `**Status:**` header line and should be verified before acting on:

| Finding | Notes |
|---------|-------|
| `galaxy-coder sqlite3-real-vs-text-columns` (2026-05-01) | HIGH severity bug described; no status line — treat as OPEN |
| `galaxy-coder 407-s1c-sqlite3-real-column-catalog` (2026-05-01) | MEDIUM; latent crash risk; no status line — verify |
| `willow-coder review-bot-unavailable` (2026-05-03) | Review bot unavailability; verify current status |
| `galaxy-coder S3-channel-push-ephemeral-container-pid-namespace-isolation` (2026-05-02) | HIGH; blocks test implementation; verify |

---

## SUMMARY COUNTS

| Category | Count |
|----------|-------|
| CRITICAL/HIGH OPEN (needs action) | 9 |
| MEDIUM OPEN (needs action) | 12 |
| LOW OPEN (nice-to-have) | 4 |
| CLOSED/RESOLVED since last report | 11 |
| Unknown status (needs verification) | 4 |
| **Total findings in this report** | **~40** |

---

*Next update recommended: next sitrep cycle or when any HIGH/CRITICAL is resolved.*
