# Agent Scorecard — 2026-06-12 connect-docs + 3-feature run

Tracks how each delegated ccc/subagent performed: task, verdict/quality, issues, commit, notes.
Maintained by the orchestrator (claude). Updated as each agent lands.

## Legend
- **Quality**: ⭐ excellent / ✅ solid / ⚠️ usable-with-fixes / ❌ poor
- **Committed**: SHA where the validated output landed (or "pending")

---

## Investigations (read-only scoping)

| Agent | Task | Verdict delivered | Quality | Issues / corrections | Committed |
|---|---|---|---|---|---|
| opus Agent | Feature A metadata investigation | PRACTICAL (mostly built) | ⭐ | Found real CLI/MCP cwd bug; flagged worktree-guard interaction | research doc (main) |
| opus Agent | Feature B nonce/blocklist investigation | PRACTICAL-w-caveats | ⭐ | Exhaustive surface map; correct chokepoint analysis | research doc (main) |
| ccc/glm51 | Feature C embed-plugins investigation | PRACTICAL (mostly built) | ⭐ | Correct: only opencode repo-dependent; embed idiom right | research doc (main) |

## Plan reviews (non-codex first pass)

| Agent | Task | Verdict | Quality | Key catches | Committed |
|---|---|---|---|---|---|
| ccc/glm51 | Review Plan C (embed-plugins) | SOUND-WITH-FIXES | ✅ | (1) path anchor `ocaml/c2c_start.ml` not `ocaml/cli/`; (2) missing `else` at c2c_start.ml:4637 silent no-op; (3) list all 4 justfile recipes; (4) codegen confirmed safe (no `|}` collisions) | review+fixes @ **556fe6c3** |
| ccc/mimo25p | Review Plan A (connect-metadata) | SOUND-WITH-FIXES | ⭐ | CRITICAL: caught self-contradiction — `--no-metadata` skipping `~cwd` would break the worktree guard; flagged state-carryover ambiguity + missing guard-invariant test. 11 anchors spot-checked (off ≤4 lines) | review+fixes @ **b2295a71** |
| ccc/mm3 | Review Plan B (name-nonce) | NEEDS-REWORK | ⭐ | CRITICAL: blocklist first-segment match would reject every auto-gen `codex-…`/`kimi-…` name → every default `c2c setup` fails. Also: disproved my "module cycle" (non-issue), flagged dead MCP `no_nonce` arg, stale Random.seed, 2-not-3 doc places, +2 missing call sites | review+rework @ **d80fe10a** |

## Implementation slices

| Agent | Slice | Build/Test | Quality | Issues | Committed |
|---|---|---|---|---|---|
| ccc/mimo25p | S1 connect-docs truth pass | PASS; agent jekyll rc=0; 12 files | ✅ | Clean removal (front-door Gemini/Crush gone, `layout: docs` fixed, 3 historical files correctly preserved). Orchestrator independently re-verified content + scrubbed `.opencode/package.json` env churn. CAVEAT: agent's "peer-PASS" was a self-sub-review (NOT a real different-model peer-PASS); jekyll build not reproduced locally (jekyll gem not in orchestrator env). | 4 commits, head **91ea99b3** |
| ccc/mimo25p | S2 CLI gemini-refuse + init hint | PASS; build rc=0 (orchestrator-verified in-worktree); binary refuses `install gemini` exit 1 w/ clean JSON | ✅ | Feature CORRECT (verified worktree binary refuses; dormant `setup_gemini`/`GeminiAdapter` preserved). Slightly over-scoped into role-template gemini cleanup (in-bounds). **Found defect:** new `test_c2c_gemini_deprecation.ml` `find_c2c_binary` falls back to PATH `c2c` → NON-HERMETIC (false-red on my run, false-green risk vs stale installed binary) — harden in peer-review. Agent's "20 pre-existing failures unrelated" = TRUE (e.g. `test_c2c_peer_pass` git-trailer; untouched by S2). Env churn scrubbed. Still needs a REAL different-model peer-PASS. | 3 commits, head **181d4209** + scrub |

## Codex second-opinion pass (final gate over hardened plans)

| Agent | Task | Verdict (per plan) | Quality | Key catches beyond round 1 | Committed |
|---|---|---|---|---|---|
| ccc/cx-reviewer (codex) | Final review A/B/C | A: MINOR-FIXES · B: STILL-NEEDS-REWORK · C: MINOR-FIXES | ⭐ | **B blocker 1:** `from_auto_gen` lost across `C2C_MCP_AUTO_REGISTER_ALIAS` env boundary → default install alias re-blocked. **B blocker 2:** `--require-easy` infinite loop (3-segment nonce). **A:** record/sig also in `c2c_mcp_helpers.ml` + `c2c_mcp.mli` (build-fail otherwise). **C:** test path/Dune wiring under-specified. **B3:** stale `claude-quill` example. | review @ `.collab/research/…REVIEW-codex.md`; fixes folded (SHAs below) |

