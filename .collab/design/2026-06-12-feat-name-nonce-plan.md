# Implementation Plan — Feature B: Name Hardening (blocklist) + Nonce Suffix

**Worktree:** `.worktrees/wt-feat-name-nonce` · **Branch:** `feat/name-nonce`
**Base:** `origin/master` @ 8c2f5f51 · **Verdict:** PRACTICAL-WITH-CAVEATS
**Source research:** `.collab/research/2026-06-12-three-feature-investigations.md` §B

## Decisions locked by Max
- **Nonce policy: AUTO-GEN NAMES ONLY.** Append the nonce suffix ONLY to auto-generated
  pool names. Leave explicit `--alias`, role `c2c.alias`, and env-supplied names BARE. This
  avoids breaking `--from <alias>` sends, supervisor matches, and scheduled self-DMs. This
  collapses the high-blast-radius risk.
- **`--no-nonce`** disables the nonce even for auto-generated names.
- **Blocklist match = word-or-first-hyphen-segment** (casefolded), USER-SUPPLIED names only:
  reject if the alias equals a banned word OR its first `-`-segment is a banned word. Blocks
  `claude`, `claude-code`, `gpt`, `gemini`, `codex`, `codex-code`; allows `lyra-quill`,
  `stardust-vale`. (codex final-pass: NOT `claude-quill` — its first segment `claude` is
  banned, so a user-supplied `claude-quill` is correctly REJECTED. Auto-gen client-prefixed
  names like `codex-ember-frost` pass via the `from_auto_gen` origin path — see B1.)
- **Nonce charset = lowercase-only `0-9a-z`** (aliases are casefold-compared, so mixed-case
  would create surprising case-collisions). Length 4 ⇒ 36^4 ≈ 1.68M.
- **Nonce STACKS with `-<prime>`** collision disambiguation (does not replace it).
- **Bonus:** fold the missing `is_valid` format check into the broker chokepoint so CLI
  paths get it too.

## Slices
### Slice B1 — Blocklist at the chokepoint (USER-SUPPLIED names only)
> **REWORKED per mm3 review (was NEEDS-REWORK):**
> - **CRITICAL conflict resolved:** the blocklist must apply ONLY to user-supplied names.
>   Auto-generated names are client-PREFIXED (`default_alias_for_client` → `codex-ember-frost`),
>   so a first-hyphen-segment match on `codex` (a supported client) would reject EVERY default
>   `c2c setup`. Fix: thread `?from_auto_gen:bool` (default `false`) through `Broker.register`;
>   when `true`, SKIP the blocklist (auto-gen names are trusted — we generated them). This also
>   dovetails with nonce-auto-gen-only.
> - **No module cycle** (mm3 disproved): `c2c_broker` referencing `C2c_start.supported_clients`
>   is a one-way dep; both live in the same `c2c_mcp` library (`wrapped: false`, single
>   compilation unit). No hoist needed. (If you want policy decoupling, a NEW `c2c_blocklist.ml`
>   is the right home — NOT `c2c_name.ml`, which is a format validator, not a policy table.)
- `ocaml/c2c_broker.ml:1681-1687`: add `banned_aliases` (static set: `gpt`, `assistant`,
  plus `C2c_start.supported_clients` — claude, codex, opencode, kimi — plus `gemini`, `crush`)
  + predicate `is_banned_alias` that casefolds and checks full-equality OR first-hyphen-segment
  equality.
- `Broker.register` (`c2c_broker.ml:1872`): add `?(from_auto_gen=false)`; enforce
  `is_banned_alias` ONLY when `not from_auto_gen`, right after `is_reserved_system_alias`. ALSO
  fold `C2c_name.is_valid` (`c2c_name.ml:8`) here so all paths validate FORMAT (format check
  applies to everyone, including auto-gen). Rejection raises `invalid_arg` (existing pattern) —
  MCP friendly error below.
- Auto-gen call sites pass `~from_auto_gen:true` when they register a generated name; explicit/
  role/env paths pass nothing (default false → blocklist enforced).
- **Signature scope (codex):** adding `?from_auto_gen` to `Broker.register` requires updating
  the EXPOSED signature in `ocaml/c2c_mcp.mli:294`, not only `c2c_broker.ml:1871`.
- Mirror a pre-check + friendly `tool_err` in the MCP handler
  (`c2c_identity_handlers.ml:45-50`) so a user-supplied banned alias returns an error result,
  not an exception.

