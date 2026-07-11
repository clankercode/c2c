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
argv for **every** supported client, with **no per-client copies** of the
forwarding logic. The parse boundary is shared; there are **two** argv
tail-assembly sites (both verbatim), selected by transport:

- Parse boundary (`ocaml/cli/c2c_managed_cmd.ml`, `start_cmd`): `extra_argv`
  uses `Cmdliner.Arg.(pos_all string [])` and strips the leading two
  positionals (`<client>` + `--`). Cmdliner's standard `--` semantics stop
  c2c option parsing there, so post-`--` tokens are never parsed as c2c flags.
  (#470 switched from `pos_right 1 (list string)` — which comma-split tokens —
  to `pos_all string`, preserving tokens verbatim.)
- Dispatch: codex → `C2c_codex_cmd.start_delegate ~extra_args` →
  `C2c_codex_session.run`; every other client → `cmd_start_with ~extra_args`.
- **Tail-assembly site 1 — `prepare_launch_args`** (`ocaml/c2c_start.ml:3390`):
  ends with **`args @ extra_args`**. This is the site for **all non-codex
  clients** (claude / opencode / kimi / gemini / codex-headless) **and the
  hook-backed codex path** (the live default: `C2c_codex_session.run` with
  `engage=false` calls the fallback → `C2c_start.cmd_start` →
  `prepare_launch_args`). Adapters (kimi, gemini) inspect `extra_args` only to
  avoid doubling their own injected flags (e.g. kimi `--mcp-config-file`); they
  never consume them, so the verbatim tail append is uniform.
- **Tail-assembly site 2 — `build_frontend_argv`**
  (`ocaml/c2c_codex_app_server.ml:824`): the **opt-in codex app-server
  transport** (`--app-server` / `C2C_CODEX_APP_SERVER=1`) does NOT go through
  `prepare_launch_args`. `run_app_server` sets
  `extra_frontend_args = frontend_extra_args ~yolo ~extra:(model_args @ extra_args)`
  and `build_frontend_argv` appends `@ cfg.extra_frontend_args` after the fixed
  `--remote … --remote-auth-token-env …` prefix. So the passthrough tail is
  still verbatim, via a separate site. (Correction from the first draft, which
  claimed a single funnel — flagged by the codex review; now tested.)

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
| codex (hook) | already (site 1; also `c2c codex/new/resume`) | yes (#372) |
| codex (app-server) | already (site 2, `build_frontend_argv`) | **added this slice** |
| kimi | already (site 1) | **added this slice** |
| gemini | already (site 1) | **added this slice** |
| pi | not a `c2c start` client (own `pi-c2c` extension) | n/a |

## Changes made

- **No production code change to the forwarding mechanism** — already correct +
  uniform. One small display-list correction (see `start_clients` below).
- `ocaml/test/test_c2c_start.ml`: added
  - `test_prepare_launch_args_forwards_extra_args_for_kimi` (hermetic — passes
    an explicit `--mcp-config-file` in `extra_args` so the kimi adapter skips
    the on-disk MCP-config write; asserts the **full** extra_args block is the
    verbatim argv **tail** via `is_suffix`, commas preserved).
  - `test_prepare_launch_args_forwards_extra_args_for_gemini` (same `is_suffix`
    tail assertion).
  - `test_extra_argv_boundary_c2c_flag_not_consumed_b128` — explicit boundary
    proof: pre-`--` `-n` parses as c2c name; post-`--` `--model` / `-n` /
    `--alias` (byte-identical to **declared** c2c flags — `--alias` is now a
    real declared option in the test term) are NOT parsed by c2c and are
    forwarded verbatim.
  - Added an `is_suffix` helper (whole-block tail match; stronger than
    `has_adjacent_pair`).
  - Registered all in the Alcotest run list.
  - Fixed a **pre-existing** compile break: `test_tmux_message_payload_uses_c2c_envelope`'s
    `C2c_mcp.message` record literal was missing the `pow_difficulty` field that
    B014 added to the type — the base `test_c2c_start.exe` did not compile.
    Added `; pow_difficulty = None`.
- `ocaml/test/test_c2c_codex_app_server.ml`: added
  `test_frontend_argv_appends_extra_frontend_args_verbatim_b128` (new
  `passthrough` group) — covers **tail-assembly site 2**: proves
  `build_frontend_argv` appends `extra_frontend_args` verbatim after the fixed
  `--remote … --remote-auth-token-env …` prefix (closes the app-server route
  gap the codex review flagged).
- `ocaml/cli/c2c_setup.ml`: added `"gemini"` to `start_clients` — the advertised
  `c2c start` client list (used by `start_client_list` in `--help`) omitted
  gemini even though gemini is a full managed client (in the `clients` hashtbl,
  has an adapter + a `prepare_launch_args` branch). Display-only fix; makes
  `--help` and `docs/commands.md` agree.
- `docs/commands.md`: added a general **"Argument passthrough (`--`) — any
  client wrapper"** section scoped to the managed **agent** clients
  (claude/codex/opencode/kimi/gemini), with an explicit callout that
  `tmux`/`pty` handle the post-`--` tail differently (typed into pane / spawn
  command). Documented the alias-ending-in-`--` convention generally, updated
  both `start CLIENT` rows to show `[-- client-options…]` + `gemini`, and
  re-pointed the codex-specific `--` block at the general rule (codex kept as
  the primary worked example).

## Codex review (`/ccc-review-cx`)

First review returned **FAIL** with 3 major + 1 minor. All accepted + fixed:
1. audit overclaimed "one shared funnel" — app-server route is a separate
   verbatim tail site → audit corrected + app-server test added.
2. kimi/gemini tests used `has_adjacent_pair` (adjacency only) → strengthened to
   `is_suffix` (whole-block verbatim tail).
3. boundary test's `--alias` was an undeclared token → `--alias` now a real
   declared option in the test term, asserted `None`.
4. docs: general rule didn't note tmux/pty exception + Tier-2 row / `--help`
   omitted gemini → docs scoped + `start_clients` gains `gemini`.

## Verification (return codes)

- `just build` → **RC 0**.
- `dune exec ... test_c2c_start.exe` → **RC 0**, "Test Successful. 200 tests
  run." New: kimi/gemini `is_suffix` tail tests + boundary test all pass.
- `dune exec ... test_c2c_codex_app_server.exe` → **RC 0**, "Test Successful.
  28 tests run." New `passthrough` group (app-server frontend-argv tail) passes.
- `just check` → **RC 1**, failure is ONLY the pre-existing
  `sync-skills`/skill-codegen Grok drift in `.codex/skills/c2c/SKILL.md` and
  `.opencode/skills/c2c/SKILL.md` (the `git diff --exit-code -- .collab/skills
  .opencode/skills .codex/skills` step). Unrelated to this slice; not fixed per
  task instruction. No B128-touched file appears in the failing diff.
