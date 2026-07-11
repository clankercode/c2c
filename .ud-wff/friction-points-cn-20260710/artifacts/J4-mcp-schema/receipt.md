# J4 output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-j4-mcp-schema`
- Tips: `222b5425` (serialize_with_legacy helper + J1 nit carry) + `d0b50297`
  (MCP adaptation) + `3a93bcd4` (peer-review finding-6 fix, coordinator-authored
  NEW commit). Base `daa9bc83` (J1 peer-PASSed tip, chain-slice).
- MCP `send`/`poll_inbox`/`peek_inbox` results now emit the canonical v1 shape
  constructed as typed `C2c_schema_v1.t` and serialized via the module's new
  `serialize_with_legacy` (v1 keys canonical, legacy keys appended additively;
  collision risks avoided by removing legacy `ts` and moving `content` to
  v1-only — reviewer per-site collision analysis clean, no duplicate keys).
- Legacy consumers verified unbroken: opencode plugin Msg fields, connector
  message_of_json, c2c_deliver_inbox.
- Representation-only: poll decrypts + delivery=delivered, peek raw wire +
  delivery=queued, send receipt queued — all faithful to pre-J4 behavior.
- `source` omitted everywhere (transport origin not reliably inferable —
  broker assigns message_id at LOCAL enqueue, c2c_broker.ml:2376; reviewer
  verified). Room rows: type=room via canonical
  `C2c_mcp_helpers.is_room_recipient` (fix 3a93bcd4 replaced the naive '#'
  check; `<alias>#<12hexhash>` host-hash form pins as DM; 417/417).
- Tool descriptions reference message-schema-v1, per-surface delivery.state,
  untrusted-content caveat (H2a/H2b-consistent); pinning test asserts key
  phrases (reviewer: not vacuous). No generated/duplicated description
  surfaces exist; this test is the drift gate.
- J1 review nit carried: .mli + schema doc now distinguish reserved KEYS
  (ignored) from the `read` enum VALUE (rejected).
- No dune manifest edits; forbidden files untouched (verified by reviewer via
  diff stat).
- Live peer-PASS (independent opus reviewer, not author or its subagent):
  PASS at d0b50297 (reviewer's own just check rc=0, mcp 416, schema 27) with
  one non-blocking finding; coordinator fix `3a93bcd4` (new commit, never
  amend); same reviewer delta re-review extended PASS to 3a93bcd4 (own build
  rc=0, 417/417, no shadowing, single canonical definition). Signed artifact
  `3a93bcd4-fable-warden.json` (v2, build_rc=0, all targets).
- Follow-ups recorded (not fixed here): MCP `history` tool rows not on v1
  (unowned by any J slice — J5 gate must adjudicate scope); stale
  `c2c_mcp_helpers.ml:96` comment claiming message_id is relay-only
  (H2-owned file); relay room fan-out hand-rolls legacy inbox row shape at
  rest (broker inbox JSON deliberately untouched by J4).
