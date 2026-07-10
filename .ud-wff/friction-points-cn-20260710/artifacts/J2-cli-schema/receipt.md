# J2 output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-j2-cli-schema`
- Tips: `7e98e07f` (helpers + vectors) + `be1c2cf2` (surface adaptation) +
  `7917e363` (docs). Base `aad5c1b1` (H5 peer-PASSed tip; contains J1+H4+H5).
- CLI `send`/`poll-inbox`/`wait-inbox`/`peek-inbox`/`relay dm send|poll|peek`
  `--json` results emit canonical v1 via new CLI-side
  `C2c_utils.schema_v1_with_legacy` (collision filter emits ts/content/
  message_id once; single delivery object merging v1 state + legacy warning;
  no duplicate keys asserted). Schema module deliberately untouched —
  MERGE-UNIFICATION TODO at c2c_utils.ml:11 vs J4's serialize_with_legacy
  (unify after both branches land).
- J-triple: queued = remote send + peek; delivered = local send + poll;
  accepted = relay ACK (+source:"relay" on relay surfaces only). Send receipt
  kept B088 legacy values (local=delivered/remote=queued) — reviewer verified
  AT BASE (git show aad5c1b1) that these delivery.state values pre-existed, so
  the deviation from J4's MCP send=queued is required by
  legacy-values-unchanged, not divergence.
- Room classification via canonical is_room_recipient (host-hash-is-DM
  pinned); send receipt hardcodes Dm (remote @host targets never hit the room
  classifier). Empty batches structurally unchanged ([] and
  {"ok":true,"messages":[]}); error/malformed relay rows pass through
  untouched; old-reader vectors on inbox + relay rows.
- Behavior unchanged: human output, sends, drains, exit codes identical; JSON
  key order changed on send receipt + relay dm (no order-sensitive consumer
  found in-tree).
- No dune manifest edits at all; tests in already-wired modules
  (test_c2c_utils 21, test_c2c_onboarding 19).
- Live peer-PASS (independent opus reviewer, not author or its subagent):
  PASS first pass. Evidence IN slice worktree: reviewer's own `just check`
  rc=0 (build-clean-IN-slice-worktree-rc=0); suites 21/19 + full
  cli+test runtest (194) clean; live temp-broker round-trip validated real
  emitted rows against the v1 contract. Signed artifact
  `7917e363-fable-warden.json` (v2, build_rc=0, all targets).
- Out-of-scope carried: c2c_deliver_inbox NDJSON shape unowned by any J slice
  (J5 must adjudicate with the history-tool gap from J4); send-all envelope
  (J4-owned file); `relay poll-inbox` prober prints raw relay JSON.
