# friction-points-cn closure — reviewed slice table (living doc)

Status as of 2026-07-10T19:15+10:00. Max instructed (mid-run): merge
peer-PASSed slices back into LOCAL master when done (push still gated —
flag readiness, don't push). All slices below have a REAL live
peer-PASS (independent opus reviewer, not the author or its subagent) with
`build-clean-IN-slice-worktree-rc=0` in the signed artifact
(`.c2c/peer-passes/<sha>-fable-warden.json`). No branch pushed —
coordinator1 gates all pushes.

| Slice | Branch | Base | Reviewed tip | Review cycle |
|---|---|---|---|---|
| H0 peek auth | friction-h0-peek-auth | c8d5e7c9 | 180eff1b | FAIL→fix→PASS |
| H1 strict approval (B098) | friction-h1-strict-approval | c8d5e7c9 | 68124bdc | BLOCKER→fixes→PASS |
| H2a safe renderer | friction-h2a-safe-renderer | c8d5e7c9 | 4df6f381 | PASS (+doc fix) |
| H2b client activation | friction-h2b-client-activation | 4df6f381 (chain H2a) | 39786891 | PASS first pass |
| H3 monitor truth | friction-h3-monitor-truth | c8d5e7c9 | 5fae138d | PASS |
| H4 doctor truth | friction-h4-doctor-truth | c8d5e7c9 | 43fbd5c2 | BLOCKER→fix→PASS |
| H5 relay state | friction-h5-relay-state | daa9bc83 (lane) | aad5c1b1 | PASS first pass |
| H6 list identity | friction-h6-list-identity | aad5c1b1 (lane) | 8b2c4c0c | PASS first pass |
| J1 schema core | friction-j1-schema-core | 43fbd5c2 (lane) | daa9bc83 | PASS (nit→J4) |
| J2 CLI schema | friction-j2-cli-schema | aad5c1b1 | 7917e363 | PASS first pass |
| J3 monitor NDJSON | friction-j3-monitor-ndjson | 5fae138d + merge daa9bc83 | 333923f2 | PASS→same-family fix→delta PASS |
| J4 MCP schema | friction-j4-mcp-schema | daa9bc83 | 3a93bcd4 | PASS→finding-6 fix→delta PASS |
| F101 self-update | friction-f101-self-update | c8d5e7c9 | 52fd2562 | PASS (cycle) |
| F5a fault infra | friction-f5a-fault-infra | 8b2c4c0c (lane end) | fbb16453 | PASS first pass |
| D1 connect golden path | friction-d1-connect-golden | c8d5e7c9 | 43cac304 | PASS first pass |
| D1b review follow-ups | friction-d1b-followups | c8d5e7c9 | dfae5aaf | PASS first pass |
| D1c knock residue | friction-d1c-knock-residue | c8d5e7c9 | 12119367 | FAIL→fix→delta PASS |
| ADR0 decision ledger | friction-adr0-decision-ledger | 050fd96c (reconcile) | 5d7822b7 | PASS first pass |
| F5b adverse matrix | friction-f5b-adverse-matrix | fbb16453 + merge 68124bdc | 672bdae6 | PASS first pass |
| F5c schema faults | friction-f5c-schema-faults | fbb16453 | 812d7f34 | PASS first pass |
| H7 status honesty (B090/C047) | friction-h7-status-honesty | 672bdae6 (chain F5b) | 5c2d79b1 | PASS first pass |
| H9 connector row validation | friction-h9-connector-row-validation | 812d7f34 (chain F5c) | 051cf896 | PASS first pass |
| J5 aggregate I002 gate | friction-j5-aggregate-gate | 812d7f34 + merges 333923f2/3a93bcd4/7917e363 | a9887a34 | PASS first pass |
| Q1 CLI error contract | friction-q1-cli-error-contract | 5c2d79b1 + merge 333923f2 | 4e1665ed | PASS first pass |

In flight: H10 connector inline-client status honesty (fixes Q1-DEFECT-1,
the 4th discovered defect; base 051cf896, tip 798461c7, reviewer running).
Q1's runtime FIXME cell auto-enforces once H10 + Q1 lanes merge — verify
the flip post-merge on master.

## Merge-order notes for coordinator

- Dune-lane chain merges in order: H4 → J1 → H5 → H6 → F5a (each contains
  its predecessors).
- J3 contains H3 + the (H4+J1) lane via its audited integration merge
  (cs_node_id fixture fix inside merge commit 20258f5a).
- F5b contains the lane + H1 via its integration merge (cfca0413).
- **Simplified final merge plan (lanes already union most branches):**
  J5 tip a9887a34 contains lane+F5c+J3(H3)+J4+J2+unification; H7 tip
  5c2d79b1 contains lane+F5b+H1+H7; H9 tip 051cf896 contains lane+F5c+H9;
  Q1 tip contains H7-lane + J3-lane. So master merge order: (1) J5 tip,
  (2) H9 tip (shares F5c base — mostly fast-forward-ish union), (3) H7
  tip (brings F5b+H1+H7; expect test_c2c_schema_v1/dune/docs context
  conflicts vs J5 — reuse J5's audited union resolutions), (4) Q1 tip
  (largely contained by then), (5) independent roots: H0 180eff1b,
  H2a→H2b chain 39786891 (c2c.ts coupling with H1 — keep BOTH H2b's
  escaped formatEnvelope+hints AND H1's trackPendingPermission/
  surfaceAdvisoryMessage), F101 52fd2562, D1 43cac304, D1b dfae5aaf,
  D1c 12119367, ADR0 5d7822b7. Approval/await_reply suite counts differ
  between lanes (H1 present vs not) — after the H7-lane merge expect
  approval 23(+H1 additions)/await_reply 7; run full just check after
  EACH merge into master.
- c2c.ts merge coupling: H1 (68124bdc) × H2b (39786891) touch adjacent
  regions — resolution MUST keep H2b's escaped formatEnvelope return + hint
  lines AND H1's trackPendingPermission/surfaceAdvisoryMessage (H2b receipt
  has details).
- J2×J4 post-merge unification TODO: fold C2c_utils.schema_v1_with_legacy
  onto J4's C2c_schema_v1.serialize_with_legacy (documented at
  c2c_utils.ml:11).
- test_c2c_schema_v1.ml edited by J3 (monitor section) and J4 (+1 vector) on
  parallel branches — merge is additive sections, expect clean or trivial.
- docs/commands.md edited by H5, H6, J2, J4, D1c on parallel branches —
  different sections; watch for context-line conflicts at merge.
- D1b changed justfile watchdog defaults (60→900, 9 recipes) — merge before
  relying on plain `just check` in cold worktrees.

## Cross-slice follow-ups (not blocking any slice)

- J5 must adjudicate: MCP `history` tool rows + c2c_deliver_inbox NDJSON +
  `relay poll-inbox` prober + send-all envelope — surfaces not on v1,
  unowned by J2/J3/J4.
- peer_offline self-closing envelope: xml_escape for uniformity (injection-
  safe today).
- monitor multiline-content one-line NDJSON explicit test (invariant held by
  Yojson; empirically confirmed).
- tests/test_c2c_monitor.py 8/9 pre-existing env failures — owner triage.
- test_relay_remote_broker pins a COPY of the /remote_inbox/ parser.
- test_pow_relay could migrate onto Relay_test_support_real.
- StartOpencodeRefreshParityTests non-hermetic (broker fingerprint wins over
  temp env root).
- `--global --relay` list labeling needs a broker-root-enumeration fixture.
