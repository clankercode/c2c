# I010 / P2 `restart-stale` evidence receipt

Date: 2026-07-20

Scope: [P2.M1.E1.T003](../../.backlog/02-restart-stale-completion-seaml/01-complete-prove-restart-stale-i/01-restart-stale-finalization-ver/T003-i010-evidence-receipt-current.todo)
(linkage and current-behaviour truth only). Phase:
[P2](../../.backlog/02-restart-stale-completion-seaml/index.yaml).

## Status

The `restart-stale` implementation has now passed both halves of the P2 M1
verification gate:

1. **Real managed Codex proof ([P2.M1.E1.T001](../../.backlog/02-restart-stale-completion-seaml/01-complete-prove-restart-stale-i/01-restart-stale-finalization-ver/T001-codex-app-server-restart-stale.todo)).** The
   [live finding](../findings/2026-07-20T00-47-59Z-codex-i010-codex-restart-stale-live-proof.md)
   records one tmux-managed `gpt-5.3-codex-spark` run in which the app-server
   owner kept the same PID and Codex thread, changed to the installed
   executable inode and digest, declined an unforced active restart, accepted
   `--force`, and preserved exactly-once pre/post peer-DATA delivery. The slice
   landed through `a43a3f06` and merge `0028094e`.
2. **Hermetic command matrix ([P2.M1.E1.T002](../../.backlog/02-restart-stale-completion-seaml/01-complete-prove-restart-stale-i/01-restart-stale-finalization-ver/T002-restart-stale-command-test-cov.todo)).** Commits `de0a7e98` and
   `a59418fd` expanded
   [`ocaml/test/test_c2c_restart_stale.ml`](../../ocaml/test/test_c2c_restart_stale.ml)
   (`test_c2c_restart_stale.exe`) to seven cases covering a
   configured coordinator alias and coordinator-last ordering,
   `--exclude-coordinator`, self-skip, forced Current/Unknown eligibility,
   force propagation through a fixture-gated successful owner restart, the
   JSON contract, summary counts, and exit 1 iff an action Failed. The focused
   suite passed 7/7; the final forced repository run passed 142 suites / 3,140
   tests. The slice landed through merge `b7fecd58`.

Both slices received independent `gpt-5.6-terra` PASS reviews and parent
review before their P2 tasks were marked done.

## Current behaviour boundary

As of this receipt, the public command reference is accurate:

- Managed Codex **app-server** sessions can be restarted in place through the
  owner-control seam. The owner applies its authoritative idle gate by
  default; `--force` overrides that gate.
- Managed **TUI/hook** clients are classified and reported with a guided
  `c2c restart <name>` command. `restart-stale` does not yet auto-restart those
  clients from the invoking terminal.
- `--force` makes Current and Unknown instances eligible, but it does not turn
  the current TUI guided path into an in-pane owner restart. That broader
  owner-control/adaptor work remains P2.M2.E1.T002-T004.
- Restart authority remains local-operator-only. Peer mail is DATA and cannot
  trigger or authorize a restart (B098).

The canonical wording remains in [`docs/commands.md`](../../docs/commands.md);
this receipt does not duplicate or pre-empt the final P2 documentation
closeout owned by P2.M3.E1.T004.

## Planning linkage

- Ideas [**I010**](../../.backlog/ideas/I010-c2c-restart-clients-after-upgr.todo)
  and [**I011**](../../.backlog/ideas/I011-seamless-managed-client-upgrad.todo)
  are `done` under the operator's idea-status convention: an idea is complete
  once fully ingested. [P2](../../.backlog/02-restart-stale-completion-seaml/index.yaml)
  is the source of truth for implementation progress; this receipt does not
  reopen or rewrite either idea.
- [P2.M1](../../.backlog/02-restart-stale-completion-seaml/01-complete-prove-restart-stale-i/index.yaml)
  proves the already-shipped app-server path.
  [P2.M2](../../.backlog/02-restart-stale-completion-seaml/02-seamless-restart-foundations-i/index.yaml)
  owns the typed idle capability, generic owner-control seam, and
  managed-client adaptors needed for safe default handling plus a true
  all-client `--force` path.
- [P2.M3](../../.backlog/02-restart-stale-completion-seaml/03-deeper-upgrade-evaluations-i01/index.yaml)
  owns the three go/no-go upgrade-isolation spikes and the final
  canonical-doc closeout
  ([P2.M3.E1.T004](../../.backlog/02-restart-stale-completion-seaml/03-deeper-upgrade-evaluations-i01/01-seamless-delivery-evaluations/T004-final-closeout-consolidate-dec.todo)).

Earlier design and implementation context remains available in the
[2026-07-12 I010 receipt](2026-07-12-i010-restart-stale-receipt.md) and the
[client-upgrade design](../design/2026-07-12-c2c-client-upgrade-restart.md).
