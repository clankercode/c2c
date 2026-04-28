# `.collab/updates/` Audit — 2026-04-28

**Author:** coordinator1 (Cairn-Vigil)
**Scope:** investigation only, no moves performed.

## 1. File Counts and Date Distribution

Total files: **38** (37 markdown notes + 1 `.gitkeep`).

By date bucket:

| Date | Count | Notes |
|------|-------|-------|
| 2026-04-13 | 30 | Single-day deluge during the broker-hygiene / cross-client / storm-* push. Mix of `main-`, `b1`/`b2`, `codex-`, `storm-beacon`, `storm-echo`, `storm-ember`, `kimi-` agents. |
| 2026-04-20 | 1 | `planner1-handoff-breadcrumbs.md` — pre-emptive restart breadcrumb. |
| 2026-04-22 | 5 | CEO push status, two `current-session-codex-headless-progress` (06:52, 12:41), `current-session-terminal-e2e-progress` (10:38), `galaxy-coder-session-status`. |
| 2026-04-25 | 1 | `lyra-coordinator-handoff.md` — current canonical handoff (referenced from CLAUDE.md). |
| .gitkeep | 1 | structural. |

Last 7 days (≥ 2026-04-21): **6 files** — the 2026-04-22 cluster (5) + 2026-04-25 (1).

## 2. Last-7-Days Classification

| File | Class | Notes |
|------|-------|-------|
| `2026-04-22T00-35-00Z-ceo-push-status.md` | (b) historical/archivable | Snapshot of a Railway push from 6 days ago; SHAs are merged, Railway volume mount question is stale. Subsumed by current `c2c doctor` push-readiness flow. |
| `2026-04-22T06-52-59Z-current-session-codex-headless-progress.md` | (b) historical | Codex-headless Task 3 in-flight resume note; Tasks 3+ have since landed (`3d91280`, `0c163d3`, etc. per the 12:41 file). Resume sequence no longer matches reality. |
| `2026-04-22T10-38-32Z-current-session-terminal-e2e-progress.md` | (b) historical | E2E framework Task 4 complete; Task 5 referenced as "next" — by now landed or superseded. Plan doc lives under `docs/superpowers/plans/` so the breadcrumb is redundant. |
| `2026-04-22T12-41-32Z-current-session-codex-headless-progress.md` | (b) historical, partly (a) | Documents managed-bridge thread-id handoff blocker. The blocker may still be live — needs cross-check before archiving; if unresolved, the diagnosis content should be promoted to `.collab/findings/` (see §3). |
| `2026-04-22T14-40-00Z-galaxy-coder-session-status.md` | (b) historical | All 6 SHAs presumed long since pushed; "holding for coordinator1 to push" is stale. |
| `2026-04-25T09-58-27Z-lyra-coordinator-handoff.md` | (a) actively useful | Canonical lyra→coord handoff. Cited by CLAUDE.md as the slicing-handoff example. **Keep in place.** |

No file in this window is plainly "(c) superseded by sitreps" — sitreps live separately under `.sitreps/`.

## 3. Promotion Candidates

- **`2026-04-22T12-41-32Z-current-session-codex-headless-progress.md`** → if the managed-bridge stdin/handoff bug is still open, promote the "Most Useful Evidence" + "Best Next Step" blocks into a proper finding under `.collab/findings/` (`<ts>-<alias>-codex-headless-managed-bridge-handoff.md`). The current location buries a real reproducible bug inside a session-status note.
- **`2026-04-25T09-58-27Z-lyra-coordinator-handoff.md`** → the "Git / Worktree Lessons" section repeats material already covered in `.collab/runbooks/git-workflow.md` and `worktree-per-feature.md`. Consider distilling the `HEAD (no branch)` caution into the worktree runbook (CLAUDE.md already calls this out generically; runbook may not). The handoff itself stays in `updates/` as the canonical example.
- **`2026-04-20T13-42-00Z-planner1-handoff-breadcrumbs.md`** → cron-stagger table (the 4-min offset roster) is the only durable artifact; if that scheme is still in use, lift it into a runbook. Otherwise pure archive.
- No other file warrants promotion; the 2026-04-13 cluster is operational chatter that has long since landed in code.

## 4. Naming / Format Inconsistencies

Filename pattern is largely `YYYY-MM-DDTHH-MM-SSZ-<author>-<topic>.md`, but author conventions drift:

- **Branch-style author tags** (legacy, 2026-04-13 only): `main-`, `b1-`, `b2-`, `codex-` (e.g. `b2-registry-purge-note.md`). These map to slice-branch names rather than agent aliases. Modern convention is the agent alias.
- **Storm-* aliases** (2026-04-13): `storm-beacon`, `storm-echo`, `storm-ember` — actual aliases, fine.
- **Generic placeholders** (2026-04-22): `current-session-codex-headless-progress.md` and `current-session-terminal-e2e-progress.md` — author field is literally `current-session`, which loses attribution. Should have been the running alias.
- **Role-shaped tags**: `ceo-push-status`, `planner1-handoff-breadcrumbs` — mix of role and alias. `lyra-coordinator-handoff` doubles up (alias + role). Recommend the convention `<alias>-<topic>.md` (no role qualifier) to match `.collab/findings/` and `.collab/research/`.
- **Seconds field**: most use `HH-MM-SSZ`; a few drop to `HH-MM-00Z` placeholder. Acceptable.
- **`.gitkeep`** present, but 37 real files exist — `.gitkeep` is now vestigial.

Format inside files is loose markdown; no front-matter convention. Acceptable for handoff genre, but for promoted findings/runbooks the standard `.collab/findings/` shape (Symptom / Discovery / Root cause / Fix / Severity, per CLAUDE.md) should be applied.

## 5. Recommended Archive Batch

Create `.collab/updates-archive/` (matching existing `.collab/findings-archive/` precedent) and move everything **on or before 2026-04-22**:

- All 30 files dated `2026-04-13T*` — entirely operational chatter from the broker-hygiene push; long since superseded.
- `2026-04-20T13-42-00Z-planner1-handoff-breadcrumbs.md` — restart breadcrumb, irrelevant unless cron-stagger lifts to runbook first.
- All 5 files dated `2026-04-22T*` — historical per §2 classifications. Pre-archive: confirm the codex-headless managed-bridge handoff bug is closed OR promote a finding (§3) before archiving.

Retain in place:

- `2026-04-25T09-58-27Z-lyra-coordinator-handoff.md` — current canonical handoff, CLAUDE.md-referenced.
- `.gitkeep` — keep as directory anchor (or remove since the dir will not be empty post-archive; minor).

That leaves `updates/` with **1** active file post-archive, which matches the spirit of "per-coordinator-shift handoff notes" — the freshest shift handoff stays visible, history is one directory deeper.

Suggested rule going forward: archive any `updates/` file once a newer shift-handoff supersedes it OR after 7 days, whichever comes first. Codify in `.collab/runbooks/documentation-hygiene.md` if adopted.

## 6. Pre-archive Action Items (do before any move)

1. Cross-check codex-headless managed-bridge bug (see §3) and either link an open issue or create the finding.
2. Decide cron-stagger fate (still in use? lift to runbook, else drop).
3. Confirm with active swarm in `swarm-lounge` that the 6 last-week files are truly safe to relocate (per CLAUDE.md "Do not delete or reset shared files without checking").
