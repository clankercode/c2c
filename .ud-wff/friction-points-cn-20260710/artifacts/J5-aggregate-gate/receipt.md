# J5 output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-j5-aggregate-gate`
- Tip: `a9887a34`. Base `812d7f34` (F5c reviewed tip). Commits: 3 audited
  integration merges — `8ca96893` (J3 333923f2, brings H3), `3a8332f0`
  (J4 3a93bcd4), `d2ccb6ab` (J2 7917e363) — + `1fdc2bfa` (cs_node_id
  cross-lane fixture fix, test-only) + `a9887a34` (unification + gates +
  docs).
- **Merge audit (reviewer)**: all three merges faithful unions, verified by
  `git merge-tree --write-tree` reconstruction + test_case arithmetic
  (schema_v1 suite 26 → +4 F5c +9 J3 +1 J4 → 40 at merges, 44 at tip).
  Hand-resolutions: ocaml/dune module-list union (J3 merge); additive
  test sections both kept (J3+J4 merges); message-schema-v1.md scope note
  combined J1-J5 landing notes (J2 merge). Tip signatures from all three
  reviewed tips confirmed present. No conflict markers anywhere.
- **J2↔J4 unification closed** (TODO at c2c_utils.ml:11):
  `C2c_utils.schema_v1_with_legacy` DELETED; `C2c_schema_v1.serialize_with_legacy`
  extended (`?delivery_extra`) absorbing J2's exact algorithm — v1-wins
  dedup, delivery_extra merged inside `delivery` filtered against dfields
  (state can never be clobbered). MCP output byte-identical (zero key
  collisions between MCP legacy sets and v1 keys; neither MCP call-site
  passes delivery_extra). 4 CLI call-sites migrated. Byte-equality also
  captured empirically pre/post on real CLI+MCP surfaces.
- **Aggregate I002 gate**: both sides of the OCaml link boundary, NO dune
  manifest edits — `test_c2c_schema_v1.ml` group "aggregate-gate (J5/I002)"
  (MCP inbox_row_json / build_send_receipt / monitor message_event) +
  `ocaml/cli/test_c2c_utils.ml` group (CLI inbox rows, send receipts,
  relay dm ack/poll/peek). Every row: real production builder → validate
  Ok → serialize → re-validate identical + no-dup-keys (top level and
  inside delivery). Reviewer traced drift-catch concretely.
- **Docs**: surface-coverage table in docs/reference/message-schema-v1.md —
  adapted surfaces (producer+slice+gating test) AND 5 explicitly-NOT-adapted
  (MCP history rows, broker inbox at-rest, deliver_inbox NDJSON,
  relay poll-inbox prober, send_all envelope) each with reason + owning
  gate. Reserved-v2 table matches code (identity_pk/verified/trust_tier
  from-keys; priority; `read` state rejected). Cross-links
  message-schema-v1 ↔ monitor-json-schema ↔ commands closed, anchors
  resolve.
- Suite counts (reviewer, 2x): schema_v1 44, monitor_logic 36, c2c_utils 22,
  mcp 417, relay_state 22, doctor_capabilities 23. NOTE: this lane does NOT
  contain H1 or F5b/H7/H9 (approval 24 / await_reply 5 here is pre-H1 —
  confirmed `68124bdc` not an ancestor). Union happens at final master merge.
- Live peer-PASS (independent opus reviewer, not author or its subagent):
  PASS first pass. Evidence IN slice worktree: reviewer's own
  `DUNE_WATCHDOG_TIMEOUT=900 just check` rc=0. Signed artifact
  `a9887a34-fable-warden.json` (v2, build_rc=0, all targets).
- Carried: C2c_monitor_ndjson keeps its own legacy-append shaping
  (event_type/monitor_ts must PREPEND — shared helper can't express;
  documented in mli); transient MERGE_RR.lock collision during merge 3
  (known index-lock churn family, merge state intact); F5b/H7/H9 lane
  merges deferred to final master merge.
