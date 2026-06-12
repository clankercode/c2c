# Plan Review — Feature C: Embed Client Plugins

**Reviewer:** glm-5.1 · **Date:** 2026-06-12
**Plan reviewed:** `.collab/design/2026-06-12-feat-embed-plugins-plan.md`
**Verdict: SOUND-WITH-FIXES**

---

## 1. EVIDENCE CHECK — Anchor Verification

### Confirmed correct

| Anchor | Claim | Verified | Notes |
|---|---|---|---|
| `justfile:64-81` codegen-role-designer | Quoted-string embed precedent | YES | Lines 64-81; `{role_designer_src\|...\|role_designer_src}` pattern with collision check via `grep -Fq` |
| `justfile:88-131` codegen-role-templates | Multi-file embed precedent | YES | Lines 88-131; iterates `.md.tmpl` files, per-file collision check, same `{delim\|...\|delim}` idiom |
| `role_designer_embedded.ml` | Existing committed artifact | YES | `ocaml/cli/role_designer_embedded.ml` — 6.6KB, auto-generated header + `let content = {role_designer_src\|...` |
| `role_templates.ml` | Existing committed artifact | YES | `ocaml/cli/role_templates.ml` — listed in dune `(modules)` |
| `ocaml/cli/dune:3` modules list | Where new module goes | YES | Line 3 is the `(modules ...)` stanza of the `(executable (name c2c) ...)` block |
| `c2c_setup.ml:728,760-786` | `setup_opencode` repo-dependent code | YES | `canonical_plugin = "data//opencode-plugin//c2c.ts"` at :728; symlink-vs-copy logic at :760-786; "plugin not found" error at :767-771 |
| `c2c_opencode_plugin_drift.ml:146,187` | Drift checker "run from c2c repo" guidance | YES | Line 146: `"Run: cd /path/to/c2c && just install-all"`; line 187: same |
| `c2c_setup.ml:1653` | `detect_installation` | YES | Returns `(self, clients)` snapshot; no change needed |
| `c2c_setup.ml:1852` | `install_all_subcmd` | YES | Iterates detected clients; delegates to per-client setup; no change needed |
| `c2c.ml:2042` | `check_plugin_installs` opencode hint | YES | `:2042` — "run: c2c install opencode from c2c repo" |

### WRONG / IMPRECISE anchors

| Anchor | Issue | Correct location |
|---|---|---|
| `c2c_start.ml:4634-4652` (plan Slice C2) | **Wrong directory.** The plan says `ocaml/cli/c2c_start.ml` but the file is at `ocaml/c2c_start.ml` (the test dune confirms `ocaml/test/dune:52`). The `ocaml/cli/` directory has NO `c2c_start.ml`. | **`ocaml/c2c_start.ml:4634-4652`** |
| `c2c_start.ml ~4634-4652` | Minor: the actual copy site spans `:4629-4652` (starts at `(* Write the canonical plugin...` comment at :4629). Using :4634 as the start skips the comment + `plugin_src` binding. | Use **`:4629-4652`** or at minimum note the broader context |

**Severity: LOW** — the wrong path doesn't affect the plan's logic (both paths exist in the worktree), but an implementer could waste time looking in `ocaml/cli/` first.

---

## 2. CODEGEN FEASIBILITY — 95KB TS in `{ident|...|ident}`

### Safe. No collision risk detected.

