# B144 — Live Codex E2E for hooks+CLI and managed app-server transports

## Problem
Codex delivery has two transports; live coverage is split/incomplete:
- Hook+CLI: `test_c2c_hook_codex.ml` and draft-preservation Row 6 feed the hook
  **synthetic** payloads (`c2c hook codex` invoked directly). No test lets the
  hook fire *naturally* from a real interactive codex.
- Managed app-server: `codex-ingress-dogfood.py` / `codex-autoturn-e2e.py` /
  `codex-draft-preservation-e2e.py` drive the app-server *seams* via dev drivers
  but never launch the managed `c2c start`/`c2c new codex` supervisor.

## Established conventions (reused, not reinvented)
- **Live gate (in-suite):** `test_c2c_codex_app_server.ml` gates its live proof on
  `C2C_CODEX_APPSERVER_LIVE=1`, skipping with `Alcotest.(check pass) "skipped
  (gate off)"` when unset. This is the canonical in-suite skip pattern.
- **Live harness shape:** existing codex e2e scripts are standalone Python with
  `preflight` / `run` modes, `run` refuses unless `$TMUX` is set, codex located
  via `CODEX_BIN`/PATH, version parsed from `codex --version` (`codex-cli 0.144.1`).
- **Isolation:** `c2c install codex` (setup_codex, c2c_setup.ml:588) resolves the
  codex config from `$HOME/.codex/config.toml` — so `HOME=<tmp>` isolates the
  hook install; codex then reads that same `<tmp>/.codex` (auth.json copied in).
- **herdr harness:** `herdr agent start <name> --cwd P --env K=V -- <argv>`,
  `herdr agent send`, `herdr agent read`, `herdr agent wait --status idle`,
  `herdr wait output <pane> --match` — a real terminal for a natural hook fire.

## Deliverables
1. `scripts/codex-hooks-live-e2e.py` — HOOK+CLI transport. Isolated `HOME` +
   `c2c install codex` (real hooks, pre-trusted). Launch a real codex under herdr
   (tmux fallback) with `C2C_CODEX_FORCE_HOOKS=1`. Register a peer, send a real
   DM, drive a prompt so the hook fires **naturally**, assert (a) the c2c envelope
   appears in the transcript via hook additionalContext, (b) the inbox was drained.
   Gate: `C2C_CODEX_HOOKS_LIVE`. preflight/run.
2. `scripts/codex-managed-appserver-live-e2e.py` — MANAGED app-server transport.
   Launch via `c2c new codex` (in tmux, per CLAUDE.md). Send a peer DM, assert:
   arrival-time model-visible injection, an eligible LOCAL auto-turn fired,
   typed-draft preservation held, teardown/deregistration clean (no orphan proc,
   registration gone). Gate: `C2C_CODEX_APPSERVER_LIVE`. preflight/run.
3. `ocaml/test/test_c2c_codex_live_e2e.ml` (+ dune stanza) — in-suite skip proof.
   Two gated cases; gate off → skip; gate on → shell to the harness `run` mode,
   assert exit 0. Keeps `dune runtest` (CI) hermetic by default.
4. Retire stale XML-sideband E2E refs: `test-codex-delivery-tmux-e2e.sh` header
   points at the new hooks harness as the live replacement; sweep other
   E2E-specific `--xml-input-fd` refs.

## Gating summary (opt-in commands)
- Hooks:      `C2C_CODEX_HOOKS_LIVE=1 scripts/codex-hooks-live-e2e.py run` (in tmux)
- App-server: `C2C_CODEX_APPSERVER_LIVE=1 scripts/codex-managed-appserver-live-e2e.py run` (in tmux)
- Hermetic default: neither var set → each harness prints SKIP, exits 0; the
  OCaml cases skip; `just test-ocaml` / `dune runtest` stay green.
