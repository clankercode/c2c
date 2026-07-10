# J3 output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-j3-monitor-ndjson`
- Tips: `20258f5a` (integration merge) + `7e31c1a6` (NDJSON v1 adaptation) +
  `333923f2` (peer-review fix, coordinator-authored NEW commit).
  Bases: `5fae138d` (H3 tip) with `daa9bc83` (J1+H4 lane) merged — both
  peer-PASSed ancestors of HEAD.
- **Integration merge `20258f5a`** (in scope, reviewed): parents exactly
  5fae138d + daa9bc83; reviewer's merge-tree audit found exactly ONE hand-edit
  — `cs_node_id = None` added to H4's doctor-capabilities connector_state
  fixture (H3 introduced the field; None is the neutral pre-H3 shape). This is
  the H3×H4 `cs_node_id` integration point flagged at H3/H4 close — now merged
  and green (doctor 23/23, monitor_logic 36/36, connector 24/24,
  schema_v1 after J3: 35/35). Worker's reset-and-redo of its own unpublished
  auto-merge commit judged acceptable (not an amend of any reviewed SHA).
- **J3 change**: new `ocaml/c2c_monitor_ndjson.ml` (c2c_mcp lib) —
  `message_event` builds typed C2c_schema_v1.t, serializes via the module,
  appends legacy keys filtered against v1 keys (source-once pinned + reviewer
  empirically reproduced); `emit_line` = compact object + newline + flush per
  event (both invariants pinned by tests; multiline content JSON-escaped to
  one physical line, empirically confirmed). Both emission sites (archive
  `emit` + `--live` inline) routed through the module; old inline spreads
  deleted. B070/B089 dedup runs on raw messages BEFORE shaping (ordering
  verified at c2c_monitor_cmd.ml:630-631). H3 behavior (exit-3, error honesty,
  local+relay single stream) untouched. Only behavior delta: `--live --json`
  now emits additive `source:"local"` (archive path already emitted source;
  no reader can key on absence).
- **Fix `333923f2`**: `room_of_fields`'s '#'-suffix path gated by canonical
  `C2c_mcp_helpers.is_room_recipient` (J4 finding-6 family) — host-hash
  `<alias>#<12hexhash>` emits type:dm (reviewer re-ran repro: was type:room at
  7e31c1a6, now dm; room fanout still room; non-hex 12-char suffix still room;
  empty room_id falls through). New pin test; schema_v1 35/35.
- Tests: 9 J3 cases in test_c2c_schema_v1.ml "monitor-ndjson (J3)" section
  (placement justified: cli/dune's monitor_logic stanza does not link c2c_mcp
  and manifests were frozen — reviewer verified factually). Docs:
  monitor-json-schema.md + gui-architecture.md; reviewer built a throwaway
  emitter and got byte-identical lines to the doc examples.
- Live peer-PASS (independent opus reviewer, not author or its subagent):
  PASS at 7e31c1a6 (reviewer's own just check rc=0
  = build-clean-IN-slice-worktree-rc=0; suites 36/24/23/34) with one
  non-blocking same-family issue; coordinator fix 333923f2 (new commit);
  same reviewer delta re-review extended PASS (own build rc=0, 35/35).
  Signed artifact `333923f2-fable-warden.json` (v2, build_rc=0, all targets).
- Nit carried (non-blocking): add an explicit multiline-content one-line
  NDJSON test (invariant currently guaranteed by Yojson + empirically checked).
- Out-of-scope (recorded as run issue, not fixed): tests/test_c2c_monitor.py
  8/9 pre-existing failures in this environment (verified with pre-J3 binary)
  — owner triage needed.
