# Connect Experience — Implementation Plan (flagship push)

> **For agentic workers:** each SLICE = one worktree under `.worktrees/`, branched from
> `origin/master`. Implement via ccc subagent, then run `review-and-fix` to PASS, then a
> DIFFERENT-model peer cross-review with build-clean produced INSIDE the slice worktree
> (`build-clean-IN-slice-worktree-rc=0` in `criteria_checked`). New commit per fix, never
> `--amend`. Do NOT push — all slices batch into ONE origin/master push gated by Max/coord.

**Goal:** Make the c2c.im connect docs + the `c2c` connect experience match the "three
short steps, it Just Works" promise: strip the deprecated Gemini/Crush, fix the front-door
journey, and ship a `c2c connect` command that confirms delivery is live.

**Architecture:** Docs are Jekyll (publish-by-default → stage in worktrees, build locally).
The OCaml `c2c connect` umbrella command wraps existing `c2c health` checks (dashboard) and
adds a loopback delivery probe (`--verify`) that observes the broker archive `drained_by`
label. One flagship push, multiple independent + chained slices.

**Source spec:** `.collab/design/2026-06-12-connect-experience-improvements.md` (APPROVED by
Max 2026-06-12). Read it for full evidence/decisions; this doc is the executable slicing.

---

## Slice map

| Slice | Worktree / branch | Phase | Depends on | Build cost |
|---|---|---|---|---|
| S1 | `wt-connect-s1-docs` / `feat/connect-s1-docs-truth` | P1 docs truth + Gemini/Crush removal (docs only) | — | none (Jekyll) |
| S2 | `wt-connect-s2-cli-removal` / `feat/connect-s2-cli-removal` | P1 CLI: `c2c install gemini` refuses; init hint → 4 clients | — | OCaml |
| S3 | `wt-connect-s3-journey` / `feat/connect-s3-journey` | P2 journey restructure (docs) | S1 (avoid doc conflicts) | none (Jekyll) |
| S4 | `wt-connect-s4-connect-cmd` / `feat/connect-s4-connect-cmd` | P3 `c2c connect` dashboard + `--verify` + epilog unify + init/install-all fixes | S2 (shares init/setup edits) | OCaml |

Independent: S1, S2 can start immediately and in parallel. S3 starts after S1 merges
into its branch base OR is authored to avoid touching S1's exact lines (it restructures
`get-started.md`/adds pages; S1 only truth-edits existing lines — low conflict, but
sequence S3 after S1 to be safe). S4 depends on S2 (both touch `c2c_setup.ml` init/epilog
regions) — chain S4 on S2's branch tip per branch-per-slice §chain-slice, OR author S4 to
not collide and rebase at merge time. Recommend: land S2 first, then branch S4 from it.

---

## Slice S1 — Docs truth pass + Gemini/Crush removal (DOCS ONLY)

**Worktree:** `.worktrees/wt-connect-s1-docs` · **Branch:** `feat/connect-s1-docs-truth`

**Decisions:** REMOVE Gemini + Crush from the public/front-door docs (four supported
clients: Claude, Codex, OpenCode, Kimi). Leave archived design docs under
`docs/superpowers/{plans,specs}/` untouched (historical record). Audit — do NOT blind-delete
— stale `.py` refs (keep intentionally-historical ones, repoint how-to ones to OCaml).

**Files (front-door only):**
- `docs/_layouts/home.html:24` — hero stat `"4 clients + Crush exp"` → honest four-client
  statement (e.g. `"4 clients"` / `"Claude · Codex · OpenCode · Kimi"`); make the hardcoded
  fallback consistent with `index.md` front-matter.
- `docs/index.md` — kill the 4-vs-5 contradiction (`:52` "Five clients" vs `:53`
  "Four-client parity"); remove Gemini from hero lead + any client list; fix the `:55`
  "full changelog" reference if it names get-started (the URL move is S3 — here just ensure
  no Gemini/Crush).
