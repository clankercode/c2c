# Plan — #379 Cross-host `alias@host` FINISH

**Status**: design plan, not yet sliced. Subagent-produced 2026-04-28T10:28 UTC. See `.collab/research/2026-04-28T10-15-00Z-coordinator1-379-cross-host-alias-finish-vs-revert.md` for the FINISH vs REVERT recommendation that motivates this plan.

## Summary

Half-wiring is in addressing, not transport. Fix at relay ingress: split
`to_alias` on `@`; if host part matches the relay's well-known name (or is
empty / wildcard `*`), strip it and look up the bare alias. Otherwise
dead-letter with a precise reason (`cross_host_not_implemented`) instead
of misleading `unknown_alias`. Add one e2e test, update three docs,
peer-PASS.

## Decisions

- **Strip at relay ingress, not connector.** Cleaner federation story
  (#330 mesh) — connector keeps forwarding the full canonical address;
  relay is the single normalization point.
- **`self_host` identity:** Add a `~self_host:string option` arg to
  `Broker.send` (and threaded from `start_server`'s existing `~host` param
  via a new `--relay-name` CLI flag, defaulting to the value of `--host`
  and overridable). v1 accepts `to_alias` whose host part equals
  `self_host` OR equals the literal `"relay"` (back-compat with the
  existing test fixture `lyra@relay`) OR is empty. All other host parts →
  dead-letter `cross_host_not_implemented`.
- **No connector changes** beyond logging. Receiver registers bare alias
  as today.
- **Send-side canonical resolution (Phase 2 spec §6) is OUT of scope** for
  this slice — explicitly punted.

## Where exactly to strip `@host`

`ocaml/relay.ml:853-866` inside `Broker.send`. New helper
`split_alias_host : string -> string * string option` lives in the same
module (private), used at line 857 before the `Hashtbl.find_opt`.

```ocaml
(* sketch *)
let split_alias_host s =
  match String.index_opt s '@' with
  | None -> (s, None)
  | Some i ->
    (String.sub s 0 i, Some (String.sub s (i+1) (String.length s - i - 1)))

let host_acceptable ~self_host = function
  | None -> true
  | Some "" | Some "relay" -> true
  | Some h -> (match self_host with Some sh -> h = sh | None -> false)
```

Two new dead-letter `reason` strings:
- `"cross_host_not_implemented"` — host present and unknown
- existing `"unknown_alias"` — bare alias not registered

## Backward compat

- `Hashtbl.find_opt t.leases bare` is unchanged when input has no `@` →
  all existing local tests pass untouched.
- Existing test `test_send_remote_alias_appends_to_outbox` only checks
  **outbox** state; behavior unchanged.
- Existing relay test fixtures using bare `"alice"` etc. → unchanged.
- New behavior is gated on presence of `@`; no observable change for
  `@`-free input.

## Slices

### Slice 1 — Relay ingress host-strip (core)

**SPEC:** Add `split_alias_host` + `host_acceptable` helpers in
`ocaml/relay.ml`. Thread `self_host : string option` through `Broker.send`
(default `None` ⇒ accept any host with literal `"relay"` or empty). Strip
and lookup bare alias. Cross-host (unknown host) → dead-letter
`cross_host_not_implemented`.

**INTERFACE:**
- `Broker.send` signature unchanged; `self_host` read from `t` field
  added in slice constructor.
- New `t.self_host : string option`, set via `Broker.create`.

**Hours:** 2

**Acceptance:**
- Unit test: `send ~to_alias:"alice@relay"` resolves when `alice` is
  registered.
- Unit test: `send ~to_alias:"alice@evil.example"` with
  `self_host=Some "relay.c2c.im"` produces dead-letter with
  `reason="cross_host_not_implemented"`.
- Unit test: `send ~to_alias:"alice"` (no `@`) still works.
- All existing relay tests green.

### Slice 2 — CLI `--relay-name` plumbing

**SPEC:** Add optional `--relay-name <s>` to `c2c relay serve`. Defaults
to value of `--host` if not given. Pass into `Broker.create ~self_host`.
Doctor / `c2c relay status` echoes it.

**INTERFACE:** `Relay.start_server ~host ~port ~relay:Broker.t
~self_host:string option …`

**Hours:** 1

**Acceptance:**
- `c2c relay serve --host 127.0.0.1 --relay-name relay.c2c.im` boots; logs
  the name.
- `Broker.create` accepts and stores `~self_host`.

### Slice 3 — End-to-end test: cross-host send

**SPEC:** New test `test_cross_host_alias_finish` in
`ocaml/test/test_c2c_mcp.ml` (or a new `test_cross_host_e2e.ml` if the
existing file is overweight). Spins up: relay (`self_host="hostA"`),
receiver registers bare `"b"` against relay, sender writes
`to_alias:"b@hostA"` into outbox, connector drains, assert receiver inbox
contains the message. Negative case: `to_alias:"b@hostZ"` → relay
dead-letter has `reason="cross_host_not_implemented"`.

**INTERFACE:** Pure test; reuses fixtures from
`test_c2c_relay_connector.ml:134` style.

**Hours:** 2

**Acceptance:**
- Positive path delivers message into receiver inbox (not just outbox).
- Negative path lands in `Broker.dead_letter` with the new reason string.
- Test file builds under existing dune harness.

### Slice 4 — Doc updates

**SPEC:** Update three docs to reflect "single-relay v1, host part must
equal `--relay-name`":
- `docs/commands.md` (lines 84, 92, 667-668) — clarify accepted host
  values.
- `docs/relay-quickstart.md` (lines 153, 329) — note `--relay-name` flag.
- `docs/cross-machine-broker.md` (lines 119, 196, 242) — replace
  "future work" stub with v1 status.
- `.collab/runbooks/remote-relay-operator.md` — add `--relay-name` to the
  serve example.
- `.collab/specs/2026-04-21-alias-naming-standardization.md` — flip Phase
  2 §6.1 (host-strip) from "future" to "landed in #379"; leave §6.2
  (canonical disambiguation) as future.

**Hours:** 1

**Acceptance:**
- `grep -rn "alias@host" docs/ .collab/` produces no contradictory "future
  work" claims about host-strip.
- Spec marks §6.1 done with PR ref.

### Slice 5 — peer-PASS + commit

**SPEC:** Run `just test`, `just lint`, get peer-PASS via `review-and-fix`
skill, commit in worktree, hand to coordinator for cherry-pick.

**Hours:** 1-2

**Acceptance:** Green CI; signed peer-PASS DM in coordinator inbox.

## Total: 7 hours (within 4-8 estimate)

## Sequencing

Slice 1 → Slice 2 (parallelizable with 1) → Slice 3 (depends on 1,
optionally 2) → Slice 4 (parallel with anything) → Slice 5 (last).

## Risks / call-outs

- The literal `"relay"` host-name backdoor is a back-compat hack for
  `lyra@relay` test fixtures. Document it explicitly. Once fixtures are
  migrated to `--relay-name relay.c2c.im` it can be retired.
- Mesh (#330) is *not* unblocked by this slice; the dead-letter
  `cross_host_not_implemented` is the seam where mesh code will later
  branch into a peer-relay forwarder.

## Critical Files

- `ocaml/relay.ml`
- `ocaml/c2c_relay_connector.ml`
- `ocaml/test/test_c2c_mcp.ml`
- `docs/relay-quickstart.md`
- `.collab/specs/2026-04-21-alias-naming-standardization.md`