> **BLOCKER B-origin (codex final-pass) — `from_auto_gen` is LOST across the env boundary.**
> The common install/start path does NOT register in-process: `c2c install/setup` auto-picks
> the alias (`c2c_setup.ml:1522-1528`) and writes it to MCP config as
> `C2C_MCP_AUTO_REGISTER_ALIAS` (`c2c_setup.ml:467,581,1051,1384`); `c2c start` writes the
> effective alias to the child env (`c2c_start.ml:2942-2949`, kimi `:3101-3122`). The
> server-side auto-register (`c2c_mcp_helpers_post_broker.ml:816-819`) + the MCP handler
> (`c2c_identity_handlers.ml:14-23`) read ONLY that string and call `Broker.register` with NO
> origin flag (`post_broker:979`, `handlers:283-286`). So a generated `codex-ember-frost-a7c2`
> arrives looking exactly like a user-supplied alias → the default `from_auto_gen=false` path
> BLOCKS it on first segment `codex`. **This re-introduces the original critical bug across the
> config/env boundary.** REQUIRED design — propagate origin via a sibling env marker:
> - When `do_install_client` / `c2c start` AUTO-PICK the alias (not `--alias`/`--name`/role/
>   user-env), write `C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN=1` alongside
>   `C2C_MCP_AUTO_REGISTER_ALIAS`. Do NOT write it when the alias was explicitly supplied.
> - Teach `auto_register_startup` (`c2c_mcp_helpers_post_broker.ml:816-819,979`) and the MCP
>   register handler (`c2c_identity_handlers.ml:14-23,283-286`) to pass `~from_auto_gen:true`
>   ONLY when that marker is present (and unset/false otherwise).
> - Tests (both sides): generated config/start aliases register fine; user-provided
>   env/explicit `codex` / `codex-code` still rejected.
> Note: the env marker ALSO governs whether the nonce was already applied — the alias written
> to `C2C_MCP_AUTO_REGISTER_ALIAS` by install/start is the FINAL name (nonce already appended
> at generation time), so the register path must NOT re-nonce; it only needs the origin flag
> to skip the blocklist.

### Slice B2 — Nonce generator + auto-gen-only application
- New `ocaml/c2c_nonce.ml`: `gen_nonce () = String.init 4 (fun _ -> charset.[Random.int 36])`
  with `charset = "0123456789abcdefghijklmnopqrstuvwxyz"`. **Defensively `Random.self_init ()`
  inside the module init** (mm3: `c2c_setup.ml:186 generate_alias` does NOT seed — the comment
  at `:182-184` referencing a `setup_register` caller is STALE; no such function exists, so an
  unseeded path would yield a deterministic/predictable nonce). Mirror `c2c_start.ml:2467`.
