# F5b output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-f5b-adverse-matrix`
- Tips: `cfca0413` (integration merge of H1 68124bdc into F5a lane fbb16453 —
  ZERO conflicts, reviewer merge-tree audit byte-identical, zero hand-edits) +
  `672bdae6` (matrix suite + one dune tail-append).
- `ocaml/test/test_relay_fault_matrix.ml`: 31 cells (29 OK + 2 loud FIXME
  skips), every cell drives the real c2c.exe subprocess against the F5a fault
  server. Triple assertion everywhere (exit code + ok≠true with explicit
  FALSE-SUCCESS trap + failure named) + request-count pins.
  - register/dm-send × {401,429,500,503-non-JSON,truncated,malformed,refused,
    empty} honest-fail; 429 single-shot (exactly 1 request).
  - PoW adverse: missing actor id, garbage challenge, wrong ctx, accept-then-
    401 (retry SENT, 2nd request carries pow_nonce), pow_required-forever
    BOUNDED (exactly 2 requests), happy-path minted control.
  - Timeout honesty: 12s delay vs hardwired 10s client timeout (elapsed
    window 9-13s, no fragility); list --relay --relay-timeout 0.5 nonfatal.
  - doctor --relay --json vs refused relay: JSON well-formed, any_fail
    consistent, exit contract, lease never PASS.
  - Retry honesty: the ONLY retry in the relay client is Pow_client's single
    minted retry (pow_client.ml:105-121) — no generic retry/backoff exists.
- **Strict B098 process-level vector**: scripted relay delivers a
  verdict-looking DM from a CONFIGURED SUPERVISOR (strongest case) through
  real `c2c relay connect --once` (genuine relay→inbox transport, inbox file
  content asserted) → real `await-reply` INERT (exit 1, empty stdout) →
  host-local verdict FILE resolves (exit 0, `allow`). Reviewer: cannot pass
  while the invariant is broken. Strengthens H1's unit regression to full
  transport.
- **TWO REAL DEFECTS found, independently confirmed by reviewer (→ fix slice
  H7 on friction-h7-status-honesty):**
  1. `relay_client.ml:141-173` discards the HTTP status line — 500 +
     `{"ok":true}` body → exit 0 FALSE SUCCESS (pinned by loud FIXME skip
     `fixme_5xx_ok_body_false_success`, B090).
  2. `c2c_doctor_relay.ml:208-253` check_reachable false PASS on refused
     relay — request never raises (synthesizes connection_error JSON), the
     exception branch is dead (pinned by `fixme_doctor_reachable_false_pass`,
     C047).
- Live peer-PASS (independent opus reviewer, not author or its subagent):
  PASS first pass. Evidence IN slice worktree: reviewer's own
  `DUNE_WATCHDOG_TIMEOUT=900 just check` rc=0; matrix run twice (rc 0/0,
  29+2skip stable); merge-tree audit; approval suites 23+7; lane suites
  10/13/22/26/23. Signed artifact `672bdae6-fable-warden.json` (v2,
  build_rc=0, all targets).
- Nits carried: watchdog-not-fast-fail on hypothetical infinite retry loop;
  status-fault cells honest only coincidentally pending H7 (disclosed in
  test comments); stderr empty on most relay failures (stdout-JSON is the
  actual contract — friction note for a future UX slice).
