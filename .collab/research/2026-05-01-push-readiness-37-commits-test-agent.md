# Push Readiness Audit — 37 commits ahead of origin/master

**Audit date**: 2026-05-01
**Auditor**: test-agent
**Master tip**: `b4b128e7` | **origin/master**: `3716afee` (37 commits behind)

---

## Verdict: **PUSH WARRANTED**

**Reason**: 5 RELAY-critical commits that directly affect broker/relay/runtime behavior, plus 1 AMBIG. The remaining 31 are LOCAL and can land together without risk.

---

## RELAY — changes broker/relay/server behavior that affects running instances

| SHA | Message | Rationale |
|-----|---------|-----------|
| `25345f0a` | feat(#514 S1): stale broker_root detection — exit 42 on fingerprint mismatch | Broker root validation; affects relay startup |
| `8b6a036e` | fix(monitor #518): treat empty-string C2C_MCP_BROKER_ROOT as unset | Broker root resolution fix; prevents stale path reuse |
| `48bd74cf` | fix(#525): add broker_root_source marker to kimi-mcp.json | kimi MCP config — prevents broker drift after migrations |
| `dc2bdaf9` | fix(#484 S1): notifier uses read_inbox peek instead of drain + tests | Inbox notifier behavior — was silently eating messages on drain |
| `dd23b518` | feat(#511 slice 2): hook script walks authorizer chain sequentially | Hook routing — affects permission flow for kimi approvals |

---

## AMBIG — touches both surfaces or uncertain

| SHA | Message | Rationale |
|-----|---------|-----------|
| `05d1b25e` | finding(#528): test-agent self-cherry-pick into coord main tree pre-PASS | Finding doc — meta, but documents a process violation |

---

## LOCAL — refactors, docs, runbooks, tests, findings, coordination

**Refactors** (no behavior change):
- `b581bd42` refactor(#450 s7): Identity/Discovery extract
- `46cb99de` refactor(#450 s6): Send cluster extract
- `5c4fd3a6` refactor(#450 s5): Inbox cluster extract
- `c10f55ad` refactor(#450 s4): Pending-reply cluster extract
- `87d3c2af` refactor(#450 s3): DND/Compact/Stop extract
- `e2bdf3f3` refactor(#450 s2): Rooms cluster extract
- `878345ed` refactor(#450 s1): Memory_handlers extract
- `9254442b` refactor(#450 s0.5): hoist post-Broker helpers
- `3716afee` refactor(#450 s0): hoist Broker + helpers

**Docs/runbooks**:
- `7665e850` docs(#473): kimi-as-peer quickref update
- `aa57595f` fix(#526): stale line refs per fern review
- `fac20a28` fix(#526): findings filename naming convention
- `53e1166e` docs(#526): c2c-plugin.json broker_root asymmetry doc
- `61b1c6de` docs(#493): rebase-rubric discipline note
- `b7502262` docs(#493): permission-DM discipline runbook

**Findings/meta**:
- `7fa30541` finding: routing-mismatch relapse on tagged DMs
- `e91cece5` sitrep: 18:00 UTC
- `79053386` finding: subagent stale-CWD nested-worktree footgun (Pattern 19)
- `35ad05dd` #479 statefile parity audit summary

**Tests**:
- `c94d033d` feat(#480 S1): native OCaml tests for oc_plugin drain-inbox-to-spool
- `08055d71` test(#450 s4): clear TMUX_PANE in get_tmux_location test
- `e5d02441` fix(test_c2c_start): widen sync_instance_alias try-catch for Sys_error
- `0a1b1c32` test(#478): unit tests for build_kimi_mcp_config + kimi docs

**Reverts** (cleaned up state):
- `5ebf576e` Revert "fix(#484 S1): notifier uses read_inbox peek..." — superseded by `dc2bdaf9`

**Plugin/config**:
- `d7186c99` feat(#527): write agent_name to c2c-plugin.json in refresh_identity
- `47c04eab` feat(#524): read supervisor_strategy from repo.json + wire to hook routing

**Local-only tooling**:
- `1eff5e8f` fix(#519): cap dup-scanner + overall-timeout; doctor worktree check

**Coordination**:
- `b4b128e7` drive-by: remove tmux_pane_id from tmux_target_info (#527 follow-on)
- `e871a2ff` warn: emit deprecation warning on legacy DM format (#493)

---

## Summary by class

| Class | Count | Notes |
|-------|-------|-------|
| RELAY | 5 | Broker/relay runtime behavior |
| AMBIG | 1 | Meta/process finding |
| LOCAL | 31 | Refactor, docs, tests, findings |

---

## Recommended push composition

**Push all 37** — the RELAY commits need to go live, and the refactors/doc commits are harmless batch. The risk of a partial push (cherry-picking RELAY only) is higher than just pushing everything.

**Alternatively**: push only the 5 RELAY + 1 AMBIG commits and let the rest ride. But there's no behavioral risk from the LOCAL batch landing together.

---

## Risk assessment

- **Broker/relay downtime**: None — no migration, no schema change, no restart required
- **Config format change**: None material
- **Behavioral changes**: 5 RELAY fixes that improve correctness (not regressions)
- **Documentation user-facing**: Some docs updates visible on c2c.im after GitHub Pages rebuild
