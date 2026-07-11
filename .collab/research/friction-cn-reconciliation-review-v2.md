# Friction reconciliation review v2

Date: 2026-07-10
Reviewed tip: `25ba37dd`
Prior review: `.collab/research/friction-cn-reconciliation-review.md`

## Verdict

**PASS.** R1-R3 are fully corrected. Strict B098 authority and the
I003/I004/I007/I008 deferrals remain correct. The reconciliation is fit for
implementation dispatch under its stated dependencies and completion gates.

## R1 — ownership/disposition of the seven rows

### Result: PASS

F5d now explicitly owns B071; Q1 owns B076-B077, B183-B184, and B210; ADR0
owns C036-C046, especially C046. Mechanical expansion confirms that all 285
non-closed/non-boundary T0 rows now occur in the bounded-slice or explicit
disposition sections; the prior seven-ID omission is gone.

The semantic proof check passes for both connector rows:

- B071 now maps to F5d, which explicitly requires a positive two-host connector
  bridge smoke proving the working/honest bridge. That is the required proof.
- T0 B210 says a broken bridge must fail loudly, not silently, and requires a
  full connector failure regression.
- Q1 maps B210 and explicitly requires the full connector negative failure
  regression, clear stderr, and non-zero relay-error behavior.

The other six repairs are sufficient:

- B076-B077 and B183-B184 have a command-wide parse, exit-taxonomy, non-zero
  relay-error, and stderr-snapshot matrix in Q1.
- B071 has the positive connector-mode two-host receipt in F5d.
- B210 has the negative full connector failure regression in Q1.
- C046 has ADR0's decision ledger, link validation, and irreversible-protocol
  gate.

## R2 — exclusive or serialized test/manifest ownership

### Result: PASS

The repair successfully makes these boundaries explicit:

- H0 uses the already registered `test_relay_remote_broker.ml` and forbids a
  dune-manifest edit.
- F5a is sequenced after J1 and owns the next `ocaml/test/dune` manifest commit.
- H5 follows H4, owns an exclusive relay-state test module, and acknowledges
  H4's test-manifest commit.
- H6 follows H5 and owns an exclusive list-relay test module.

The ordered start set now explicitly serializes every shared-manifest owner as
H4 -> J1 -> H5 -> H6 -> F5a unless a slice proves it needs no manifest edit.
This removes the remaining H4/J1 collision while preserving the other fixed
boundaries.

One implementation caveat is non-decisive for this narrow review:
`test_relay_remote_broker.ml` currently tests unrelated remote-broker path
parsing. It is technically an available registered executable, but H0 should
avoid deleting its existing regressions while adding signed peek ownership
coverage.

## R3 — B098 finding status consistency

### Result: PASS

The finding now says **“Decision resolved; implementation open,”** links
`friction-cn-b098-decision.md`, identifies the direct operator request plus
critical backlog B098 as authority, marks H1 unblocked, and records rejection
of the remote-supervisor RPC contract. It no longer contradicts the
reconciliation.

## Strict-authority and deferral regression check

### Result: PASS

- B098 still selects host-local verdict-file/CLI resolution. Configured and
  unconfigured supervisor inbox/relay messages remain inert under H1's required
  proof. No peer message gains approval authority.
- H0 remains limited to peek authorization; durable cursors, acks, independent
  consumer progress, waits, receipts, and push remain I004-deferred.
- H2 remains the accepted B099 safety-framing subset, not I007 adapter
  unification or I003 trust enforcement.
- H6 still distinguishes current identity kinds without inventing I008
  attestation or verified-agent semantics.
- The explicit I003, I004, I007, and I008 disposition rows are unchanged in
  substance. Stale I006 remains split rather than activated.
- ADR0 records deferred choices and forbids protocol changes; it does not
  activate I004.

## Attempted criticisms and validators

| Attempt | Result |
|---|---|
| The seven IDs might still be mechanically absent. | Rejected: 285/285 non-closed/non-boundary rows are now mapped; missing set is empty. |
| F5d might now fully satisfy B071. | Rejected as criticism: it explicitly owns the positive two-host connector bridge smoke. |
| B210 might still be attached to the positive-only F5d proof. | Rejected: tip `25ba37dd` restores B210 to Q1 and names the full negative connector failure regression. |
| J1/F5a might still collide. | Rejected: F5a is explicitly chained after J1 and owns the next manifest commit. |
| H4/H5/H6 might still collide with one another. | Rejected: they are serialized H4 -> H5 -> H6 with exclusive test modules. |
| H4/J1 might still collide. | Rejected: the shared lane explicitly serializes H4 -> J1 -> H5 -> H6 -> F5a. |
| The B098 finding might still preserve the old authority blocker. | Rejected: status and link now match the selected strict contract. |
| The repairs might have activated deferred futures. | Rejected by the explicit scopes, prerequisites, and unchanged disposition table. |

Validators:

- Direct diff review through `25ba37dd` for the reconciliation and B098
  finding.
- Mechanical non-closed-row expansion: 285 required, 285 mapped, zero missing.
- Direct comparison with T0 B071/B076/B077/B183/B184/B210/C046 proof fields.
- Direct inspection of `ocaml/test/dune` and the existing H0 test executable.
- Authority/deferral comparison against B098 and I003/I004/I006/I007/I008.

No code changed in this repair, so no build was required for this narrow
research-artifact review.

No prior R1-R3 blocker remains at the reviewed tip.