- **Delimiter `c2c_ts_src`**: zero occurrences of the string `c2c_ts_src` in `data/opencode-plugin/c2c.ts` (verified via `rg`).
- **Closing `|}`**: zero occurrences of `|}` in the TS file (verified via `rg -F '|}'`). This is the critical one — OCaml's quoted-string syntax terminates on `|<ident>}` and any `|}` in the content would be a hard break.
- **Backslashes**: 19 lines contain `\` (regex escapes, template literals). OCaml `{ident|...|ident}` treats backslashes as *literal characters* — no escaping needed. This is the whole point of the quoted-string syntax. Safe.
- **Non-ASCII**: 94 lines contain Unicode (comments with dashes, URLs). UTF-8 is fine — OCaml quoted strings are byte-transparent.
- **Collision-check pattern reuse**: The `codegen-role-designer` recipe (`justfile:69`) uses `grep -Fq '|role_designer_src}' "$src"` — exact substring match for the closing delimiter. The plan's proposed `c2c_ts_src` delimiter with the same `grep -Fq '|c2c_ts_src}' "$src"` guard is sound. I verified `|c2c_ts_src}` does not appear in the TS source.

### Size concern — NONE at 95KB

The `role_designer_embedded.ml` precedent is 6.6KB. OCaml has no hard limit on string literal size (the compiler handles multi-MB strings). Dune compiles it fine. Binary-size growth is ~95KB raw — the AC sanity-check at line 76 is correct.

### Escaping summary

| Content feature | OCaml quoted-string behavior | Risk |
|---|---|---|
| `\b`, `\n`, `\\`, `\`` | Literal bytes — no interpretation | None |
| `\|}` (pipe-close-brace) | Literal — only `\|<ident>}` is a terminator | None (ident doesn't match) |
| Unicode UTF-8 | Byte-transparent | None |
| Null bytes | OCaml strings allow `\x00` | None (TS file has none) |

---

## 3. DEV-FALLBACK COHERENCE

### The precedence question: which source wins?

The plan says (lines 9-10, 42-44):
> "embedded blob is canonical for binary-only installs; in a dev checkout the repo `data/` file is preferred"

And Slice C2 (lines 41-45):
> "Keep the repo-symlink path as a fallback ONLY when running from a dev checkout (canonical `data/` file present)"

**Assessment: The plan has the correct precedence (dev/repo FIRST, embedded as fallback), but the detection signal is subtly fragile.**

The current `setup_opencode` code (`c2c_setup.ml:760`) checks:
```ocaml
let canonical_exists = Sys.file_exists canonical_plugin && file_size canonical_plugin >= 1024 in
```

This is the "am I in a dev checkout?" signal: does `data/opencode-plugin/c2c.ts` exist and is it ≥1KB?

**Risk: STALE EMBEDDED BLOB in dev workflow.** If the dev edits `data/opencode-plugin/c2c.ts` but forgets to re-run `just codegen-opencode-plugin`, the dev checkout will correctly use the live `data/` file (symlink tracks edits). BUT — the committed `c2c_opencode_plugin_embedded.ml` is now stale. The C3 byte-equality test catches this in CI. This is exactly the right trade-off: dev workflow is never disrupted (live file always wins), and CI gates drift.

**Recommended precedence (matches the plan's intent):**
1. If `data/opencode-plugin/c2c.ts` exists and is ≥1KB → symlink (dev checkout, tracks edits)
2. Else → write `C2c_opencode_plugin_embedded.content` to destination (binary-only install)

**One gap in the plan:** the `c2c start opencode` copy site (`ocaml/c2c_start.ml:4637`) currently only writes when `Sys.file_exists plugin_src` (the repo file). The plan says "write embedded content if the repo file is absent" but the plan should also specify: **always overwrite from embedded when the repo file is absent, so a binary-only `c2c start opencode` self-heals**. The current code silently no-ops when the repo file is missing (`if Sys.file_exists plugin_src then begin ... end` at :4637-4652 wraps the entire write in a conditional). The fix is to add an `else` branch that writes from `C2c_opencode_plugin_embedded.content`.

**Verdict on dev-fallback: SOUND.** The plan's intent is correct. Add explicit instruction for the `else` branch in c2c_start.ml.

---

## 4. SYNC-GATE SOUNDNESS

### Will the byte-equality test fail when stale? YES — anti-false-green is strong.

The plan's Slice C3 (lines 52-55) proposes a test asserting `C2c_opencode_plugin_embedded.content` equals `data/opencode-plugin/c2c.ts` byte-for-byte.

**Why this works:**
- `data/opencode-plugin/c2c.ts` is tracked in git. If someone edits it, the file changes on disk immediately.
- `c2c_opencode_plugin_embedded.ml` is a committed codegen artifact. It only changes when `just codegen-opencode-plugin` is re-run.
- The byte-equality test reads both at test runtime (from the worktree). If the TS file was edited without regenerating the `.ml`, the test fails. This is the same pattern used by `test_role_templates` (which tests the `role_templates.ml` codegen artifact).

**Is "regenerating committed .ml in CI vs asserting-equality" the right call?** YES. The plan's approach (assert equality, not regenerate-in-CI) is correct because:
1. The codegen recipe runs locally before commit. The committed `.ml` IS the artifact.
2. CI asserting equality catches the case where someone edits the TS but forgets the codegen step.
3. CI regenerating would hide the staleness (it would always pass) and create a dirty working tree in CI, which is worse.
4. The AC at line 82 explicitly calls for anti-false-green verification: "confirm the byte-equality sync test actually fails when the embedded blob is stale."

**One subtlety:** the test must read `data/opencode-plugin/c2c.ts` relative to the *worktree root*, not the test binary's CWD (dune runs tests from `_build/default/ocaml/cli/`). The existing `test_c2c_opencode_plugin_drift.ml` tests work with fixture paths, so the new test should either:
- Use `Sys.getcwd () // ".." // ".." // "data" // "opencode-plugin" // "c2c.ts"` (fragile to dune layout changes), or
- Accept the path as a test parameter / env var, or
- Use the same path resolution that `c2c_opencode_plugin_drift.ml` uses for its canonical path.

The plan doesn't specify this detail. **Recommendation:** mirror whatever path resolution `c2c_opencode_plugin_drift.ml` uses for its canonical file (currently `Filename.concat (Sys.getcwd ()) canonical` where `canonical = "data/opencode-plugin/c2c.ts"`).

---

## 5. GAPS

### Gap 1: Build-dep wiring incomplete — `codegen-opencode-plugin` not in `just build` chain yet

**Severity: MEDIUM (implementation detail, not plan logic)**

The plan's Slice C1 (line 37) says: "Wire `codegen-opencode-plugin` into the `just build` / `just install*` dep chain (`justfile:140` and siblings)."

Currently (`justfile:140`):
```
build: codegen-role-designer
```

The plan must add `codegen-opencode-plugin` as a dep to ALL of:
- `build:` (line 140) — `build: codegen-role-designer codegen-opencode-plugin`
- `build-cli:` (line 145) — same
- `build-server:` (line 150) — technically not needed (server doesn't use the plugin), but for consistency
- `install-all:` (line 309) — `install-all: codegen-role-designer install-git-hooks` → add `codegen-opencode-plugin`

The plan mentions this but doesn't enumerate the four recipes. An implementer might miss `build-server` or `install-all`. **Fix:** enumerate all four in the plan.

### Gap 2: `c2c_opencode_plugin_embedded` not listed in drift test's `(modules)`

**Severity: LOW**

The plan proposes extending `test_c2c_opencode_plugin_drift.ml` or adding `test_c2c_opencode_plugin_embedded.ml`. If a new test file is added, it needs its own `(test ...)` stanza in `ocaml/cli/dune` with `(modules test_c2c_opencode_plugin_embedded c2c_opencode_plugin_embedded)`. The plan doesn't specify the dune wiring for the new test. Not a logic gap, but the implementer needs to know.

### Gap 3: Binary-size impact on `c2c_deliver_inbox.exe` — is the embedded module linked into it?

**Severity: LOW**

`c2c_deliver_inbox.exe` has its own `(executable ...)` stanza in `ocaml/cli/dune:7-11` with a minimal `(modules ...)` list. Since `c2c_opencode_plugin_embedded` is only added to the main `c2c` executable's modules (line 3), the deliver-inbox binary is unaffected. **No action needed** — just noting this for the "binary-size growth is ~95KB" AC: that's the `c2c` binary only, which is correct.

### Gap 4: `c2c.ml:2042` hint says "run from c2c repo" — plan mentions updating it but C3 says "VERIFY (no code)" for detection flow

**Severity: LOW (plan already covers this in C3 line 59)**

The plan says "Update `check_plugin_installs` opencode hint (`c2c.ml:2042`) accordingly" — this is correct and explicit. No gap, just confirming the hint at `:2042` ("run: c2c install opencode from c2c repo") must change to something like "run: c2c install opencode" (dropping the "from c2c repo" qualifier since it now works binary-only).

### Gap 5: Fresh-checkout build — codegen reads `data/opencode-plugin/c2c.ts` which IS in git

**Severity: NONE (not actually a gap)**

On a fresh clone, `data/opencode-plugin/c2c.ts` exists (it's committed). The codegen recipe reads it and produces `c2c_opencode_plugin_embedded.ml`. The committed `.ml` is also in git. So on a fresh checkout, `just build` works even WITHOUT running the codegen (the committed `.ml` is already there). The codegen dep just ensures it's regenerated if the TS changes. This is the same as the role-designer precedent. No gap.

### Gap 6: `install_all` still delegates to `setup_opencode` which the plan modifies — binary-free after C2?

**Severity: NONE**

After C2, `setup_opencode` writes `C2c_opencode_plugin_embedded.content` when the repo file is absent. `install_all` (`c2c_setup.ml:1852`) calls `setup_opencode` which will now work without a repo. The detection flow (`detect_installation`) checks if the binary is on PATH and if client configs exist — no repo dependency. **Confirmed: `c2c install all` becomes repo-free after C2.**

---

## Top 5 Concrete Improvements

1. **Fix `c2c_start.ml` path.** Plan says `c2c_start.ml:4634-4652` implicitly suggesting `ocaml/cli/c2c_start.ml`. Correct path is **`ocaml/c2c_start.ml:4629-4652`**. Update all references in the plan.

2. **Enumerate ALL justfile recipes needing the new dep.** The plan says "Wire... into `just build` / `just install*` dep chain (`justfile:140` and siblings)" but should explicitly list: `build:` (L140), `build-cli:` (L145), `build-server:` (L150, optional but consistent), `install-all:` (L309). Missing one = broken build for that recipe.

3. **Specify the `else` branch for `c2c start opencode` copy site.** Current code at `ocaml/c2c_start.ml:4637` wraps the entire plugin write in `if Sys.file_exists plugin_src then begin ... end` with no `else`. The plan says "write embedded content if the repo file is absent" but doesn't call out that this requires adding an explicit `else` branch. Add: "Add `else` branch that writes `C2c_opencode_plugin_embedded.content` to `plugin_dst` when `plugin_src` is absent."

4. **Specify path resolution for the byte-equality test.** The C3 sync-gate test reads `data/opencode-plugin/c2c.ts` from the worktree at test runtime. Dune runs tests from `_build/default/ocaml/cli/`. The plan should note that the test needs to navigate to the worktree root (e.g., `Filename.concat (Sys.getcwd ()) ".." // ".." // "data" // "opencode-plugin" // "c2c.ts"`) or accept the path via env/fixture, mirroring how `c2c_opencode_plugin_drift.ml` resolves its canonical path.

5. **Add the new test's dune stanza to the plan.** If `test_c2c_opencode_plugin_embedded.ml` is a new file (recommended over extending the existing drift test, for separation of concerns), the plan should include the dune `(test ...)` stanza with `(modules test_c2c_opencode_plugin_embedded c2c_opencode_plugin_embedded)` and `(libraries c2c_mcp alcotest ...)` so the implementer doesn't have to derive it.

---

## Summary

The plan is **SOUND in its core logic**: the embed idiom is well-established in this codebase (two working precedents), the 95KB TS file is safe for `{ident|...|ident}` embedding (zero delimiter collisions, no escaping issues), the hybrid drift strategy (dev-repo-first + embedded-fallback + CI byte-equality gate) is the right design, and `c2c install all` genuinely becomes repo-independent after C2.

The fixes are all at the **specificity** level — wrong path, missing enumeration of build targets, implicit `else` branch — not at the architectural level. No rework needed.
