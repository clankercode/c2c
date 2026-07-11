# Q1 output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-q1-cli-error-contract`
- Tips: `806f0df9` (audited merge of J3 reviewed tip 333923f2 — dune
  module-list union via rerere, verified only-conflict) + `5c248451`
  (matrix, the slice's only owned file) + `4e1665ed` (cs_node_id fixture,
  1-line cross-lane compile fix). Base `5c2d79b1` (H7 reviewed tip). Worker
  was cut mid-slice by a session limit and resumed cleanly from transcript.
- **Matrix**: `tests/test_c2c_cli_error_contract.py` (738 lines) — 31
  methods (30 pass + 1 runtime FIXME-skip) + 68 subtest cells. Hermetic:
  env dict-literal from scratch (never os.environ), temp HOME/broker root,
  non-git cwd, loopback-only scripted fault relay (race-safe stdlib
  http.server). Tier-gate detector skips hidden commands cleanly.
- **Pinned exit taxonomy**: 0 = success + contracted degrades (`doctor
  --json` outside repo degraded:true; `list --relay` loud local-only
  fallback — documented exception to "relay errors never exit zero",
  pre-pinned in test_c2c_list_relay.ml, cross-referenced); 1 = per-op/
  semantic incl. ALL relay client errors + `doctor --relay` any-fail;
  2 = send positional self-validation, wait-inbox bad --timeout,
  `relay connect --once` sync-with-errors (B087); 124 = cmdliner parse
  errors with Usage stderr. Assertions tight (exact code + message needle
  + ok-trap); reviewer proved a 124→1 or 500-ok:true→exit-0 regression
  would be caught, and that subtest failures fail the suite (pytest 9
  native unittest.subTest — probed RC=1).
- **H7 pinned from outside**: dishonest 500+ok:true → relay dm send/
  register/status exit 1, error_code http_error_500, http_status 500,
  body under relay_response.
- **FOURTH DEFECT (Q1-DEFECT-1), pinned NOT fixed**: connector inline
  Relay_client (c2c_relay_connector.ml:661 on this branch) discards HTTP
  status → `relay connect --once` vs dishonest 500 = false success
  (exit 0, registered=2). Runtime FIXME-skip
  `test_FIXME_dishonest_500_ok_true_is_treated_as_success` auto-enforces
  when fixed (reviewer verified flip both directions empirically). Fix
  slice H10 dispatched on H9's lane. Finding doc
  `2026-07-10T12-17-07Z-q1-worker-connector-dishonest-500-false-success.md`
  (worktree + main checkout; LOW: prose says ~577, defective line is 661).
- Live peer-PASS (independent opus reviewer, not author or its subagent):
  PASS first pass. Evidence IN slice worktree: reviewer's own
  `DUNE_WATCHDOG_TIMEOUT=900 just check` rc=0; python suite 2x serialized
  (30/1skip/68 subtests); 7 empirical spot-checks against the built
  binary. Signed artifact `4e1665ed-fable-warden.json` (v2, build_rc=0,
  all targets).
- Carried: `just build` doesn't compile test executables (full-tree breaks
  surface only at `just check`); `c2c doctor` resolves its script via
  cwd's git toplevel (hermetic tests need non-git cwd); python suite
  flakes if run concurrently with a dune build of the same worktree;
  unregistered `c2c send` auto-registers by design.
