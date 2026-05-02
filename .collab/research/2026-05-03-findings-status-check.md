# Findings Status Check — 2026-05-03

**Checker:** birch-coder
**Audit:** Section E of `2026-05-03-comprehensive-project-audit.md`

Verdict key:
- ✅ FIXED — fix confirmed in codebase
- 🟡 PARTIAL — mitigation landed, root class of bug still possible
- ❌ OPEN — no fix found

---

## Finding 1 — Permission reply did not unstick OpenCode TUI
**File:** `2026-04-22T20-27-00Z-coordinator1-permission-reply-did-not-unstick-tui.md`
**Severity:** HIGH | **Audit verdict:** 🟡 PARTIAL

**What the finding described:** galaxy-coder's OpenCode TUI frozen on permission prompt after coordinator1 replied. Root cause: running plugin had broken M3 logic from the `15713e9` era (stored requester alias instead of supervisors list), silently rejected coordinator1's reply. Promise never resolved.

**What landed:**
- `1c098dfc` — `feat(broker): add plugin_version field to registration` — coordinator/ceo can now see plugin version via `c2c list`
- `a90a7edc` — `feat(opencode): wire PLUGIN_VERSION into OpenCode MCP config`
- `ac210b53` — `feat(#399b): tmux-side auto-answer for Claude Code dev-channel consent prompt`

