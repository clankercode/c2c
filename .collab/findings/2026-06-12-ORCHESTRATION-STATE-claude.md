# ORCHESTRATION STATE — claude — COMPLETE (2026-06-12)

**ALL THREE FEATURES SHIPPED + DEPLOYED.** master pushed 57555f8b..8c2f5f51.

## Outcome
| # | Feature | SHA(s) | Reviews | Merge | Live-validated |
|---|---------|--------|---------|-------|----------------|
| 20 | opencode install crash (mkdir_p recursive) | 28204669 | impl + mm3 + codex (all PASS) | 634fefbe | `c2c install opencode --force` rc=0, deliver-watch.sh created |
| 18 | rooms-history room_id (FALSE ALARM → regression tests) | e05059d9 + 05c4858b | impl + glm51(+E2E) + codex (all PASS) | ca6faeda | pytest 33/33; smoke green |
| 19 | /connect reload-plugins/restart docs | ab10b13e + 70622d638 + 46e46f57 | impl + mm3(+3 fixes) + codex(+hero/Gemini fix) | 8c2f5f51 | post-install msg correct per-client |

Pipeline used (per user directive): impl(mimo25p)+review-and-fix → cross-review by DIFFERENT
model (mm3/glm51) running review-and-fix → my own ccc-review-cx (codex @cx-reviewer) → merge
+build+install → single push → worktree cleanup. Model budget respected (8x mimo25p, 2x mm3, 1x glm51).

## Key finding
#18 was a FALSE ALARM — CLI source already POSTs room_id correctly; live failure was a
stale/transient artifact. Slice became test-only (server-contract + E2E CLI test).
See .collab/findings/2026-06-12T08-58-00Z-claude-rooms-history-false-alarm.md.

## Deploy
master @ 8c2f5f51 pushed → Railway rebuild (relay.ml UNCHANGED, relay behavior identical) +
GitHub Pages rebuild (onboarding docs go live on c2c.im). All 9 commits classified local-only
by `c2c doctor` (none relay-critical).

## Cleanup
All 3 worktrees (wt-opencode-install-fix, wt-rooms-history-fix, wt-connect-docs) + branches removed.
Discarded env-specific churn: .opencode/opencode.json broker-root, .opencode/package.json plugin bump.

NOTHING PENDING. This run is closed.
