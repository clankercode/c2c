# Implementation Plan — Feature C: Embed Client Plugins (repo-independent install)

**Worktree:** `.worktrees/wt-feat-embed-plugins` · **Branch:** `feat/embed-plugins`
**Base:** `origin/master` @ 8c2f5f51 · **Verdict:** PRACTICAL (mostly built)
**Source research:** `.collab/research/2026-06-12-three-feature-investigations.md` §C

## Decisions locked by Max
- **Hybrid drift strategy:** codegen + CI-test sync gate (A), repo-symlink kept as the dev
  fallback (B). Embedded blob is canonical for binary-only installs; in a dev checkout the
  repo `data/` file is preferred so the symlink-tracks-edits workflow is preserved.
- **Defer git-shim embedding** — it's only a non-fatal warning today; keep this slice focused
  on the opencode plugin (the one real repo-dependency that breaks binary-only install).

## Background (verified)
- 4/5 clients already embed all scripts/config inline (claude/codex/kimi/gemini). Only
  **opencode** reads `data/opencode-plugin/c2c.ts` (95 KB) from the working tree:
  `setup_opencode` (`c2c_setup.ml:728,760-786`) + `c2c start opencode` copy
  (`c2c_start.ml:4634-4652`).
- Embed idiom: `just` codegen recipe → committed `.ml` with `{ident|...|ident}` string,
  listed in dune `(modules)`. Precedents: `role_designer_embedded.ml`
  (`justfile:64-81`), `role_templates.ml` (`justfile:88-131`).
- The TS plugin is runtime-self-contained (type-only imports + Node built-ins; no
  node_modules needed at runtime). `.opencode/plugins/c2c.ts` is byte-identical to the
  `data/` canonical.
- Drift checker `c2c_opencode_plugin_drift.ml` treats `data/` as canonical vs the deployed
  file — its semantics + "run from c2c repo" guidance (`:146,187`) need updating.

## Slices
### Slice C1 — Codegen recipe + embedded module
- Add `just codegen-opencode-plugin` to `justfile` (mirror `codegen-role-designer`,
  `justfile:64-81`): read `data/opencode-plugin/c2c.ts`, choose a quoted-string delimiter
  that does NOT collide with the file content (the role-designer recipe has the
  collision-check pattern — reuse it), emit
  `ocaml/cli/c2c_opencode_plugin_embedded.ml` = `let content = {c2c_ts_src|...|c2c_ts_src}`.
- Add `c2c_opencode_plugin_embedded` to `ocaml/cli/dune:3` `(modules ...)`.
- Wire `codegen-opencode-plugin` as a dep into ALL FOUR relevant recipes (glm51 review):
  `build:`, `build-cli:`, `build-server:`, `install-all:` so it regenerates before compile
  on any path.
- Run the recipe; COMMIT the generated `.ml` (it's a committed artifact like the precedents).

### Slice C2 — Refactor install + start to prefer embedded
- `setup_opencode` (`c2c_setup.ml:760-786`): write
  `C2c_opencode_plugin_embedded.content` to the plugin destination by default. Keep the
  repo-symlink path as a fallback ONLY when running from a dev checkout (canonical `data/`
  file present) — preserves the dev "symlink tracks edits" workflow. Remove the hard
  "plugin not found — run from c2c repo" failure (`:767-771`) since embedded content is
  always available.
- `c2c start opencode` copy site (`ocaml/c2c_start.ml:4629-4652` — NOTE correct path is
  `ocaml/c2c_start.ml`, NOT `ocaml/cli/`; glm51 review): same — write embedded content
  if the repo file is absent. The current code SILENTLY NO-OPS when the repo file is absent
  (the `if` at `ocaml/c2c_start.ml:4637` has no `else`); the fix MUST add an explicit `else`
  branch that writes `C2c_opencode_plugin_embedded.content` so `c2c start opencode` self-heals
  the plugin on a binary-only install.

### Slice C3 — Drift test + checker update + detection no-op verify
- Add a build/CI test asserting `C2c_opencode_plugin_embedded.content` equals
  `data/opencode-plugin/c2c.ts` byte-for-byte (extend `test_c2c_opencode_plugin_drift.ml` or
  add `test_c2c_opencode_plugin_embedded.ml`). This is the sync gate — editing the TS
  without re-running the codegen recipe fails the build.
- Update `c2c_opencode_plugin_drift.ml` (`:146,187`): with embedding, the binary is
  canonical; reword "cd /path/to/c2c && just install-all" guidance to "upgrade your c2c
  binary / re-run `c2c install opencode`".
- Update `check_plugin_installs` opencode hint (`c2c.ml:2042`) accordingly.
- VERIFY (no code) that `c2c install all` (`c2c_setup.ml:1852`) + `detect_installation`
  (`:1653`) now configure opencode binary-only once C2 lands — the detection flow itself
  needs no change.

### Slice C4 — Docs
- Install runbook + AGENTS.md install section: `c2c install all` works binary-only; document
  the codegen-sync requirement (edit `data/opencode-plugin/c2c.ts` ⇒ run
  `just codegen-opencode-plugin` ⇒ commit both).

## Acceptance criteria
- `dune build` clean IN WORKTREE (rc=0); suite green `-j2`; the new byte-equality test passes.
- `just codegen-opencode-plugin` is idempotent (re-running yields no diff).
- `setup_opencode` writes a working plugin with NO repo present (simulate: temp HOME, run the
  install path; assert `.opencode/plugins/c2c.ts` content == embedded). Dev path still
  symlinks when `data/` present.
- Drift checker + hints reworded; docs updated (docs-up-to-date gate).
- Binary-size growth is ~95 KB (sanity-check, not a hard gate).

## Final step — REVIEW-AND-FIX LOOP (required)
Run `review-and-fix` on each slice SHA until PASS (fixes in NEW commits, never `--amend`).
Peer cross-review by a DIFFERENT ccc model with build-clean produced INSIDE this worktree
(`build-clean-IN-slice-worktree-rc=0`). The verifier must confirm the byte-equality sync
test actually fails when the embedded blob is stale (anti-false-green). Do NOT push — lands
after connect-docs; coordinator/Max gate.