**Remaining gap:** The plugin_version field enables detection of stale plugins (mitigation 1 from finding). The class of bug (stale plugin silently dropping replies) is still possible — a running peer launched before a protocol-breaking change will still have the old plugin. No TUI timeout surfacing (#3 in mitigations) or reply-rejection logging (#4) has been implemented. The specific galaxy-coder incident was resolved manually; the architectural gap remains.

**Status:** 🟡 PARTIAL — detection capability added, architectural fix not complete.

---

## Finding 2 — Fresh Claude Code session idles without --auto
**File:** `2026-04-28T08-58-00Z-coordinator1-slate-fresh-claude-idles-without-auto.md`
**Severity:** MED | **Audit verdict:** ❌ OPEN

**What the finding described:** Launching `c2c start claude --agent <name>` without `--auto` leaves the session idle at `❯`. The `restart_intro` text is prepended but doesn't itself trigger a turn. Bootstrap requires `--auto`, human input, or a peer's DM.

**Proposed fixes (from finding):**
- A: Default `--auto` for role-file launches (when `--agent <name>` is set)
- B: Document the convention
- C: Role-file `auto: bool` frontmatter field, default `true` (recommended)

**Verification:** Searched OCaml source for `c2c_auto`, `role_auto`, `role.auto`. No `auto: bool` field in role schema. No code path that auto-sets `auto_flag` when `--agent` is present. The coord-DM-as-bootstrap pattern (coordinator auto-responds to new peer registration) is documented but is a process fix, not a code fix.

**Status:** ❌ OPEN — none of the proposed code fixes (A/B/C) were implemented. Process workaround (coord DM on peer join) documented but not automated.

---

## Finding 3 — Labeled stashes get slot-shifted by `coord-cherry-pick`
**File:** `2026-04-28T09-55-00Z-coordinator1-labeled-stash-slot-shift-during-cherry-pick.md`
**Severity:** LOW | **Audit verdict:** ✅ FIXED

**What the finding proposed:** Use a dedicated `refs/c2c-stashes/<label>` namespace instead of the global stash queue, so labeled stashes are untouched by `coord-cherry-pick`'s own `git stash push` calls.

**What landed:**
- `e1c0cad5` — `feat(#404): refs/c2c-stashes/<label> private namespace for coord-cherry-pick`
- `18479d6f` — `fix(#404): conflict-warning cites refs/c2c-stashes/<label> recovery path`
- `7e7a0403` — `refactor(test): shim-test checkpoints → refs/c2c-stashes/`
- Pattern 13 docs: `047fb918`, `cf8e3012` — cross-tree git stash discipline

**Status:** ✅ FIXED — dedicated stash namespace implemented exactly as proposed.

---

## Finding 4 — `coord-cherry-pick` with explicit-tip-list silently misses parent commits
**File:** `2026-04-28T10-02-00Z-coordinator1-cherry-pick-tip-only-misses-parent-commits.md`
**Severity:** MED | **Audit verdict:** ✅ FIXED

**What the finding described:** Cherry-picking only the tip SHA of a multi-commit slice branch applies only that commit's diff, not its parent's. Docs landed without the implementation.

**Proposed fixes (from finding):**
- A: Linter in `coord-cherry-pick` to warn about unlanded parent SHAs
- B: Default to range syntax when a single SHA is given
- C: DM-format convention for peers

**What landed:**
- `92cfb2bd` — `feat(doctor): chain-warn heuristic for multi-commit cherry-picks` — `c2c doctor cherry-pick-readiness <SHA>` detects unlanded ancestors via `git rev-list` and emits a CHAIN-WARN with ancestor list and suggested full-chain command
- `cdc30e0c` — same, pre-deploy check
- `c028e014` / `86b4149e` — `docs: add pre-cherry-pick audit gate to git-workflow.md`

**Status:** ✅ FIXED — Option A (linter/warning) implemented via `c2c doctor cherry-pick-readiness`.

---

## Finding 5 — `c2c get-tmux-location` returns wrong pane under concurrent invocation
**File:** `2026-04-28T12-55-00Z-coordinator1-c2c-get-tmux-location-race.md`
**Severity:** MED | **Audit verdict:** ✅ FIXED

**What the finding described:** `c2c get-tmux-location` called from pane A sometimes returned pane B's location because it queried tmux's server-wide "active pane" instead of the pane-bound `$TMUX_PANE`.

**Proposed fix:** Read `$TMUX_PANE` directly (set per-pane by tmux at fork), fall back to `tmux display-message -t "$TMUX_PANE"` for human-readable form.

**What landed (c2c.ml line 11020–11059):**
- `fast_path_get_tmux_location` reads `Sys.getenv_opt "TMUX_PANE"` directly
- Uses `tmux display-message -t "$TMUX_PANE"` (pane-scoped, not active-pane-scoped)
- Comment explicitly cites "Race fix (#418)"
- Performance: was 1.3–1.6s; the fast path is near-instant (pure env read)

**Status:** ✅ FIXED — exactly as proposed.

---

## Finding 6 — "build clean" peer-PASS claim can be wrong — three reviewers PASSed broken code
**File:** `2026-04-29T02-28-00Z-coordinator1-peer-pass-build-clean-claim-can-lie.md`
**Severity:** HIGH | **Audit verdict:** 🟡 PARTIAL

**What the finding described:** Three independent reviewers gave PASS on `812cce1e` (#379 S1) which failed to compile after cherry-pick (missing `stripped_to_alias` in scope, constructor-signature mismatch). Root cause: reviewers built against master without the slice applied, or reused stale `_build/` cache.

**Proposed fixes (from finding):**
- Review-and-fix skill must run `just install-all` in the slice's own worktree with fresh `_build/` and capture exit code in the peer-PASS artifact
- Add `verified_build` field to peer-PASS artifact schema

**What landed:**
- `.opencode/skills/review-and-fix/SKILL.md` updated with **Pattern 8**: mandatory in-worktree build with `rm -rf _build`, `just build` captured with `rc=N` in `criteria_checked`, explicit `build-clean-IN-slice-worktree-rc=0` entry required
- `--build-rc N` structured field added to `c2c peer-pass sign/send` (v2 artifact schema)
- `--no-build-rc` opt-out for doc-only slices
- Background receipt documented in skill preamble (lines 51–67)

**Remaining gap:** The skill update is a strong procedural fix — reviewers who follow it will produce verifiable build verdicts. However, the finding's core concern (false-positive PASS on broken code from three independent reviewers) is a human/process failure mode that no schema fully prevents if reviewers skip the skill. The fix is proportional to the severity; the class of failure is mitigated but not architecturally closed.

**Status:** 🟡 PARTIAL — procedural fix landed in review-and-fix skill, architectural closure (verified-build precondition in `peer-pass sign`) not implemented.

---

## Finding 7 — git pre-commit hook output leaks into commit message body
**File:** `2026-04-29T03-38-00Z-coordinator1-commit-msg-hook-output-pollution.md`
**Severity:** LOW | **Audit verdict:** ❌ OPEN

**What the finding described:** Cedar's `a58c25b8` commit message contained literal hook stdout (`installed: /home/xertrov/src/c2c/.git/hooks/pre-commit → scripts/git-hooks/pre-commit`) embedded in the body — likely from a shell heredoc with command substitution inside `$(...)`.

**Proposed fixes (from finding):**
1. Document as a class: pre-render commit body to a file, read it back, never let `$(...)` substitutions run inside heredoc
2. Optional `git commit --amend` cleanup (blocked by no-amend-after-PASS convention)
3. Optional pre-commit hook lint to refuse messages containing pathlike strings (overkill)

**Verification:** No code changes found in git log related to hook output filtering, path-in-commit lint, or heredoc discipline. The finding itself says "No action required — filing for next-agent visibility."

**Status:** ❌ OPEN — documentation-only finding. No code fix implemented nor required per finding's own assessment.

---

## Summary Table

| # | Finding | Severity | Status |
|---|---|---|---|
| 1 | Permission reply / stale plugin TUI freeze | HIGH | 🟡 PARTIAL — plugin_version detection added, class of bug still possible |
| 2 | Fresh Claude Code idles without --auto | MED | ❌ OPEN — role-file `auto: bool` (option C) not implemented |
| 3 | Labeled stash slot-shift | LOW | ✅ FIXED — `refs/c2c-stashes/<label>` namespace implemented |
| 4 | Cherry-pick tip-only misses parent commits | MED | ✅ FIXED — `c2c doctor cherry-pick-readiness` warns on unlanded ancestors |
| 5 | `get-tmux-location` race | MED | ✅ FIXED — `$TMUX_PANE` fast path, race documented as #418 |
| 6 | "build clean" peer-PASS claim can be wrong | HIGH | 🟡 PARTIAL — review-and-fix Pattern 8 landed, architectural closure incomplete |
| 7 | Pre-commit hook output leaks into commit body | LOW | ❌ OPEN — documentation-only, no code fix required per finding |
