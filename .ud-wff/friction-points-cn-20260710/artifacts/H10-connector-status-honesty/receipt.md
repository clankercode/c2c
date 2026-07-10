# H10 output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-h10-connector-status-honesty`
- Tip: `798461c7` (single commit: fix + tests + changelog). Base `051cf896`
  (H9 reviewed tip). Fixes Q1-DEFECT-1, the FOURTH run-discovered
  production defect: connector inline Relay_client discarded HTTP status →
  `relay connect --once` vs dishonest 500+ok:true = false success.
- **Fix**: `reconcile_status ~status body` (c2c_relay_connector.ml:626)
  ports H7's four-branch contract into the inline client: 2xx byte-identical
  passthrough; non-2xx honest ok:false annotated http_status (PoW/rate-limit
  429 flows preserved — pinned empirically); non-2xx dishonest overridden
  http_error_<code> with body under relay_response; transport unchanged,
  never raises. classify_error maps http_error_<n> → "other" (bounded
  retry→DLQ on sends; per-op errors on register/poll; --once exit 2 B087).
- **Item-5 hardening included**: member_or_null totalizes json_bool_member/
  json_list_member/response_is_rate_limited/response_is_pow_retry_failed/
  classify_error on non-object responses (identity on objects);
  test_connector_non_object_response_start_once repinned exit-1-exception →
  exit-2 per-op error (the only changed expectation; old one encoded the
  crash).
- **Red→green**: 4 new cells in test_relay_test_support.ml "connector
  status honesty (H10)" group; RED at base captured verbatim
  (registered ["f5c-sm-probe"] vs [], delivered 1 vs 0). Suite 21→25.
- **H9 interaction intact**: dishonest non-2xx poll refused at response
  layer — delivered=0, cs_inbound_rejected NOT inflated (rows never reached
  H9's validator); garbage-row cells unchanged green.
- **E2E**: reviewer reproduced the fix themselves — loopback 500+ok:true
  relay, real c2c.exe, exit 2, registered=[], http_error_500 envelope in
  connector-state.json, B087 stderr.
- Live peer-PASS (independent opus reviewer, not author or its subagent):
  PASS first pass. Evidence IN slice worktree: reviewer's own
  `DUNE_WATCHDOG_TIMEOUT=900 just check` rc=0; suites 2x (support 25,
  connector 24, mcp 412); 6 decisive criticisms attempted, all refuted
  (incl. ws-path audit, DLQ-storm, duplicate-ok-key exploit). Signed
  artifact `798461c7-fable-warden.json` (v2, build_rc=0, all targets).
- Post-merge follow-up: verify Q1's runtime FIXME cell
  (test_FIXME_dishonest_500_ok_true_is_treated_as_success) flips to
  enforcing-green on master once H10 + Q1 lanes are both merged.
- Carried: pre-existing Warnings 8/26 in c2c_relay_connector.ml untouched.
