# Three Feature Investigations — connect-metadata / name-hardening+nonce / embed-plugins

**Date:** 2026-06-12 · **Orchestrator:** claude · **Method:** 3 parallel subagents
(2 opus Agent, 1 ccc/glm51). READ-ONLY scoping; no code changed.

Proposed by Max. Each section = verdict + plan + relevant files + decisions.
Source reports archived in `/tmp/c2c-prompts/plugin-embed.out` and the agent transcripts.

---

## Feature A — Metadata on first connect (repo/folder name, default-on, opt-out)

**Verdict: PRACTICAL — mostly already built.**

The broker registration record *already* stores `cwd : string option` (JSON,
forward-compatible — `registration_of_json` ignores unknown fields) and a repo slug
inside `canonical_alias` (`alias#repo@host`). The MCP `register` handler already
captures `Sys.getcwd ()`. **Registrations are broker-local and never traverse the
relay** (zero `cwd`/`canonical_alias` refs in `relay*.ml`) → the cross-machine privacy
concern is moot by default. So the feature reduces to: explicit opt-out surface +
(optional) display in `list`/`whoami`.

### Plan
1. *(decide)* What IS "metadata"? Repo already in `canonical_alias` slug; folder already
   in `cwd`. Recommend reuse, not a redundant `repo` blob (YAGNI).
2. Thread `?(include_metadata=true)` through the register path so `cwd`/`repo` is stored
   only when not suppressed — capture-site gating, not serializer. (`c2c_broker.ml`,
   `c2c_identity_handlers.ml`)
3. MCP schema: add `bool_prop "include_metadata"` to `register` tool (`c2c_mcp.ml:30`).
4. CLI: add `--no-metadata` Cmdliner flag to `register_cmd`; AND pass `~cwd` in the CLI
   `Broker.register` call (currently CLI passes `cwd=None` — see bug below).
   (`cli/c2c.ml:2855`, `:2901`)
5. *(optional)* Display: add field to `list`/`whoami` projections (both omit `cwd` today).
   (`c2c_identity_handlers.ml:372`, `:417`)
6. Docs + tests (fixture-gated suppress path).

### Key files
- Record type + cwd: `c2c_mcp.mli:49-112` (`cwd` `:106-111`, `canonical_alias` `:55`).
- JSON round-trip (forward-compat proof): `c2c_broker.ml:122` (to_json), `:248` (of_json).
- `register` fn (already has `?cwd`): `c2c_broker.ml:1871`; canonical_alias `:1962`.
- Repo-slug derivation: `c2c_broker.ml:1695-1712`; fingerprint `c2c_repo_fp.ml:14-28`.
- MCP register handler (captures cwd): `c2c_identity_handlers.ml:14`, call `:285-287`.
- CLI register (NO cwd, NO flag): `cli/c2c.ml:2855` term, `:2901` call.
- list/whoami (omit cwd): `c2c_identity_handlers.ml:357-409`, `:411-426`.

### Decisions for Max
- **A1 — what's the metadata?** Reuse existing `cwd`+slug (rec) vs add a new `repo` field
  from `git remote get-url origin`.
- **A2 — display to peers?** At-rest only (rec) vs show in `list`/`whoami` (the only part
  that leaks anything).
- **A3 — opt-out scope.** `cwd` feeds the Hardening-B worktree-mismatch guard
  (`c2c_broker.ml:1103-1191`); suppressing `cwd` weakens that guard. Opt-out should
  probably cover only a *separate* `repo` field, NOT `cwd` itself.
- **Bug found (do regardless):** CLI `c2c register` doesn't store `cwd`; MCP does. Close
  the asymmetry or "default-on" is inconsistent across entry points.

---

## Feature B — Name hardening (blocklist) + nonce suffix

**Verdict: PRACTICAL-WITH-CAVEATS.** Sub-features split on risk:

- **Blocklist → PRACTICAL.** `Broker.register` (`c2c_broker.ml:1871`) is the *single
  chokepoint* every CLI path + the MCP handler funnel through, and it already rejects
  reserved aliases (`is_reserved_system_alias`, `:1683`, list `:1681`). Extend that one
  predicate. Recommended match: reject if casefolded alias **== a banned word OR its
  first hyphen-segment is one** → blocks `claude`/`claude-code`, allows `lyra-quill`.
- **`--no-nonce` + full-name output → PRACTICAL.** Output sites already echo the stored
  alias verbatim (alias stored as-given, only comparisons casefolded), so a suffix
  round-trips for free.
- **Nonce-BY-DEFAULT → the dangerous one.** NO single chokepoint (must apply before
  `register`, across 4+ name-resolution paths). Defaulting onto *every* registration:
  (i) collides with the existing `-<prime>` collision scheme (`suggest_alias_prime`,
  `c2c_broker.ml:1843`); (ii) breaks ~20 exact-equality tests; (iii) **breaks role/env
  -pinned identities** — `lyra-quill` → `lyra-quill-A7c2` breaks every `--from lyra-quill`
  send, supervisor matches, scheduled self-DMs.

### Plan
1. Extend blocklist primitive `c2c_broker.ml:1681-1687` (banned set, casefold compare;
   reuse `C2c_start.supported_clients` `c2c_start.ml:1578` + static `gpt/assistant/...`).
