# Client registries sync assertion (#388)

**Agent**: subagent dispatched by cairn (research follow-up to client-matrix-audit)
**Date**: 2026-04-29
**Slice**: client-registries-sync
**Worktree**: `.worktrees/client-registries-sync/`
**Branch**: `slice/388-client-registries-sync`
**SHA**: `395b88dd3f3fd66c59b4658c6c6627ba1dfaab3e`
**Issue**: #388 (code health audit, second pass)

## Goal

Close Gap 1 from `.collab/research/2026-04-29-client-matrix-audit-cairn.md`:
the two parallel registries `clients` and `client_adapters` in
`ocaml/c2c_start.ml` are kept in hand-sync with no startup check that
they agree. Add fail-fast detection so a future PR adding to one but
not the other crashes loudly at startup instead of producing silent
misconfiguration.

## What landed

`feat(#388): startup assertion that clients and client_adapters registries agree`

- New `assert_clients_match_adapters` function invoked at module init
  in `ocaml/c2c_start.ml`. Detects three drift cases:
  1. Orphan adapter (in `client_adapters` but not in `clients`) — would
     bypass daemon-wiring fields silently.
  2. Undeclared no-adapter (in `clients`, not in `client_adapters`, not
     in `clients_without_adapter` allowlist) — forces explicit decision.
  3. Stale allowlist entry (in `clients_without_adapter` but not in
     `clients`) — forces cleanup when removing a client.
- New `clients_without_adapter` allowlist documenting the 4 entries
  that intentionally have no adapter: `crush`, `codex-headless`,
  `pty`, `tmux`.
- Helper `client_adapter_keys ()` exposed in the .mli so tests can
  cross-check without leaking the `CLIENT_ADAPTER` module type.
- 4 unit tests in `ocaml/test/test_c2c_start.ml` under
  `client_registries_sync_388` group covering each invariant
  individually plus the round-trip pass.

## Verification

- `dune build --root .worktrees/client-registries-sync` → rc=0
- `dune build --root .worktrees/client-registries-sync @runtest` → rc=0
- New tests appear in test output:
  ```
  [OK] client_registries_sync_388  0  assert_clients_match_...
  [OK] client_registries_sync_388  1  every_adapter_has_cli...
  [OK] client_registries_sync_388  2  every_clients_entry_h...
  [OK] client_registries_sync_388  3  clients_without_adapt...
  ```

## Files

- `ocaml/c2c_start.ml` (+89)
- `ocaml/c2c_start.mli` (+25)
- `ocaml/test/test_c2c_start.ml` (+68)

## Path note

The source research doc said "ocaml/cli/c2c_start.ml" but the file
actually lives at `ocaml/c2c_start.ml` (no `cli/` prefix). No
functional impact — just a heads-up for the next subagent following
the audit doc's pointers.

## Status

Done. Awaiting peer-PASS before coord-PASS / push.
