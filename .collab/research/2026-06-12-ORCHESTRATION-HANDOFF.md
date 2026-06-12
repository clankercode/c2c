# Orchestration Handoff — connect-docs push + 3 features (2026-06-12/13)

Resume state for claude orchestrator (interactive session for Max). Companion:
`.collab/research/2026-06-12-agent-scorecard.md` (per-agent grades + catches).

## Active background jobs (CHECK ON RESUME) — updated 2026-06-13 ~01:00

**STEP-CAP PATTERN (important):** all 3 features exceed the ccc 100-step cap. The original
`ccc @kimi` runs each hit "Max number of steps reached: 100" and exited rc=1 (NOT a real failure).
Resume preserves context via: `kimi -r <session-id> -y --print -p "<continuation>"` (run from the
worktree cwd; a resumed run gets a fresh 100-step budget). Session IDs are printed in each capped
run's tail ("To resume this session: kimi -r <id>").

| Feat | Worktree | Status | Current job id |
|---|---|---|---|
| **A** connect-metadata | wt-feat-connect-metadata | ✅✅ **DONE + glm51 peer-PASS @ 872f257e** (build rc=0; onboarding 13/13, mcp 364/364; +2 coverage tests omit-when-false & re-register-discard; guard-invariant verified). Ready to merge (held for full feature push). | — done |
| **B** name-nonce (RISKIEST) | wt-feat-name-nonce | ⏳ resumed — was mid-build-error, NO impl commits yet (blocklist.ml+nonce.ml created, 9 files modified). Must reach build rc=0 + tests + per-slice commits. | resume `bqqscise8` (kimi sess 8a7dc590) |
| **C** embed-plugins | wt-feat-embed-plugins | ⏳ resumed — C1 `71c35350` + C2 `64c21b03` committed; finishing C3 (byte-eq sync-gate, MUST verify fails-when-stale) + C4 docs. | resume `b6zy68lhn` (kimi sess 0bb2db81) |

