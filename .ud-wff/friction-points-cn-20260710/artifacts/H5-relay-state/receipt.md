# H5 output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-h5-relay-state`
- Tips: `1e264e2b` (classifier + renderers) + `aad5c1b1` (tests + docs).
  Base `daa9bc83` (J1 peer-PASSed tip — dune lane H4→J1→H5→H6→F5a).
- Pure classifier `ocaml/relay_state.ml`(.mli): total state machine over
  relay-config/identity/alias/registration-evidence/connector-liveness inputs.
  Six states: the five required (unconfigured, configured_not_registered,
  registered_live, registered_expired, registered_unreachable) plus
  `configured_unverified` — an honest-unknown reachable ONLY when the relay was
  not successfully queried, so it never masks a required state. Precedence:
  unconfigured dominates; expired lease dominates connector state; both
  unreachable legs (lease-alive-connector-down vs query-failed-with-evidence)
  distinguished in reason strings.
- Connector liveness single-sourced from `Relay_doctor.connector_running`
  (H4's broker-owned signal, relay_doctor.ml UNMODIFIED) — status and doctor
  cannot disagree; agreement pinned by direct-equality tests.
- Renderers (`ocaml/cli/c2c_relay_state.ml`, shared by status/whoami/health):
  old conflated `registered: <alias> (current session alias)` line replaced by
  `alias: ... (local session alias — not a relay registration)` + new `state:`
  and `connector:` lines. JSON strictly additive: `relay.registration
  {state,reason}` + `relay.connector {live,state_file,last_sync_age_s}`;
  pre-existing keys unchanged; repo-wide grep found no consumer of the old
  label.
- Tests: exclusive `ocaml/test/test_c2c_relay_state.ml`, 22 cases — all six
  states, both unreachable legs, expired reserved/released, lease-JSON
  round-trip vs real RegistrationLease.to_json, malformed-lease totality,
  connector fresh/stale/absent with Relay_doctor equality asserts, pinned
  state-string contract, human/JSON parity (exact state-string embedding, not
  presence-only), hermetic E2E whoami json-vs-human incl. old-label-gone
  assert. Dune-lane: pure trailing append below J1's stanza.
- Docs: `docs/commands.md` relay-state section; reviewer verified verbatim
  human/JSON examples byte-for-byte against hermetic runs.
- Live peer-PASS (independent opus reviewer, not author or its subagent): PASS
  first pass. Evidence IN slice worktree: reviewer's own
  `DUNE_WATCHDOG_TIMEOUT=900 just check` rc=0
  (build-clean-IN-slice-worktree-rc=0); suite 22/22 + lane siblings
  schema 26/26, doctor 23/23. Signed artifact `aad5c1b1-fable-warden.json`
  (v2, build_rc=0, all targets).
- Nits: abbreviated docs human example (shown lines verbatim-correct);
  lease field-name coupling covered by roundtrip test.
- Tooling issues recorded (run log IssueRecorded, not fixed here):
  `just check` dune-watchdog default 60s rc=124 on cold worktrees
  (workaround DUNE_WATCHDOG_TIMEOUT=900); bare `dune` on PATH is not the opam
  switch's dune. Pre-existing warnings list left untouched.