- `docs/overview.md:11,22` — client list + ASCII diagram: ensure four clients, no Gemini;
  audit `.py` refs at `:60,85`.
- `docs/get-started.md:15,18` — remove the 4-vs-5 Gemini contradiction (content rewrite is
  S3; here only the truth-pass of client count).
- `docs/clients/feature-matrix.md:4` — replace `layout: docs` with a valid layout
  (`page`/default per `_config.yml` minima); confirm four-client columns, no Gemini; fix
  Crush mentions.
- `docs/clients/e2e-checklist.md:4` — replace `layout: docs`; remove Crush.
- `docs/client-delivery.md` — remove Gemini sections (`:334,451`) + Crush; audit `.py` refs
  (`:231,294,300-301,437` — keep historical-context ones, repoint how-to).
- `docs/commands.md` — truth-pass relay/install duplicated surfaces (`:857-876,928-943`);
  remove Gemini/Crush; fix the pool/format invariant copy at `:994` if touched.
- `docs/known-issues.md:11,59,92,94` — remove `crush` + `run-*-inst-outer` stale guidance;
  audit `.py` refs.
- `docs/communication-tiers.md` — remove Crush if present.

**Steps:**
1. `grep -rn -iE 'gemini|crush' docs/ | grep -v 'docs/superpowers/'` → worklist; for each
   front-door hit decide remove vs (historical) keep.
2. Edit each file above. For `.py` refs: `grep -rn '\.py' docs/ | grep -v superpowers` →
   repoint how-to to the OCaml subcommand, keep deprecation-context lines.
3. Build locally: `cd <worktree> && bundle exec jekyll build` → zero layout warnings.
4. Verify every command block touched against `c2c <subcmd> --help` (doc-hygiene rule).
5. Commit per logical group (hero, index/overview, clients/, delivery, commands,
   known-issues).

**AC:** `grep -riE 'gemini|crush' docs/ | grep -v superpowers/` returns only intentional
historical mentions; Jekyll builds warning-free; no `layout: docs` remains; client count is
consistently four; docs-up-to-date gate satisfied.

**Final:** `review-and-fix` → PASS; peer cross-review (different ccc model) with a local
Jekyll build verdict captured in the artifact. No push.

---

## Slice S2 — CLI Gemini removal + init hint (OCaml)

**Worktree:** `.worktrees/wt-connect-s2-cli-removal` · **Branch:** `feat/connect-s2-cli-removal`

**Decisions:** `c2c install gemini` should REFUSE (exit 1) like `c2c start crush` does. Leave
`GeminiAdapter`/`setup_gemini` code DORMANT (no deletion) — just gate the install entry +
remove gemini from advertised client lists/help. Fix the `init` no-client hint to list the
four supported clients (not the stale `opencode/claude/codex/codex-headless`).