On EACH completion: read task output, validate build+tests IN-WORKTREE (`opam exec -- dune build
--root <wt> -j2`; opam env NOT in orchestrator shell — wrap in `bash -lc 'eval "$(opam env)"; …'`
or `opam exec --`), then run a DIFFERENT-model peer-review that **MUST verify test coverage**
(Max's explicit ask), scrub any `.opencode/package.json` churn, update scorecard. B is riskiest —
confirm its 2 codex blocker tests pass (origin env-marker; `--require-easy` termination).
Prompts: `/tmp/c2c-prompts/impl-feat{A,B,C}.txt`, `/tmp/c2c-prompts/review-featA.txt`.

**ccc conventions (Max, 2026-06-13 — also in memory `ccc-usage-prefs`):** use `ccc @kimi`
(configured alias); do NOT hide output via `>log 2>&1` (run_in_background WITHOUT redirect; read
the task `.output`); prefer parallel agents.

DONE: S4 (c2c connect) — kimi peer-PASS `b7653357`, orchestrator-validated (build rc=0,
install-all epilog + alias-preservation confirmed). kimi found 2 bugs glm51 missed.

## CONNECT-DOCS FLAGSHIP PUSH (Max-approved spec: .collab/design/2026-06-12-connect-experience-improvements.md)
One push, 4 slices, each its own worktree. Each: ccc impl → review-and-fix → DIFFERENT-model
peer-PASS → orchestrator validates (build/test/content) + scrubs env churn → scorecard.

| Slice | Worktree / branch | HEAD | Status |
|---|---|---|---|
| S1 docs truth + Gemini/Crush removal | wt-connect-s1-docs / feat/connect-s1-docs-truth | **9ab652ca** | ✅ DONE + mm3 peer-PASS |
| S2 CLI gemini-refuse + init hint | wt-connect-s2-cli-removal / feat/connect-s2-cli-removal | **7d6b9061** | ✅ DONE + glm51 peer-PASS |
| S3 journey restructure | wt-connect-s3-journey / feat/connect-s3-journey (chained on S1) | **acbadeb8** | ✅ DONE + mm3 peer-PASS (content-loss audit clean) |
| S4 `c2c connect` cmd | wt-connect-s4-connect-cmd / feat/connect-s4-connect-cmd (chained on S2) | **b7653357** | ✅ DONE + kimi peer-PASS (found install-all epilog gap + --verify alias-clobber) |

**S4 verified working live by orchestrator:** `c2c connect` dashboard renders (broker/registry/
sessions/rooms/per-client incl codex+kimi detection/next-step); `c2c connect --verify` flags
present; 14 connect-specific tests pass; build rc=0. OUTSTANDING for S4: (a) kimi triage of the
~14 broader-suite failures (prove pre-existing vs S4-epilog-regression), (b) **LIVE TMUX DOGFOOD
of `c2c connect --verify` — orchestrator must run this; ccc can't drive multi-client tmux**
(use scripts/c2c_tmux.py per CLAUDE.md), then S4 peer-PASS.

**After all 4 peer-PASS + S4 dogfood:** task #35 — merge S1-S4 to master, `just bi`, jekyll build
(modern stack), `c2c doctor` verdict, ONE `git push origin master` (Railway + Pages). Relay.ml
unchanged → relay behavior identical; Pages is the live change.

**Known follow-up (non-blocking):** `docs/index.md:176,205` use `./known-issues.md`/`./commands.md`
relative links that 404 on the live site (kramdown keeps `.md`) — pre-existing; fix during
integration/push (same class mm3 fixed in get-started.md).

## THREE FEATURES (plans hardened, NOT implemented — queued AFTER connect-docs)
Plans reviewed TWICE (non-codex round + codex final), all fixes folded + committed.
| Feature | Worktree / branch | Plan HEAD | Notes |
|---|---|---|---|
| A connect-metadata | wt-feat-connect-metadata / feat/connect-metadata | **e7e3a11f** | reuse cwd+slug; opt-out=consent flag (cwd always captured for worktree guard); fix CLI/MCP cwd asymmetry. Plan ready. |
| B name-hardening+nonce | wt-feat-name-nonce / feat/name-nonce | **7afe5566** | RISKIEST. Nonce=auto-gen-only. Codex blockers captured in plan: (1) `from_auto_gen` lost across `C2C_MCP_AUTO_REGISTER_ALIAS` env boundary → propagate via sibling env marker; (2) `--require-easy` infinite loop (3-seg nonce) → validate bare words before nonce. Blocklist user-supplied-only. |
| C embed-plugins | wt-feat-embed-plugins / feat/embed-plugins | **870faef1** | embed opencode c2c.ts via `just` codegen; hybrid drift gate; add explicit else in c2c_start.ml:4637; byte-eq sync test (resolve data path from repo root not _build). Plan ready. |
Tasks #28/#29/#30. Investigations: `.collab/research/2026-06-12-three-feature-investigations.md`.
Codex plan review: `.collab/research/2026-06-12-three-plans-REVIEW-codex.md`.

## PROCESS + GOTCHAS (learned this run)
- **Models:** ccc opencode aliases `@glm51` (best/slower), `@mm3` (bug-finder), `@mimo25p`
  (reliable/faster); `@cx-reviewer`/`@cx-coder` (codex); **kimi via `ccc --yolo k +3`** (Max:
  0% weekly quota, prefers using it). Launch ccc from the worktree cwd.
- **Each ccc impl prompt MUST forbid `git stash`** (Pattern 13 — shared stash list; glm51 used
  it on S4, no damage that time but it's a footgun). Now in the kimi S4 prompt.
- **ccc opencode agents leave `.opencode/package.json` modified (env plugin bump)** — scrub
  (`git checkout -- .opencode/package.json`) BEFORE committing/merging any slice.
- **Jekyll broken on host Ruby 3.4.8** (pinned github-pages Jekyll 3.10.0) — build docs with a
  modern stack (Jekyll 4.x + minima). Finding: `.collab/findings/2026-06-12-jekyll-broken-on-ruby-348.md`.
  Orchestrator shell lacks jekyll entirely (rc=127) — validate docs by content + let ccc build.
- **Validation discipline:** independently re-run build/tests + smoke the binary; agents have
  over-claimed (S2 "6/6 green" failed on my misinvocation due to a non-hermetic test; agents
  call suite failures "pre-existing" — VERIFY against base).
- **git:** main-tree commits need `C2C_COORDINATOR=1` (pre-reset shim). Chain-slices branch from
  the prerequisite slice's branch tip, not origin/master. NEVER push (gated; Max/coord).
- Prompts archived in `/tmp/c2c-prompts/` (impl-S*.txt, review-*.txt, review-plan-*.txt).

## IMMEDIATE NEXT STEPS (resume order)
1. When `b8zt9vv99` (kimi S4) completes → read `/tmp/c2c-prompts/review-S4.log`, validate triage
   + fixes, scrub churn, update scorecard, set S4 HEAD.
2. Run the **live tmux dogfood** of `c2c connect --verify` (≥2 clients) — orchestrator task.
3. Mark S4 done (#34). Then #35: integrate S1-S4 + the index.md link follow-up → one push (Max
   gates; he granted push latitude this session).
4. Then features A/B/C implementation (#28-30), B last/most-careful.
