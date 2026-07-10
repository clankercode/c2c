# H9 output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-h9-connector-row-validation`
- Tips: `06547cb3` (connector validation) + `051cf896` (broker load_inbox
  totality). Base `812d7f34` (F5c reviewed tip). Fixes the THIRD production
  defect (F5c-confirmed): connector delivered schema-garbage poll rows
  verbatim → one poisoned row wedged all broker-side inbox reads.
- **Connector half**: `inbound_row_is_deliverable` validates each poll row
  before local-inbox append — EXACT field-by-field mirror of what
  `message_of_json` requires (string from_alias/to_alias/content; all other
  fields optional-with-default). Invalid rows dropped + counted in NEW
  `cs_inbound_rejected` (connector-state JSON + sync printfs); `last_error`
  records "dropped N schema-invalid inbound row(s) of M for <alias>:
  [truncated sample]"; `--once` exits 2 via existing B087 per-op-error path.
  All-garbage batch: delivered=0, no inbox file created. `messages`
  wrong-type/empty: unchanged lenient behavior. Happy path behaviorally
  identical (order-preserving partition).
- **Broker half (defense-in-depth + healing)**: `load_inbox` now total
  per-row — malformed rows skipped via filter_map (order preserved), each
  emitting cataloged `inbox_row_skipped` broker.log event; pre-poisoned
  inbox files now load; drain→save rewrites parsed rows only (heals).
  Read path deliberately non-mutating (event re-fires until rewrite).
- **Red→green**: F5c loud-SKIP cell → `test_connector_poll_garbage_rows_dropped`
  (RED at base: delivered 3 vs 1) + new `test_load_inbox_skips_malformed_rows`
  (RED at base: Type_error through whole inbox). Suites: support 21+0skip,
  connector 24, mcp 412 — reviewer ran each twice, stable.
- Scope: c2c_relay_connector.ml + c2c_broker.ml production; 4 test files
  (2 are 2-line constructor updates for the new field); catalog runbook.
  NO dune edits; relay_client.ml / c2c_doctor_relay.ml untouched (H7 scope).
- Live peer-PASS (independent opus reviewer, not author or its subagent):
  PASS first pass. Evidence IN slice worktree: reviewer's own
  `DUNE_WATCHDOG_TIMEOUT=900 just check` rc=0; 8 decisive criticisms
  attempted, all refuted (incl. validator strictness both directions,
  ordering, raw-reader audit — only 2 message_of_json callers, DLQ already
  guarded). Signed artifact `051cf896-fable-warden.json` (v2, build_rc=0,
  all targets).
- Carried (nonblocking): validator is a hand-maintained mirror of
  message_of_json (drift mitigated by comment + broker net); connector's
  INLINE Relay_client (c2c_relay_connector.ml:577) still has the H7
  body-over-status defect — recorded as run issue, adjudicate at J5/Q1
  (possible H10 or unification).
- Worker out-of-scope report: `response_is_rate_limited` non-object
  hardening is NOT a 2-3 line fix (three sibling helpers raise on the same
  input); coherent follow-up slice documented.