**Files:**
- `ocaml/cli/c2c_setup.ml` — the gemini install entry (`setup_gemini` dispatch in
  `do_install_client` ~`:1532-1537`): make the `gemini` case print a deprecation/refuse
  message and return non-zero (mirror how `crush` is handled in `c2c_start.ml`'s refuse).
  Remove gemini from `known_clients` advertised for install / the init-configurable list
  (`:1469-1470`) so it's not auto-offered.
- `ocaml/cli/c2c.ml:6739-6743` — `init` no-client hint: list `claude codex opencode kimi`.
- Help/usage strings that enumerate clients including gemini — grep
  `grep -rn -i gemini ocaml/cli/*.ml` and gate/remove from advertised surfaces (NOT the
  adapter internals).

**Steps (test-first):**
1. Add/extend a test (`ocaml/cli/test_c2c_setup*.ml` or `test_c2c_cli.ml`): assert
   `c2c install gemini` exits non-zero with a deprecation message; assert the init hint
   lists the four clients. Run → FAIL.
2. Implement the refuse + hint edit. Build: `opam exec -- dune build --root <wt> -j2`.
3. Run the new test + full suite (`-j2`) → PASS.
4. Verify `crush` parity (`c2c start crush` already refuses) — match the message style.
5. Commit.

**AC:** `c2c install gemini` rc≠0 with a clear deprecation note; gemini absent from
advertised install/init client lists + help; adapter code still compiles (dormant); init
hint shows four clients; suite green in-worktree.

**Final:** `review-and-fix` → PASS; peer cross-review with `build-clean-IN-slice-worktree-rc=0`.

---

## Slice S3 — Journey restructure (DOCS)

**Worktree:** `.worktrees/wt-connect-s3-journey` · **Branch:** `feat/connect-s3-journey`
**Sequence:** after S1 (shares `get-started.md`/`index.md`).

**Scope (from spec P2):**
- **`/get-started/` → real quickstart; changelog → `/changelog/`.** Create
  `docs/changelog.md` (`permalink: /changelog/`, `layout` valid) and MOVE the "What's
  Shipped Recently" content there. Rewrite `docs/get-started.md` as the canonical 3-step
  quickstart (install → `c2c init` → restart → **`c2c connect --verify`** "is it working?").
  Fix `docs/index.md:55` "full changelog" link → `/changelog/`. Update nav
  (`_config.yml:21`) if needed. Preserve the `/get-started/` permalink.
- **Path fork** near the front door: (a) local swarm (`c2c init`, swarm-lounge), (b) reach a
  specific person across machines → `/connect/` (relay register, Ed25519 TOFU), (c) run your
  own relay → relay-quickstart. Short signpost, one line each, links out. INCLUDE the
  human-operator / cross-machine relay on-ramp here (replaces the deferred rooms page).
- **Consolidate per-client delivery** onto `docs/clients/feature-matrix.md` as the single
  source; make `docs/client-delivery.md` a thin summary that links to it (declare
  feature-matrix authoritative).
- **Newcomer troubleshooting** section: "ran init but `list` shows nobody"; "friend can't
  reach me (wrong path)"; "messages only arrive when I poll → you didn't restart; run
  `c2c connect --verify`".

**Steps:** create `/changelog/`, rewrite quickstart, add fork signpost, consolidate
delivery, add troubleshooting; `bundle exec jekyll build` warning-free + link-check the
moved permalink and `index.md:55`; verify command blocks vs `--help`.

**AC:** `/get-started/` is a quickstart ending in the verify step; `/changelog/` holds the
release notes with the homepage link fixed; the path fork is present with the relay on-ramp;
delivery info lives once on feature-matrix; troubleshooting present; build warning-free.
NOTE: references to `c2c connect --verify` are forward-looking — fine in docs; the command
lands in S4 (same push).

**Final:** `review-and-fix` → PASS; peer cross-review with local Jekyll build verdict.

---

## Slice S4 — `c2c connect` umbrella command + doctor unification (OCaml)

**Worktree:** `.worktrees/wt-connect-s4-connect-cmd` · **Branch:** `feat/connect-s4-connect-cmd`
**Sequence:** branch from S2's tip (chain-slice) — shares `init`/install epilog regions.

**Scope (from spec P3 §5):**
1. **`c2c connect` (bare) — dashboard, repo-independent.** New Cmdliner command (register in
   the top-level group near `health`/`doctor`). Wraps the existing `c2c health` checks
   (`c2c.ml:2158-2244`) into a friendly summary: alias/registration (`whoami` + liveness),
   per-supported-client install + auto-delivery status, relay status, rooms, and THE ONE
   NEXT STEP. EXTEND `check_plugin_installs` (`c2c.ml:2008-2058`) to cover Codex + Kimi
   (currently Claude/OpenCode/GUI only).
2. **`c2c connect --verify` — loopback delivery probe.** Enqueue a UNIQUE NON-EPHEMERAL
   self-marker through the configured broker; watch the archive `drained_by`
   (`c2c_broker.ml:2312-2358`) for that marker for N seconds; report:
   - `PASS: consumed by auto-delivery path <drained_by>`
   - `INCONCLUSIVE: still queued — restart your client / it may use poll delivery`
   - `FAIL: broker/registration/config path broken`
   - `NOT PROVEN: <client> transcript visibility is client-specific, not CLI-observable`
   NEVER ephemeral (ephemeral drains aren't archived, `c2c_broker.ml:2273-2276`); NEVER drain
   the user's real inbox — isolate by unique marker; if it can't isolate, say so. Exit non-
   zero on FAIL.
3. **`c2c connect --fix` (optional)** — offer to run the missing install/init step the
   dashboard found (thin wrapper over existing install/init). Defer if time-constrained.
4. **Doctor unification:** make `init`/`install`/`install all` epilogs end with the ONE
   canonical line `Run 'c2c connect --verify' to confirm delivery is live` (replace per-client
   `opencode mcp list`/`gemini mcp list` fragments). ADD the restart footer to `install all`
   (`c2c_setup.ml:1852-1877`, currently just `Done.`).
5. **`init` fixes:** stop swallowing the identity step
   (`c2c relay identity init 2>/dev/null`, `c2c.ml:6782-6784`) — surface a real error/hint
   on failure. (The no-client hint is done in S2.)

**Steps (test-first, fixture-gated broker):**
1. Tests first: (a) `--verify` PASS when a marker is drained via a push path; (b)
   INCONCLUSIVE when the marker stays queued; (c) FAIL on a broken broker/registration;
   (d) the probe does NOT drain a pre-seeded real inbox message; (e) dashboard renders the
   correct "next step" for not-installed / installed-not-restarted / all-good. Run → FAIL.
2. Implement the command + handlers; extend `check_plugin_installs`. Build
   `dune build --root <wt> -j2`.
3. Tests + full suite `-j2` → PASS. Use temp HOME/broker roots so tracked config isn't
   churned.
4. **Live dogfood in tmux** across ≥2 clients (Claude + one of Codex/OpenCode/Kimi): confirm
   `--verify` reports PASS only after a real restart, INCONCLUSIVE before. Per CLAUDE.md use
   `scripts/c2c_tmux.py` + the swarm scripts — NOT ad-hoc spawns.
5. Update CLI help + docs (`commands.md`, the quickstart from S3) for the new command —
   docs-up-to-date gate (P3 changes help → docs move with it).
6. Commit per sub-feature (dashboard, verify, epilog-unify+install-all-footer, init-fix).

**AC:** `c2c connect` shows a correct dashboard + next-step repo-independently; `--verify`
returns the four-state result honestly, never drains the real inbox, never claims transcript
injection; epilogs end with the canonical verify line; `install all` prints the restart
footer; `init` surfaces identity-init failures; suite green in-worktree; live tmux dogfood
PASS captured; docs updated.

**Final:** `review-and-fix` → PASS; peer cross-review (different model) with
`build-clean-IN-slice-worktree-rc=0` AND the tmux dogfood result in `criteria_checked`.

---

## Push (after all slices PASS)
Cherry-pick/merge each PASSED slice branch to master locally; run `just bi` (build+install)
+ `bundle exec jekyll build`; `c2c doctor` for push verdict; ONE `git push origin master`
(Railway + Pages build). Then `./scripts/relay-smoke-test.sh` (relay.ml unchanged, so relay
behavior identical — Pages is the live-facing change). Features A/B/C land AFTER this push.

## Self-review (writing-plans)
- Spec coverage: P1 (S1+S2), P2 (S3), P3 (S4), P4 deferred — all spec sections mapped. ✓
- No placeholders: file:line targets + ACs concrete; OCaml slices are test-first. ✓
- Consistency: the `c2c connect --verify` name + four-state output used identically across
  S3 docs and S4 impl. ✓
