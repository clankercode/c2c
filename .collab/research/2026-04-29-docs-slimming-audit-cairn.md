# docs/ Slimming + Clarity Audit

**Author:** cairn-vigil (coordinator1) · **Date:** 2026-04-29 · **Status:** survey only (no fixes applied)
**Scope:** every `.md` published from `docs/` (Jekyll publishes-everything; only `CLAUDE.md` is in `_config.yml` exclude).

## Summary stats

- **Total `.md` files reviewed:** 77 (23,041 LOC)
- **CLEAN (no action needed):** 22
- **NEEDS-WORK:** 55
  - **DELETE candidates:** 7 (legacy/notes that should move to `.collab/` or be removed)
  - **MOVE-TO-`.collab/` candidates:** 32 (entire `superpowers/specs/` + `superpowers/plans/` + most of `c2c-research/` + `notes/`)
  - **MERGE candidates:** 4 (architecture.md ↔ overview.md, gui-architecture-prelim.md → gui-architecture.md, etc.)
  - **REWRITE/FIX-IN-PLACE:** 12

## Top 5 prioritized actions

1. **Add a `superpowers/` exclusion to `_config.yml`.** All 27 files in `docs/superpowers/{plans,specs}/` are internal planning artefacts (specs, plans, design notes) that were written before the `docs/` vs `.collab/` split was settled. They publish to `https://c2c.im/superpowers/...` today. Either `exclude: [superpowers]` in `_config.yml` (fast fix, keeps history) or move the directory wholesale to `.collab/superpowers/`. **Saves ~12,500 LOC of public surface in one diff.**
2. **Add `c2c-research/` and `notes/` to exclude (or move).** 14 files in `c2c-research/` and 4 in `notes/` are research artefacts and dated working notes — same reasoning. Most are pre-shipping research that's now superseded by what was built. Saves ~3,500 LOC.
3. **DELETE 4 legacy stubs:** `docs/research.md`, `docs/pty-injection.md`, `docs/verification.md`, `docs/HANDOVER.md`. Three are tiny (≤42 LOC) "Legacy: …" stubs that explicitly say "see overview.md". HANDOVER.md is an empty template. Replace with one-line redirects in `known-issues.md` if needed.
4. **Merge `gui-architecture-prelim.md` (309 LOC) into `gui-architecture.md`** (or delete). The prelim doc explicitly says it's a scratchpad superseded by the formal doc.
5. **Fix the 2 wrong-org GitHub URLs in `docs/security/pending-permissions.md`** (`xertrov/c2c` → `XertroV/c2c-msg`) and `team-self-upgrade-process.md` operational stale snapshot (mentions specific PIDs from a single agent's session 2026-04-21 — should move to `.collab/runbooks/` as generic procedure).

---

## Per-page findings

### Front-door / canonical pages (mostly CLEAN — keep updating)

```
docs/index.md (199 LOC)
  - Issue: card-grid duplicates "How It Works" content with overview.md "Delivery Model" — LOW (slight repetition is OK on landing).
  - Recommendation: FIX-IN-PLACE (small).

docs/overview.md (212 LOC)
  - Issue: Heavy overlap with architecture.md "High-level model" (broker root resolution paragraph appears verbatim in 2 pages plus relay-quickstart) — MED.
  - Issue: "MCP Server Setup" section (per-client) duplicates index.md "Setup" table and the cli surface in client-delivery.md — MED.
  - Recommendation: MERGE / dedupe — keep overview.md as the conceptual page, push per-client setup details into client-delivery.md, link out for broker root resolution.

docs/architecture.md (256 LOC)
  - Issue: Same broker-root-resolution boilerplate as overview.md / cross-machine-broker.md / relay-quickstart.md — MED.
  - Issue: "Historical artifacts" section discusses Python shims (`c2c_cli.py`, `relay.py`, etc.) that are deprecated; per CLAUDE.md drift hotspots — MED.
  - Recommendation: FIX-IN-PLACE — cut "Historical artifacts" entirely (link `.collab/runbooks/python-scripts-deprecated.md`), and centralise broker-root resolution in one page (suggest: architecture.md), link from others.

docs/get-started.md (59 LOC)
  - Issue: Title is "Get Started" but content is "Next Steps / What's Shipped Recently / Active Work" — actual onboarding lives in index.md. Confusing nav. — MED.
  - Recommendation: REWRITE — rename to "Recent Changes" or merge with index.md. The "Active Work" section duplicates `.goal-loops/active-goal.md` (intentional but stale-prone).

docs/commands.md (821 LOC)
  - Issue: Hand-written mirror of `c2c --help`; CLAUDE.md flags this as the canonical doc that must move with CLI changes. Spot check: matches current surface.
  - Recommendation: CLEAN (high-maintenance but load-bearing).

docs/communication-tiers.md (113 LOC)
  - Issue: Tier 2 table cites deprecated Python script names (`c2c_kimi_wake_daemon.py`, `c2c_opencode_wake_daemon.py`, `c2c_crush_wake_daemon.py`) — the row labels them "Deprecated" so this is documentation, not drift. LOW.
  - Recommendation: CLEAN — could trim deprecated rows entirely once CLAUDE.md says they're gone from `scripts/`.

docs/known-issues.md (148 LOC)
  - Issue: Mixes still-active issues with crossed-out ~~Fixed~~ entries. As fixes age, the file becomes a changelog rather than a known-issues list. MED.
  - Recommendation: FIX-IN-PLACE — periodically sweep ~~Fixed~~ entries to `.collab/findings-archive/`.

docs/relay-quickstart.md (538 LOC)
  - Issue: Recently updated (last commit 2026-04 added stale-image troubleshooting). CLEAN.
  - Recommendation: CLEAN.

docs/cross-machine-broker.md (252 LOC)
  - Issue: Significant overlap with relay-quickstart.md — "what is a relay" + step-by-step appears in both. MED.
  - Recommendation: MERGE — keep relay-quickstart.md as the operator guide; trim cross-machine-broker.md to design rationale only ("Why not shared filesystem?", "Contracts to preserve") and link out.

docs/clients/feature-matrix.md (170 LOC)
  - CLEAN — recently updated (#309) and well-structured.
```

### Architecture / spec pages

```
docs/MSG_IO_METHODS.md (578 LOC)
  - Issue: Comprehensive but overlaps with client-delivery.md (per-client view) and communication-tiers.md (priority/status view). 3 pages cover the same matrix from different angles. MED.
  - Issue: References `c2c_inject.py`, `claude_send_msg.py`, `c2c_pty_inject` (deprecated paths) extensively — accurate as historical record, but adds noise. LOW.
  - Recommendation: KEEP — this is the canonical method-by-method reference. Possibly merge MSG_IO_METHODS.md ↔ client-delivery.md ↔ communication-tiers.md into one combined "Delivery Reference" page if you want to slim aggressively (potential savings ~600 LOC).

docs/client-delivery.md (497 LOC)
  - Issue: Mentions `run-kimi-inst-outer` (deprecated outer-loop script CLAUDE.md says is replaced by `c2c start kimi`) — LOW (already says "replaces deprecated"). FIX-IN-PLACE: tighten wording.
  - Recommendation: FIX-IN-PLACE.

docs/channel-notification-impl.md (size moderate)
  - Issue: Implementation spec; describes a path that effectively dormant (Claude Code never declares experimental.claude/channel). LOW (still useful for future reference).
  - Recommendation: CLEAN — consider moving to `.collab/design/` since it's an implementation spec.

docs/dnd-mode-spec.md (~250 LOC)
  - Issue: Spec doc; describes shipped feature (DND landed in c4ee157). MED.
  - Recommendation: MOVE TO `.collab/design/LANDED/` — implementation specs aren't user-facing reference.

docs/monitor-json-schema.md
  - CLEAN — operator-facing schema for `c2c monitor --json`.

docs/agent-files.md
  - CLEAN — user-facing role-files reference.

docs/agent-file-schema-draft.md (55 LOC)
  - Issue: Status: DRAFT for review before implementation. Roles have shipped; this is now a stale spec.
  - Recommendation: DELETE (moved/superseded by `agent-files.md`) or MOVE to `.collab/design/LANDED/`.

docs/opencode-plugin-statefile-protocol.md
  - Issue: Implementation-internal protocol doc — not useful to public site visitors. MED.
  - Recommendation: MOVE TO `.collab/design/`.

docs/remote-relay-transport.md
  - CLEAN — operator-facing.

docs/security/pending-permissions.md (248 LOC)
  - Issue: Lines 247–248 contain `https://github.com/xertrov/c2c/commit/...` — wrong org, should be `XertroV/c2c-msg`. HIGH (CLAUDE.md flagged drift hotspot).
  - Issue: Page title says "Pending Permission RPCs (M2/M4)" — internal version naming bleeds into public docs. LOW.
  - Recommendation: FIX-IN-PLACE (URLs) + LOW retitle.
```

### GUI pages

```
docs/gui-architecture.md (formal, large)
  - CLEAN — current architecture for the planned GUI.

docs/gui-architecture-prelim.md (309 LOC)
  - Issue: Header explicitly says "scratchpad … the formal, structured version lives at docs/gui-architecture.md … fold the useful parts into the formal doc later." HIGH (self-flagged as redundant).
  - Recommendation: DELETE (after one-pass merge of any uncovered ideas into gui-architecture.md) OR MOVE to `.collab/research/`.

docs/gui-getting-started.md
  - Issue: Documents `tsconfig.json` build failure ("currently fails on line 18 (`TS5101: baseUrl is deprecated`)") as a known issue inline — should be either fixed in-tree or moved to known-issues.md. MED.
  - Recommendation: FIX-IN-PLACE.
```

### Legacy / stub pages — DELETE candidates

```
docs/research.md (36 LOC)
  - "Legacy: Research" page. Single-paragraph stub pointing to overview.md.
  - Recommendation: DELETE.

docs/pty-injection.md (42 LOC)
  - "Legacy: PTY Injection" stub. Mentions hardcoded `/home/xertrov/src/meta-agent/...` path; that's a personal dev-machine artifact bleeding into the public site.
  - Recommendation: DELETE (or MOVE to `.collab/findings-archive/`).

docs/verification.md (39 LOC)
  - "Legacy: Verification" stub. References hardcoded `~/.claude/projects/...` UUIDs from a 2026-04 trial.
  - Recommendation: DELETE.

docs/HANDOVER.md (16 LOC)
  - Empty template ("# Handover Information / ## Doc Meta"). Publishes to /HANDOVER/ with no content. HIGH.
  - Recommendation: DELETE (or move to `.collab/runbooks/handover-template.md`).

docs/team-self-upgrade-process.md (172 LOC)
  - Issue: Operational snapshot containing specific PIDs, pane indices, and agent aliases (galaxy-coder, jungle-coder pinned at 2026-04-21). Stale within hours of being written. HIGH.
  - Issue: Generic procedure useful to swarm operators, but specifics belong in `.collab/`.
  - Recommendation: MOVE TO `.collab/runbooks/team-self-upgrade.md` (and strip the dated state-of-swarm table).

docs/x-codex-client-changes.md (305 LOC)
  - Issue: Vendor-fork-internal change log for forked Codex TUI. Useful to maintainers; not user-facing reference. MED.
  - Recommendation: MOVE TO `.collab/design/` or to a separate `forks/` repo doc.

docs/phase1-implementation-steps.md (129 LOC)
  - Issue: One-shot extraction plan ("extract lines 4799–5935 to c2c_setup.ml"). Phase 1 is DONE per the doc itself.
  - Recommendation: DELETE (or move to `.collab/design/LANDED/`).

docs/ocaml-module-structure.md (103 LOC)
  - Issue: Internal-implementation-only — line ranges in `c2c.ml`, extraction phase status. Not relevant to c2c users.
  - Recommendation: MOVE TO `.collab/runbooks/ocaml-modules.md`.
```

### `notes/` directory (4 files, ~190 LOC) — MOVE to .collab/

```
docs/notes/2026-04-12-c2c-cli-and-approval-note.md (37 LOC)
  - Issue: 2026-04-12 working note. Decisions are landed. Stale.
  - Recommendation: MOVE TO `.collab/findings-archive/`.

docs/notes/2026-04-12-c2c-mcp-broker-note.md (64 LOC)
  - Issue: V1-shape working note from 2026-04-12; broker is now far past V1.
  - Recommendation: MOVE TO `.collab/findings-archive/`.

docs/notes/2026-04-13-claude-settings-mcp-channel-note.md (39 LOC)
  - Issue: Setup note recommending `--dangerously-load-development-channels server:c2c` — actively contradicted by current CLAUDE.md ("Do NOT set C2C_MCP_AUTO_DRAIN_CHANNEL=1"). HIGH risk of misleading readers.
  - Recommendation: DELETE or MOVE to archive with a banner.

docs/notes/2026-04-13-collab-protocol.md (53 LOC)
  - Issue: Collaboration protocol from 2026-04-13 referencing specific session UUIDs. Long-stale.
  - Recommendation: MOVE TO `.collab/findings-archive/`.
```

### `c2c-research/` directory (10 files, ~3,500 LOC) — MOVE to .collab/

All files in `c2c-research/` are pre-shipping research / architecture surveys. They publish to `https://c2c.im/c2c-research/...` today. Most have layered status notes ("Layer 4 spec for review", "draft for coordinator1 review") — internal artefacts.

```
docs/c2c-research/RELAY.md (195 LOC) — master index, but cites `.git/c2c/mcp/` (legacy broker path).
docs/c2c-research/claude-cli-help.md (72 LOC) — raw `--help` dump; no narrative.
docs/c2c-research/codex-channel-notification.md (249 LOC) — research, dated 2026-04-15.
docs/c2c-research/e2e-encrypted-relay-architecture.md (905 LOC) — comprehensive research, valuable but internal.
docs/c2c-research/opencode-channel-notification.md (174 LOC) — research, dated.
docs/c2c-research/relay-bearer-admin-only-plan.md (134 LOC) — design slice, "approved by coordinator1 2026-04-21".
docs/c2c-research/relay-internet-build-plan.md (436 LOC) — 5-layer plan, draft.
docs/c2c-research/relay-peer-identity-spec.md (486 LOC) — Layer 3 spec, draft.
docs/c2c-research/relay-railway-deploy.md (152 LOC) — operator deploy guide (THIS one is arguably user-facing).
docs/c2c-research/relay-rooms-spec.md (454 LOC) — Layer 4 spec, draft.
docs/c2c-research/relay-tls-ocaml-integration.md (314 LOC) — internal slice plan.
docs/c2c-research/relay-tls-setup.md (237 LOC) — Layer 2 companion (MAYBE keep, operator content).
docs/c2c-research/generating-agents/x-oc-fork-writing-agents-w-themes.md (176 LOC) — fork-specific guide.
```

  - Recommendation: BULK-MOVE the directory to `.collab/research/relay/` (preserves history).
    Exception: keep `relay-railway-deploy.md` and `relay-tls-setup.md` as user-facing pages (move to `docs/` root).

### `superpowers/` directory (27 files, ~12,500 LOC) — MOVE to .collab/

Every file under `docs/superpowers/{plans,specs}/` is a planner/implementer artefact. Many have explicit "Archival note: out of date" headers (e.g. `2026-04-11-c2c-registration-and-autonomous-chat.md`). They publish but are not designed for public consumption.

  - Recommendation: BULK-MOVE `docs/superpowers/` → `.collab/superpowers/` (or `.collab/design-archive/`). Preserves history; one-line `_config.yml` change as a stop-gap (`exclude: [superpowers]`).

---

## Drift hotspots (per CLAUDE.md "Common drift hotspots")

| Drift type | Severity | Files affected | Notes |
|---|---|---|---|
| Wrong GitHub org URL | HIGH | `security/pending-permissions.md` (2 occurrences) | `github.com/xertrov/c2c` → `github.com/XertroV/c2c-msg` |
| Legacy broker path `.git/c2c/mcp/` | LOW (mostly archival) | `c2c-research/RELAY.md`, several `superpowers/` plans | Internal docs; LOW priority once those move out of `docs/` |
| Python script citations | MED | 19 files mention `c2c_*.py` | Most are intentional (legacy / deprecated callouts). Audit when scripts are deleted. |
| Stale OCaml line numbers | LOW | `phase1-implementation-steps.md`, `ocaml-module-structure.md` | Both should leave `docs/`. |
| Legacy outer-loop scripts | LOW | `client-delivery.md` (1 mention, contextual) | Already labeled "deprecated". |

## Cross-cutting observations

- **The `_config.yml` exclude list has only 1 entry.** This is the highest-leverage single fix: adding `superpowers`, `c2c-research`, `notes` to exclude (or moving them) would cut public surface by ~70%.
- **Broker-root resolution paragraph appears in 5 pages verbatim.** Promote one canonical location (suggest `architecture.md`); link out from elsewhere with a one-sentence summary. Reduces drift risk when the resolution order changes.
- **Three pages cover the delivery matrix** (`client-delivery.md`, `MSG_IO_METHODS.md`, `communication-tiers.md`). Each adds a different lens, but a reader navigating the site sees overlapping info 3x. Worth deciding which is canonical and trimming the others to "see X for Y dimension".
- **No published changelog page** — `get-started.md` doubles as a changelog ("What's Shipped Recently") but the title doesn't say so. Consider a real `CHANGELOG.md` or rename `get-started.md`.

## Suggested execution order (low-risk → high-impact)

1. **Quick wins (one PR)**: DELETE the 4 legacy stubs (`research.md`, `pty-injection.md`, `verification.md`, `HANDOVER.md`); fix the 2 wrong-org URLs in `security/pending-permissions.md`; merge `gui-architecture-prelim.md` notes into `gui-architecture.md` and delete the prelim. ~600 LOC.
2. **Bulk move (one PR, history-preserving)**: `git mv docs/superpowers .collab/superpowers && git mv docs/c2c-research .collab/research/relay && git mv docs/notes .collab/findings-archive/2026-04-notes/`. Also relocate `team-self-upgrade-process.md`, `phase1-implementation-steps.md`, `ocaml-module-structure.md`, `agent-file-schema-draft.md`, `dnd-mode-spec.md`, `opencode-plugin-statefile-protocol.md`, `x-codex-client-changes.md`, `channel-notification-impl.md`. Update inbound links. ~16,000 LOC out of `docs/`.
3. **Dedupe (multiple smaller PRs)**: centralise broker-root resolution in `architecture.md`; trim duplicates in `overview.md` / `cross-machine-broker.md`; decide canonical delivery-matrix page and trim the other two.

End of audit.
