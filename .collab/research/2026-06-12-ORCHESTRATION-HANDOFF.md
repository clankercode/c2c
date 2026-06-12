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
| **B** name-nonce (RISKIEST) | wt-feat-name-nonce | ✅✅ **DONE + mm3 peer-PASS @ f397d807**. mm3 found+fixed 2 more test_c2c_start tests kimi missed, added build_env end-to-end coverage (managed start writes alias+marker="1", explicit→marker="0"), +6 env-marker tests, verified full coverage checklist, no prod code changed, scrubbed .opencode. Orchestrator reconfirmed build rc=0 + all suites green (1 failure = pre-existing get_tmux_location TMUX-not-set env). Ready to merge. | — done |
| **C** embed-plugins | wt-feat-embed-plugins | ✅✅ **DONE + codex peer-PASS @ 36f7e102**. codex fixed the non-hermetic test (resolve dev-source from install target tree not CWD), strengthened the sync-gate assertion, made drift-doctor project-local, removed legacy global hints. 4 fix commits. Orchestrator reconfirmed binary-only test passes via `dune exec` from worktree root (orig failure mode) + 4/4 embedded + idempotent codegen. Ready to merge. | — done |

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

## FLAGSHIP SHIPPED — 2026-06-13 (origin/master @ 16064f0f)
All 7 branches merged to master + pushed (Max-authorized). Pipeline:
- Merged: connect-docs S1 `30af741e` / S3 `9e405168` / S2 `1cf6b480` / S4 `af953b3e`
  (commands.md conflict resolved: gemini/crush-removed list + connect --verify guidance),
  then features A `4718ff29`, B `55bf76e8`, C `79ee8198`.
- A×B conflicts (register sig/record, identity handler, c2c.ml, c2c_setup.ml, test_c2c_cli):
  combined `?metadata_opt_out` + `?from_auto_gen`; gemini dispatch stayed removed (S2) + got
  `~alias_from_auto_gen`. B×C conflicts (c2c_start.ml 3×): combined `alias_from_auto_gen` +
  `opencode_plugin_embedded`. client-delivery.md: kept S3 concise structure + grafted C's
  embedded-blob OpenCode sentence.
