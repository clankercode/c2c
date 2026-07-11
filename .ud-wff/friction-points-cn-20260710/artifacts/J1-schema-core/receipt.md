# J1 output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-j1-schema-core`
- Tip: `daa9bc83` (single commit). Base `43fbd5c2` (H4 peer-PASSed tip —
  chain-slice for the serialized ocaml/test/dune manifest lane H4→J1→H5→H6→F5a).
- New pure module `ocaml/c2c_schema_v1.ml`/`.mli` (yojson only): canonical lean
  v1 message/event contract. Required: schema_version==1, type (dm|room|system),
  from.alias (non-empty), to, content. Optional: message_id, ts, from.host_id,
  from.address, source (local|relay), in_reply_to, delivery.state
  (queued|accepted|delivered). Unknown enum values REJECTED; unknown keys
  TOLERATED; reserved v2 keys (from.identity_pk/verified/trust_tier, top-level
  priority) ignored on parse, never emitted; delivery.state=read rejected
  (deferred to v2). Serialization omits absent optionals; roundtrip equality.
- Conformance: 26 alcotest vectors (valid/invalid-version/invalid-state/
  compatibility/optionality/missing-required), rc=0.
- Published doc `docs/reference/message-schema-v1.md` + linked from
  `docs/reference/index.md`; field table verified against code by reviewer.
- ocaml/test/dune: pure trailing append, J1 stanza LAST, directly below H4's —
  lane discipline confirmed byte-identical elsewhere. ocaml/dune: one-token
  modules-list insertion.
- Purely additive confirmed: no non-test code references C2c_schema_v1;
  send/poll/peek/monitor/MCP shapes untouched (J2/J3/J4 adopt it).
- Live peer-PASS (independent opus reviewer, not author or its subagent):
  PASS first pass. Evidence IN slice worktree: reviewer's own `just check` rc=0
  (build-clean-IN-slice-worktree-rc=0), schema suite 26/26. Coordinator's own
  `just check` rc=0 pre-review. Signed artifact `daa9bc83-fable-warden.json`
  (v2, build_rc=0, all targets).
- Nits carried forward (fold into J2): (1) .mli:11-18 prose + doc reserved-table
  header conflate reserved KEYS (ignored) with the read enum VALUE (rejected) —
  one-line clarification needed; (2) some invalid vectors assert is_err only;
  (3) cosmetic serialize fields-append style.
- Deferred (explicit): machine-readable JSON-Schema publication + CI drift gate
  (B036/B079); trust/identity fields + read receipts (A066/B216 — Max deferrals
  I003/I004/I008 preserved).