2. Wire into the chokepoint `Broker.register` `:1872`; mirror to MCP handler friendly
   error (`c2c_identity_handlers.ml:45-50`) so MCP returns `tool_err` not an exception.
3. Nonce generator mirroring `uuid_v4` (`c2c.ml:9849`): `String.init 4 (fun _ ->
   charset.[Random.int N])`. **Recommend lowercase-only charset** (`0-9a-z`) — aliases
   are casefold-compared so `-A7c2`==`-a7c2` would collide.
4. **Decide nonce policy** (the big one) — apply after resolution, before `register`.
   Recommend: nonce ONLY auto-generated names, leave explicit `--alias`/role/env bare; OR
   make nonce opt-IN (`--nonce`) not opt-out.
5. Thread `--no-nonce` through Cmdliner (`c2c.ml:2857,6682,8977`, `c2c_setup.ml:1785`) +
   `no_nonce` MCP arg (`c2c_mcp.ml:30-38`).
6. Reconcile with `suggest_alias_prime` (stack vs replace); update `test_c2c_mcp.ml:2171`.
7. Update output/auto-pick sites to show post-nonce value
   (`c2c.ml:2914,6934,6779,9152`, `c2c_setup.ml:441,526,1527`).
8. Fix ~30 tests (exact-equality + suffix-format) — see report for the full list.
9. Doc sweep: pool/format invariant (`CLAUDE.md:268`==`AGENTS.md:268`==
   `docs/commands.md:994`) + register/init examples + role templates.

### Decisions for Max
- **B1 — nonce default policy:** nonce only auto-gen names (rec) / opt-in `--nonce` /
  opt-out-default-on-for-all (largest blast radius — forces every equality lookup
  nonce-tolerant).
- **B2 — blocklist match semantics:** word-or-first-segment (rec) vs exact vs substring.
- **B3 — nonce charset:** lowercase-only `0-9a-z` (rec, avoids casefold collision) vs
  mixed-case.
- **B4 — nonce vs `-<prime>`:** stack or replace the collision suffixer?
- **B5 — bonus:** CLI paths skip `is_valid` today (only MCP validates) — fold the format
  check into `Broker.register` alongside the blocklist while there?

---

## Feature C — Embed client plugins so `c2c install` is repo-independent

**Verdict: PRACTICAL — mostly already built.**

Detection-driven install already exists: `c2c install all` (`c2c_setup.ml:1852`) +
`detect_installation` (`:1653`). **4 of 5 clients are already fully embedded**
(claude/codex/kimi/gemini — inline OCaml strings; kimi's hook header even says "verbatim
into the c2c binary so installation is self-contained"). **Only opencode is
repo-dependent:** `setup_opencode` (`c2c_setup.ml:728,760-786`) symlinks/copies
`data/opencode-plugin/c2c.ts` (95 KB). Secondary minor: the git pre-reset guard
(`c2c_start.ml:1878-1892`) reads `<repo>/git-shim.sh` (non-fatal warning today).

**Embed mechanism (no ocaml-crunch):** `just` codegen recipes (`justfile:64-131`) wrap
file content in OCaml `{ident|...|ident}` strings → committed `.ml` listed in dune
`(modules)`. Precedents: `role_designer_embedded.ml`, `role_templates.ml`. The opencode
`c2c.ts` is runtime-self-contained (type-only imports + Node built-ins, no node_modules).
Binary grows ~111 KB (opencode + git-shim) vs 24 MB base (~0.5%).

### Plan
1. `just codegen-opencode-plugin` → `ocaml/cli/c2c_opencode_plugin_embedded.ml`; add to
   `dune:3` modules + `just build` deps.
2. *(optional)* `just codegen-git-shim` → `c2c_git_shim_embedded.ml`.
3. Refactor `setup_opencode` (`c2c_setup.ml:760-786`) + `c2c start opencode` copy site
   (`c2c_start.ml:4634-4652`): prefer embedded blob, fall back to repo-symlink only in a
   dev checkout.
4. Refactor `install_pre_reset_shim` (`c2c_start.ml:1878-1892`): write embedded content
   when repo file absent instead of `failwith`.
5. Detection flow = no-op (already there).
6. CI test asserting embedded == `data/opencode-plugin/c2c.ts` byte-for-byte; update
   `c2c_opencode_plugin_drift.ml` (`:146,187`) "run from c2c repo" guidance.
7. Docs: `c2c install all` now works binary-only.

### Decisions for Max
- **C1 — drift strategy:** codegen + CI-test sync gate (A) with repo-symlink dev fallback
  (B) — recommend the hybrid.
- **C2 — git-shim embed:** in-scope (step 2) or defer (it's only a non-fatal warning today)?

---

## Cross-cutting note
All three are **net-additive, low-architectural-risk**, and two (A, C) are largely
already implemented — the work is opt-out plumbing + one embed recipe. Feature B's only
real risk is the nonce-default policy; pick "nonce auto-gen names only" and it collapses
to low-risk too. None of these block or depend on the connect-docs work; they could ride
the same flagship push or go separately.