- Apply the nonce ONLY inside the auto-generate functions, AFTER a bare name is produced,
  BEFORE it's used/registered. **Complete call-site list (mm3 added the last two groups):**
  - `ocaml/c2c_start.ml:2466` `generate_alias` / `:2477` `default_name`
  - `ocaml/cli/c2c_setup.ml:186` `generate_alias` / `:199` `generate_alias_easy` /
    `:246` `default_alias_for_client`
  - `ocaml/cli/c2c_agent.ml:458, 733` (ephemeral instance-name generation)
  - `ocaml/cli/c2c.ml:6763-6766` (init's three-way auto-pick reject-loop)
  Do NOT touch the user-supplied/role/env resolution paths — those stay bare.

> **BLOCKER B-require-easy (codex final-pass) — nonce breaks `c2c init --require-easy`.**
> The `--require-easy` validator at `c2c.ml:6768-6776` splits the generated alias on `-` and
> accepts ONLY exactly two segments:
> ```ocaml
> let w1, w2 = match String.split_on_char '-' a with [w1; w2] -> (w1,w2) | _ -> ("","") in
> ```
> If `generate_alias_easy` returns `word-word-nn4x` (3 segments), the match falls to `("","")`,
> fails the easy-pool check, and **recurses forever**. REQUIRED fix (pick one, implement +
> test): (a) validate the BARE two-word easy name against the pool FIRST, then append the nonce
> AFTER it passes; OR (b) make the parser accept `[w1; w2; _nonce]` and validate only `w1`/`w2`.
> **(a) is cleaner** (keeps nonce orthogonal to validation). Add a regression test:
> `c2c init --require-easy` with nonce enabled terminates and yields `word-word-<nonce>`.
- `--no-nonce` plumbing (CLI ONLY): add the flag to the auto-gen-bearing commands
  (`c2c.ml:6682` init, `:8977` start, `c2c_setup.ml:1785` setup/install) and thread it into
  the generate calls. **DO NOT add a `no_nonce` MCP arg** (mm3: the MCP `register` handler
  `c2c_identity_handlers.ml:14-23` never pool-generates — it reads an explicit alias or the
  `C2C_MCP_AUTO_REGISTER_ALIAS` env var, both of which are bare per the env-supplied=bare
  decision; an MCP `no_nonce` arg would be dead code).

### Slice B3 — Output shows full nonce'd name + collision reconciliation
- Verify every auto-pick notice + epilog prints the POST-nonce value:
  `c2c.ml:6779` (init auto-pick eprintf), `c2c_setup.ml:1527` (install auto-pick),
  `c2c.ml:9152` (start name), register/init epilogs `c2c.ml:2914,6934`, setup `:441,526`.
- Reconcile with `suggest_alias_prime` (`c2c_broker.ml:1843`): nonce stacks — on a (now
  rare) collision the prime suffix appends after the nonce (`word-word-a7c2-2`). Confirm
  the casefold-eviction (`c2c_broker.ml:1886`) still compares full stored aliases (it does).

### Slice B4 — Tests + docs (the "full scan")
- Update exact-equality tests broken by nonce — but since nonce is auto-gen-only, tests that
  register with EXPLICIT aliases are unaffected. Audit `test_c2c_mcp.ml`,
  `test_c2c_identity_handlers.ml` for tests relying on AUTO-generated names; gate nonce off
  via env in fixtures if needed, or assert the prefix + nonce shape.
- Add tests: (a) blocklist rejects user-supplied `claude`/`claude-code`/`gpt`, accepts
  `lyra-quill`; (b) MCP register returns friendly error (not exception) for a user-supplied
  banned name; (c) auto-gen produces `<word>-<word>-<4 lowercase alnum>`; (d) `--no-nonce`
  yields bare auto name; (e) explicit `--alias foo` is NOT nonce'd; (f) nonce charset is
  lowercase-only; **(g) auto-gen client-PREFIXED name (e.g. `codex-ember-frost`) is NOT
  rejected by the blocklist** (the critical regression — `from_auto_gen=true` path); **(h)
  user-supplied `codex` / `codex-code` IS rejected**.
- Docs: pool/format invariant lives in **TWO distinct places** (mm3: `AGENTS.md` is a SYMLINK
  to `CLAUDE.md`, so they're one file at `:268`; `docs/commands.md:994` is a SEPARATE
  user-facing paragraph). Update `CLAUDE.md:268` (architecture note) AND `docs/commands.md:994`
  (user-facing format) with appropriate (different) content describing blocklist + nonce;
  register/init examples; role-template notes.
- Blocker regression tests (codex final-pass): **(i)** an alias arriving via
  `C2C_MCP_AUTO_REGISTER_ALIAS` WITH `C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN=1` registers
  even with a client-prefixed first segment (`codex-…`), while the SAME alias WITHOUT the
  marker is rejected; **(j)** `c2c init --require-easy` with nonce enabled TERMINATES and
  yields `word-word-<4 lowercase>`.

## Acceptance criteria
- `dune build` clean IN WORKTREE (rc=0); full suite green `-j2`.
- **`c2c setup <client>` / `c2c install` default (auto-gen) flows STILL SUCCEED** — auto-gen
  client-prefixed names (`codex-…`, `kimi-…`) are NOT rejected by the blocklist (the mm3
  critical regression). Verified by test (g).
- User-supplied banned names rejected on BOTH MCP + CLI with a friendly MCP error (not an
  exception).
- Auto-gen names carry a lowercase 4-char nonce; explicit/role/env names do NOT.
- `--no-nonce` (CLI) works. NO MCP `no_nonce` arg (would be dead code).
- Output everywhere shows the full registered name incl nonce.
- Docs updated (docs-up-to-date gate); pool/format invariant consistent across all 3 copies.

## Final step — REVIEW-AND-FIX LOOP (required)
Run `review-and-fix` on each slice SHA until PASS (fixes in NEW commits, never `--amend`).
Then peer cross-review by a DIFFERENT ccc model with the build-clean verdict produced INSIDE
this worktree (`build-clean-IN-slice-worktree-rc=0` in `criteria_checked`). Pay special
attention to the module-cycle risk (B1) and the auto-gen-vs-explicit boundary (B2) — a
verifier should confirm explicit/role/env aliases are never nonce'd. Do NOT push — lands
after connect-docs; coordinator/Max gate.
