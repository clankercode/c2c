# F5c output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-f5c-schema-faults`
- Tip: `812d7f34` (single commit, 2 test files, +672/−4, NO dune edits,
  NO production code). Base `fbb16453` (F5a tip).
- **Schema-mismatch vectors** (honest-failure pinning, concrete non-effects
  asserted — alias NOT registered, zero delivered, no inbox file, exit 1 +
  connector-state last_error): Relay_client malformed/truncated/non-object;
  connector register ok-wrong-typed / ok-missing; poll messages-wrong-typed
  (lenient-ignore, zero delivered); connector start --once exit-1 surface;
  Relay_state lease wrong-types never classify live (B120); error-hint
  totality; 4 pure C2c_schema_v1.validate wrong-kind cases (suite 26→30).
- **Fake/real vector equality** (9 vectors, F5a scripted server vs production
  Relay_server(InMemoryRelay), pow-off/dev-auth): register-ok/bad,
  send-ok/duplicate/unknown-alias, poll-full/empty, health, list.
  Normalization is TYPE-CHECKED (ts scrubbed only if numeric, git_hash opaqued
  only if string — a fake serving "ts":"soon" FAILS); deterministic vectors
  compared byte-exact after key-sort; reviewer confirmed it catches fixture
  drift (missing/extra keys mismatch). Pins that the F5b matrix's scripted
  faults are meaningful.
- **THIRD REAL DEFECT found, reviewer-confirmed EMPIRICALLY both halves
  (→ fix slice H9 on friction-h9-connector-row-validation):** connector
  delivers schema-garbage poll rows verbatim (c2c_relay_connector.ml:1065-67;
  inbound_delivered=1, last_error=None, row written to inbox file) and
  downstream C2c_broker.message_of_json (c2c_broker.ml:327) raises Type_error
  which load_inbox (c2c_broker.ml:1854) propagates over the WHOLE file — one
  poisoned row wedges all broker-side inbox reads for the session.
  Severity medium-high confirmed. Pinned as loud SKIP (reason in test title)
  + FIXME + finding doc
  `.collab/findings/2026-07-10T08-29-20Z-f5c-worker-connector-garbage-inbox-rows.md`
  (mirrored to main checkout so it survives worktree GC).
- Live peer-PASS (independent opus reviewer, not author or its subagent):
  PASS first pass. Evidence IN slice worktree: reviewer's own
  `DUNE_WATCHDOG_TIMEOUT=900 just check` rc=0; suites run twice each
  (support 20+1skip / schema 30 / list_relay 13, stable); 6 vectors
  spot-checked for concrete non-effects; Lwt/fork ordering judged sound
  (child exits via Unix._exit, engine state inert). Signed artifact
  `812d7f34-fable-warden.json` (v2, build_rc=0, all targets).
- Out-of-scope carried: response_is_rate_limited unguarded Util.member can
  abort a whole sync pass on non-object response (H9 brief includes an
  if-cheap guard); messages-wrong-type silent tolerance could gain a debug
  log; row-ID mappings best-effort (reconciliation table not in-tree).
