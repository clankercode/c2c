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
- **Blocklist match = word-or-first-hyphen-segment** (casefolded): reject if the alias
  equals a banned word OR its first `-`-segment is a banned word. Blocks `claude`,
  `claude-code`, `gpt`, `gemini`, `codex`, etc.; allows `lyra-quill`, `claude-quill`.
- **Nonce charset = lowercase-only `0-9a-z`** (aliases are casefold-compared, so mixed-case
  would create surprising case-collisions). Length 4 ⇒ 36^4 ≈ 1.68M.
- **Nonce STACKS with `-<prime>`** collision disambiguation (does not replace it).
- **Bonus:** fold the missing `is_valid` format check into the broker chokepoint so CLI
  paths get it too.

## Slices
### Slice B1 — Blocklist at the chokepoint
- `ocaml/c2c_broker.ml:1681-1687`: add `banned_aliases` (static set: `gpt`, `assistant`,
  `gemini`, `crush`, plus reuse `C2c_start.supported_clients` from `c2c_start.ml:1578` —
  claude, codex, opencode, kimi) + a predicate `is_banned_alias` that casefolds and checks
  full-equality OR first-hyphen-segment equality.
- Wire into `Broker.register` (`c2c_broker.ml:1872`) right after `is_reserved_system_alias`.
  ALSO fold `C2c_name.is_valid` (`c2c_name.ml:8`) here so all paths validate format.
  Rejection raises `invalid_arg` (existing pattern) — but see B2 for the MCP friendly error.
- Mirror a pre-check + friendly `tool_err` in the MCP handler
  (`c2c_identity_handlers.ml:45-50`) so MCP returns an error result, not an exception.
- ⚠️ Dependency note: `c2c_broker.ml` referencing `C2c_start` may create a module cycle.
  VERIFY build order; if cyclic, hoist the supported-clients list into a low-level module
  (e.g. `c2c_name.ml` or a new `c2c_blocklist.ml`) that both depend on. Resolve cleanly —
  do not introduce a cycle.

### Slice B2 — Nonce generator + auto-gen-only application
- New `ocaml/c2c_nonce.ml` (or a fn near `c2c_name.ml`): `gen_nonce () = String.init 4
  (fun _ -> charset.[Random.int 36])` with `charset = "0123456789abcdefghijklmnopqrstuvwxyz"`.
  Ensure `Random` is seeded on the relevant path (auto-gen sites already seed:
  `c2c_start.ml:2467` `Random.self_init`; verify the install path `c2c_setup.ml:186` seeds).
- Apply the nonce ONLY inside the auto-generate functions, AFTER a bare name is produced,
  BEFORE it's used/registered:
  - `ocaml/c2c_start.ml:2466` `generate_alias` / `:2477` `default_name`
  - `ocaml/cli/c2c_setup.ml:186` `generate_alias` / `:199` `generate_alias_easy` /
    `:246` `default_alias_for_client`
  Do NOT touch the user-supplied/role/env resolution paths — those stay bare.
- `--no-nonce` plumbing: add the flag to the auto-gen-bearing commands
  (`c2c.ml:6682` init, `:8977` start, `c2c_setup.ml:1785` setup/install) and thread it into
  the generate calls. (register `c2c.ml:2857` takes an explicit alias normally; include the
  flag only where auto-gen can occur.) Add a `no_nonce` bool to the MCP `register` schema
  (`c2c_mcp.ml:30-38`) for parity, honored only when the handler auto-generates.

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
- Add tests: (a) blocklist rejects `claude`/`claude-code`/`gpt`, accepts `lyra-quill`;
  (b) MCP register returns friendly error (not exception) for banned name; (c) auto-gen
  produces `<word>-<word>-<4 lowercase alnum>`; (d) `--no-nonce` yields bare auto name;
  (e) explicit `--alias foo` is NOT nonce'd; (f) nonce charset is lowercase-only.
- Docs: pool/format invariant (`CLAUDE.md:268` == `AGENTS.md:268` == `docs/commands.md:994`)
  — update to describe blocklist + nonce; register/init examples; role-template notes.

## Acceptance criteria
- `dune build` clean IN WORKTREE (rc=0); full suite green `-j2`.
- No module cycle introduced (B1 note).
- Banned names rejected on BOTH MCP + CLI with a friendly MCP error.
- Auto-gen names carry a lowercase 4-char nonce; explicit/role/env names do NOT.
- `--no-nonce` works; MCP `no_nonce` arg works.
- Output everywhere shows the full registered name incl nonce.
- Docs updated (docs-up-to-date gate); pool/format invariant consistent across all 3 copies.

## Final step — REVIEW-AND-FIX LOOP (required)
Run `review-and-fix` on each slice SHA until PASS (fixes in NEW commits, never `--amend`).
Then peer cross-review by a DIFFERENT ccc model with the build-clean verdict produced INSIDE
this worktree (`build-clean-IN-slice-worktree-rc=0` in `criteria_checked`). Pay special
attention to the module-cycle risk (B1) and the auto-gen-vs-explicit boundary (B2) — a
verifier should confirm explicit/role/env aliases are never nonce'd. Do NOT push — lands
after connect-docs; coordinator/Max gate.