---

## Implementation peer-reviews (different-model peer-PASS)

| Reviewer | Slice | Verdict | build-in-worktree | Fixed | Final SHA |
|---|---|---|---|---|---|
| ccc/glm51 | S2 (impl by mimo25p) | **PASS** | rc=0 | Hardened non-hermetic `find_c2c_binary` → `Sys.executable_name`, fail-loud, no PATH fallback. Confirmed all advertised surfaces clean, routing intact, dormant code preserved | **7d6b9061** |
| ccc/mm3 | S1 (impl by mimo25p) | **PASS** | jekyll rc=0 (modern stack) | Found+fixed orphan `---`→double `<hr>` after Crush-section removal. Verified client-count consistency (~11 files), layout fix, 3 historical exclusions correct, no broken links. **ENV finding:** pinned github-pages Jekyll 3.10.0 is broken on Ruby 3.4.8 (reproduces on origin/master — pre-existing, NOT a slice regression) | **9ab652ca** |

| ccc/mm3 | S3 (impl by mimo25p) | **PASS** | jekyll rc=0 (modern stack) | **Content-loss audit CLEAN** — enumerated all ~16 delivery cells + extras, every unique fact survives in summary/feature-matrix/runbooks, zero restorations. Fixed 2 link-404s (feature-matrix permalink, `./known-issues.md`→`/known-issues/`). Flagged pre-existing `index.md` relative-link 404 footgun (out of scope) | **acbadeb8** |

S1 STATUS: ✅ DONE — mm3 peer-PASS, 1 defect fixed, jekyll clean (modern stack).
S2 STATUS: ✅ DONE
S3 STATUS: ✅ DONE — mm3 peer-PASS, content-loss audit clean, 2 link fixes.
FOLLOW-UP (small, non-blocking): `docs/index.md:176,205` use `./known-issues.md` / `./commands.md`
relative links that 404 on the live site (kramdown keeps `.md`). Pre-existing; fix during the
connect-docs integration/push or a tiny drive-by. Same class mm3 fixed in get-started.md. — feature correct (orchestrator-verified binary refuses), hermetic test (6/6 pass), real different-model peer-PASS, build rc=0. Ready to merge (held until full connect-docs push).

## Plan-fix log (fixes folded back from reviews)
- Plan C: glm51's fixes folded (paths → `ocaml/c2c_start.ml`, explicit else-branch at :4637,
  all 4 justfile recipes) → committed `556fe6c3` on feat/embed-plugins.
- Plan A: mimo25p's fixes folded (always-capture cwd, discard metadata_opt_out on re-register,
  guard-invariant regression test) → committed `b2295a71` on feat/connect-metadata.
- Plan B: mm3's rework folded (blocklist user-supplied-only via `?from_auto_gen`, dropped the
  bogus module-cycle mitigation + dead MCP `no_nonce` arg, added 2 call sites + tests g/h +
  Random.self_init + 2-place doc invariant) → committed `d80fe10a` on feat/name-nonce.

- Codex final-pass fixes folded: Plan A `e7e3a11f` (helpers/mli scope); Plan B `7afe5566`
  (env-boundary origin propagation + `--require-easy` loop + stale example + mli sig); Plan C
  `870faef1` (test path/Dune wiring). **Plan B now requires the codex-flagged origin-marker +
  require-easy fixes implemented before it's safe** — see plan blockers B-origin / B-require-easy.

## Reviewer effectiveness summary (interim)
All 3 non-codex plan reviews caught REAL defects that would have reached implementation:
- glm51 (Plan C): silent no-op bug + wrong path anchor → ✅ solid
- mimo25p (Plan A): guard-breaking opt-out contradiction → ⭐ excellent
- mm3 (Plan B): blocklist-breaks-every-default-setup + 5 more → ⭐ excellent (best catch)
Net: the non-codex-first review pass was high-value; none were rubber-stamps. Plans A/B/C
are materially stronger. Codex `cx-reviewer` second pass still to run over the hardened plans.

## Notes
- `.opencode/package.json` env churn appears in wt-connect-s1-docs — must be scrubbed before
  S1 commit/merge (machine-specific plugin bump, not part of the slice).
