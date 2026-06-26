# Session handoff — chess e2e + relay variants (pre-compact 2026-06-26)

**Worktree:** `/home/xertrov/src/c2c/.worktrees/e2e-pi-opencode-model`
**Branch:** `e2e-pi-opencode-model` (off `origin/master`). **NOT pushed/merged.**
**Build:** worktree `_build/default/ocaml/cli/c2c.exe` is the FIXED relay binary
(includes the relay full-address-signer fix). Rebuild: `mkdir -p _build && touch
_build/.c2c-build.lock && flock _build/.c2c-build.lock opam exec -- dune build -j 2
--root "$PWD" ./ocaml/cli/c2c.exe`.

## What's done + validated

1. **pi+opencode e2e + model selection** (original /pirfl ask) — DONE, reviewed PASS.
   `e2e_model()` (C2C_E2E_MODEL/<CLIENT>_MODEL, default mimo-v2.5-pro), PiAdapter,
   canonical-broker resolution fix, send_dm C2C_COORDINATOR. pi 3/3 live; opencode
   register+send/receive live. `model_override` env-flaky (tmux).
2. **Local chess (pi vs opencode)** — built, unit-tested (13 CLI tests), reviewed PASS.
   `scripts/c2c_chess.py`, `tests/test_c2c_chess_e2e.py`, message recorder. pi launches
   clean; opencode managed-start blocks the FULL local game (separate fragility).
3. **Relay chess variant (a)** — controller-driven over PUBLIC relay. LIVE-VALIDATED
   (10/10 plies via relay.c2c.im). `tests/test_c2c_chess_relay_e2e.py`. Reviewed PASS +
   load-bearing-FEN fix. Transcript now records full `<alias>@<host>` (machine id).
4. **Relay full-address signer FIX** — `ocaml/relay.ml` (commit 2516b640):
   `from_alias_signer_name` compares the verified signer to the NAME part of from_alias
   (strips `@<host>`). Fixes "verified signer X does not match body from_alias X@host".
   Verified vs local fixed relay (POW off + on): bare AND full-address sends both ok.
   **Needs prod deploy to fix relay.c2c.im.** Finding:
   `.collab/findings/2026-06-26T12-15-00Z-relay-send-full-address-alias-signature-mismatch.md`.
5. **Variant C — pi plays over relay via native c2c_pi_* tools** —
   `tests/test_c2c_chess_pi_relay_e2e.py` (commit c647fc30), gated
   `C2C_TEST_PI_RELAY_CHESS_E2E=1`. Parametrized: local-pow-off, local-pow-on, remote(skip).
   - `test_relay_accepts_full_address_signer`: PASSES pow-off + pow-on (regression).
   - `test_pi_plays_over_relay_via_native_tools`: PONG probe proved pi receives relay DMs
     + replies via `c2c_pi_send` over the local fixed relay. **Live chess (pow-off)
     RUNNING at compact time** — check result.

## IN PROGRESS / NEXT (resume here)

- **Live test `test_pi_plays_over_relay_via_native_tools[local-pow-off]` was running.**
  Background pytest + a pi tmux session on socket `c2c-pi-relay-chess` + a local relay
  may still be alive. Check `/tmp/.../scratchpad/pi-relay-chess.txt`, the transcript at
  `/tmp/c2c-pi-relay-chess-*/transcript.txt`. Clean up if orphaned:
  `tmux -L c2c-pi-relay-chess kill-server`; kill stray `relay serve --listen 127.0.0.1`.
- Then run `[local-pow-on]` too (user: "both local with pow and local without pow work").
- Run the full ungated unit suite (`pytest tests/test_c2c_chess.py
  tests/test_terminal_e2e_framework.py tests/test_terminal_e2e_client_adapters.py
  tests/test_e2e_models.py -q --force-test-env`) — was 77 passed before relay.ml.
- `review-and-fix` the variant C test + relay.ml fix (reviewer agent id
  `ac144190f9b4f9fdc` reusable via SendMessage).
- **THEN MERGE** (user gate: "after [variant C] passes, you can merge"). Merge target:
  ASK the user (master vs their branch). Do NOT push (push gate; test+relay-fix only —
  relay fix needs a deploy which is coordinator-gated; file for deploy).

## Guardrails learned this session
- tmux isolation needs `-L <socket> -f /dev/null` (continuum auto-restore else clones
  the user's sessions + hangs new-session). User's tmux died once early (sessions 191 +
  preview-md-dev) — now safe via -f/dev/null. Verify `tmux ls` still shows 191/c2c-B002/
  preview-md-dev intact.
- DON'T edit the main tree (`/home/xertrov/src/c2c`) for slice work — I mistakenly edited
  ocaml/relay.ml there, moved it to the worktree, reverted main. Work in the worktree.
- `pkill -f "<string in my own command>"` kills my shell (exit 144). Kill by PID.
- relay commands emit JSON by default (no --json flag). `c2c host-id` = machine id.