- INTEGRATION GAP FIXED: `test_c2c_gemini_deprecation` dune target (added by S2) listed
  `c2c_setup` but not `c2c_opencode_plugin_embedded` (C's module) → added it. Build then clean.
- index.md link-404 follow-up: `./commands.md`→`/commands/`, `./known-issues.md`→`/known-issues/` `16064f0f`.
- Validation: full build rc=0; every feature suite green IN ISOLATION (mcp 372, identity 17,
  name 2, onboarding 13, setup_kimi 17, embedded 4, drift 6, gemini-deprecation 6). Full
  parallel `@runtest` shows 25 failures = 14 documented pre-existing env-sensitive (test_c2c_cli:
  schedule/peer_pass/send/worktree/memory/instances) + get_tmux_location (TMUX unset) +
  parallelism flakiness (send_from_spoofing/connect_dashboard PASS in isolation). NO regressions.
- `just bi` rc=0 (installed). Smoke: gemini-refuse✓, --no-metadata✓, --no-nonce✓, connect✓.
- Pushed. Railway (relay.ml UNCHANGED → behavior identical) + Pages rebuilding.
- POST-DEPLOY TODO: after Railway ~10-15min, `./scripts/relay-smoke-test.sh`; verify c2c.im docs render.
- Safety tag `pre-flagship-integration` @ b8d9ee93 (pre-merge master).

## NEXT FEATURE — install transparency + `c2c uninstall <component>` (IN PROGRESS 2026-06-13 ~03:10)
Max-requested. Worktree `.worktrees/wt-uninstall` / branch `feat/uninstall-manifest` (base
origin/master 16064f0f). Spec+inventory committed @ be8e1e6b in that worktree:
- `.collab/design/2026-06-13-uninstall-and-install-manifest-spec.md`
- `.collab/research/2026-06-13-install-surface-inventory.md` (full OWNED-vs-SHARED map)
Max decisions: granularity = per-client+self+git-hook+git-shim+all; tracking = install manifest
($XDG_STATE_HOME/c2c/install-manifest.json); uninstall = execute+print, `--dry-run` preview;
legacy = manifest-primary + recompute fallback (whole swarm already installed w/o manifest).
Impl dispatched: ccc @kimi `bloxdk0k1` (prompt `/tmp/c2c-prompts/impl-uninstall.txt`), slices
U1 manifest module → U2 install wiring+output → U3 uninstall command (surgical SHARED-key/block
strip + recompute fallback) → U4 docs. TESTS MANDATORY; critical safety test = user keys survive
when only the c2c stanza is stripped. On completion: validate in-worktree, different-model
peer-PASS w/ test-coverage check, then Max review (do NOT push without Max).

### UNINSTALL FEATURE PROGRESS (2026-06-13 ~03:25, pre-compact)
- U1 COMMITTED @ `8c267363` in wt-uninstall (manifest module `ocaml/c2c_install_manifest.ml`+`.mli`
  in c2c_mcp library + unit tests). Agent `bloxdk0k1` ALIVE, on U2 (wiring manifest writes into
  c2c_setup.ml). Spec @ `be8e1e6b`.
- RESUME ON CAP: if ccc hits the 100-step cap (rc=1 "Max number of steps reached"), resume with
  `kimi -r <session-id> -y --print -p "<continuation>"` from `.worktrees/wt-uninstall` (session id
  in task tail "To resume this session: kimi -r <id>"). Build in-worktree:
  `bash -lc 'eval "$(opam env)"; dune build --root .worktrees/wt-uninstall -j2'` (opam NOT in
  orchestrator shell). Critical uninstall test: a SHARED user config keeps the user's OWN keys
  after only the `c2c` stanza is stripped.
- On full completion: validate build+tests in-worktree → DIFFERENT-model ccc peer-PASS that
  verifies test coverage → HOLD for Max review (do NOT push without Max).

### UNINSTALL FEATURE — IMPL COMPLETE + LOCAL-VALIDATED, PEER-PASS IN FLIGHT (2026-06-13 ~03:56)
All 4 slices done in wt-uninstall (branch feat/uninstall-manifest). Kimi session
`deb20082-51d9-4b46-b1ec-a296b0d6343e` hit the 100-step cap TWICE; resumed each time
(`kimi -r <id> -y --print -p`). Commits on branch:
- `8c267363` U1 manifest module + unit tests
- `043b2e4d` wip(U2) step-cap checkpoint (mid-refactor; superseded by next two)
- `a9ebbec6` U2+U3 manifest wiring, consolidated output, `c2c uninstall` cmd + tests
- `71c20455` U2+U3 wire manifest into setup, register uninstall, update install test
- `d4292846` U4 docs (commands.md + CLAUDE.md + .collab/runbooks/c2c-install.md) — **HEAD**

INDEPENDENT VERIFICATION (orchestrator, not on agent's word):
- Fresh `dune build --root . -j2 ./ocaml/cli/c2c.exe` → **rc=0**.
- `python -m pytest tests/test_c2c_uninstall.py` → **8/8 pass** against the FRESH worktree
  c2c.exe (repo-root `./c2c` shim prefers `_build/default/ocaml/cli/c2c.exe`; install+uninstall
  both fall through to native). SHARED-file-safety covered: `test_uninstall_codex_preserves_user_toml_and_is_idempotent`,
  `test_uninstall_kimi_preserves_user_json_keys`, `test_uninstall_opencode_preserves_user_json_keys`
  — user keys survive, only c2c stripped; idempotent 2nd-run "nothing to remove".
- `@runtest` rc=1 BUT the 15 failures are the KNOWN env-sensitive set (send relay-fallback,
  schedule_*, memory_list, worktree_*, instances --json, peer_pass_list, connect_dashboard) —
  branch does NOT touch test_c2c_cli.ml / c2c_relay.ml / c2c_send.ml (git diff origin/master empty).
  ZERO manifest/uninstall/setup failures. Pre-existing, not feature-caused.

PEER-PASS (different model = codex, ≠ kimi impl): dispatched `ccc --yolo @cx-reviewer`,
background task `b2ummejkc`, prompt `/tmp/c2c-prompts/review-uninstall.txt`. Review-and-fix loop;
fixes land as NEW commits on the branch. Awaiting explicit PASS/FAIL verdict +
`build-clean-IN-slice-worktree-rc=0` token.

GATE: **HOLD for Max review — do NOT push.** Uninstall mutates user configs; Max gates this one
even though flagship push authority was granted earlier (that was scoped to the flagship merge).
