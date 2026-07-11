# B128 — Generalize `--` arg passthrough to all `c2c start`/`c2c new` client wrappers

Slice: `slice/b128-passthrough` (worktree `.worktrees/b128-passthrough`).
Date: 2026-07-11.

## TL;DR

**Mechanism was already generalized by the shared launch path (#372/#470,
carried through T006).** No production code fix was needed. This slice adds
the missing per-client passthrough tests (kimi, gemini) + an explicit
pre-/post-`--` boundary test, and generalizes the docs. One trivial
**pre-existing** test-compile break was fixed so the suite compiles.

## Audit — what was already generalized

`c2c start <client> -- <opts...>` forwards `<opts...>` verbatim to the client
argv for **every** supported client through **one shared code path**, not
per-client copies:

- Parse boundary (`ocaml/cli/c2c_managed_cmd.ml`, `start_cmd`): `extra_argv`
  uses `Cmdliner.Arg.(pos_all string [])` and strips the leading two
  positionals (`<client>` + `--`). Cmdliner's standard `--` semantics stop
  c2c option parsing there, so post-`--` tokens are never parsed as c2c flags.
  (#470 switched from `pos_right 1 (list string)` — which comma-split tokens —
  to `pos_all string`, preserving tokens verbatim.)
- Dispatch: codex → `C2c_codex_cmd.start_delegate ~extra_args`; every other
  client → `cmd_start_with ~extra_args`. Both funnel into
  `C2c_start.cmd_start` → `C2c_start.prepare_launch_args`.
- Uniform tail append: `prepare_launch_args` ends with **`args @ extra_args`**
  (`ocaml/c2c_start.ml:3390`) — the single place the final argv is assembled.
  `extra_args` land at the tail for claude / opencode / codex / kimi / gemini
  / codex-headless alike. Adapters (kimi, gemini) inspect `extra_args` only to
  avoid doubling their own injected flags (e.g. kimi `--mcp-config-file`); they
  never consume them, so the verbatim tail append is uniform.

### `c2c new` scope note

`c2c new` / `c2c codex` / `c2c resume codex` are **codex-only by design**
(T006, `ocaml/cli/c2c_codex_cmd.ml`, guarded by `require_codex_client`). They
peel positionals with `drop_sep` / `split_client` / `split_client_alias` and
route `extra_args` through the same `prepare_launch_args` tail append, so
`c2c new codex -- <opts>` already forwards verbatim. Generalizing `c2c new` to
spawn fresh claude/opencode/kimi/gemini threads is a **separate feature** (new
per-client new-thread semantics), not an arg-passthrough bug — out of scope for
B128. The universal wrapper that honors `--` for all clients is `c2c start`.

### Per-client verdict

| Client | `c2c start <c> -- <opts>` verbatim passthrough | Pre-slice test |
|--------|:--:|--|
| claude | already (shared path) | yes (#372) |
| opencode | already (shared path) | yes (#372) |
| codex | already (shared path; also `c2c codex/new/resume`) | yes (#372) |
| kimi | already (shared path) | **added this slice** |
| gemini | already (shared path) | **added this slice** |
| pi | not a `c2c start` client (own `pi-c2c` extension) | n/a |

## Changes made

- **No production code change** — mechanism already correct + uniform.
- `ocaml/test/test_c2c_start.ml`: added
  - `test_prepare_launch_args_forwards_extra_args_for_kimi` (hermetic — passes
    an explicit `--mcp-config-file` in `extra_args` so the kimi adapter skips
    the on-disk MCP-config write; asserts a custom flag + the config flag are
    forwarded verbatim with commas preserved).
  - `test_prepare_launch_args_forwards_extra_args_for_gemini`.
  - `test_extra_argv_boundary_c2c_flag_not_consumed_b128` — explicit boundary
    proof: pre-`--` `-n` parses as c2c name; post-`--` `--model` / `-n` /
    `--alias` (byte-identical to real c2c flags) are NOT parsed by c2c and are
    forwarded verbatim.
  - Registered all three in the Alcotest run list.
  - Fixed a **pre-existing** compile break: `test_tmux_message_payload_uses_c2c_envelope`'s
    `C2c_mcp.message` record literal was missing the `pow_difficulty` field that
    B014 added to the type — the base `test_c2c_start.exe` did not compile.
    Added `; pow_difficulty = None`.
- `docs/commands.md`: added a general **"Argument passthrough (`--`) — any
  client wrapper"** section (works for claude/codex/opencode/kimi/gemini),
  documented the alias-ending-in-`--` convention generally, updated the
  `start CLIENT` row to show `[-- client-options…]` + added `gemini` to its
  client list, and re-pointed the codex-specific `--` block at the general rule
  (codex kept as the primary worked example).

## Verification (return codes)

- `just build` → **RC 0**.
- `scripts/dune-build-locked.sh exec ocaml/test/test_c2c_start.exe` (=
  `dune exec ... test_c2c_start.exe`) → **RC 0**, "Test Successful in 2.479s.
  200 tests run." New tests observed passing:
  `launch_args.015` (kimi), `.016` (gemini), `.017` (boundary).
- `just check` → **RC 1**, failure is ONLY the pre-existing
  `sync-skills`/skill-codegen Grok drift in `.codex/skills/c2c/SKILL.md` and
  `.opencode/skills/c2c/SKILL.md` (the `git diff --exit-code -- .collab/skills
  .opencode/skills .codex/skills` step). Unrelated to this slice; not fixed per
  task instruction. No B128-touched file appears in the failing diff.
