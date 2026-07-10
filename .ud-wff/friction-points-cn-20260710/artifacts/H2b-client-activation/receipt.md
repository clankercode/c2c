# H2b output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-h2b-client-activation`
- Tips: `8430efc1` (opencode TS renderer) + `9b67ed36` (broker room envelopes) +
  `39786891` (adapter hostile-vector tests). Base `4df6f381` (H2a peer-PASSed tip,
  chain-slice).
- OpenCode plugin: TS `xmlEscape` with exact char-set + order parity vs OCaml
  `xml_escape` (& first); `from`/`to`/`content` escaped in `formatEnvelope`;
  `safeFrom` composes xml-escape then reminder-literal escape; untrusted-data
  line in DM + room hints; embedded ML regenerated, drift-rc=0; python static
  guards on BOTH TS source and generated ML.
- Codex hook: already routes through H2a-safe `format_c2c_envelope`; new e2e
  hostile-vector test through real `c2c hook codex`.
- Claude MCP channel-push + Kimi notification store: safe-by-structure
  (structured JSON fields, not markup concatenation) — pinned by tests asserting
  verbatim (non-double-escaped) round-trip + untrusted-data reminder.
- Broker room-invite/room-knock auto-DMs: extracted pure render helpers that
  xml_escape alias AND room_id; both send sites rewired; tests assert
  neutralisation + exactly one real `</c2c>`.
- No `ocaml/test/dune` or `ocaml/cli/dune` edits (dune manifest lane untouched).
- Live peer-PASS (independent opus reviewer, not author or its subagent):
  PASS first pass. Evidence IN slice worktree: reviewer's own `just check` rc=0,
  room_handlers 29/29, mcp 412/412, start 195/195, kimi 25/25, hook_codex 12/12,
  pytest HostileSafe 2/2, codegen drift-rc=0. Coordinator's own `just check`
  rc=0 pre-review. Signed artifact `39786891-fable-warden.json` (v2, build_rc=0,
  all targets).
- Merge-coordination note (for coord at merge time): H1 (`68124bdc`) edits the
  adjacent region of `opencode-c2c/c2c.ts`; H1's diff carries the OLD unescaped
  `formatEnvelope` return line as context. Merge resolution MUST keep H2b's
  escaped return + hint lines AND H1's `trackPendingPermission` /
  `surfaceAdvisoryMessage`. Semantically orthogonal; `surfaceAdvisoryMessage`
  calls `formatEnvelope` so it inherits escaping.
- Non-blocking follow-up: `peer_offline` self-closing envelope (broker.ml:3072)
  unescaped but injection-safe (enum/float/charset-validated alias); could route
  through xml_escape for uniformity.
- Out-of-scope pre-existing defect flagged by worker:
  `tests/test_c2c_oc_plugin.py::StartOpencodeRefreshParityTests::test_start_opencode_refresh_writes_shared_c2c_cli_command`
  is non-hermetic (spawns `c2c start opencode`; real repo broker fingerprint wins
  over temp env root). Not touched in this slice.
- tmux four-client live validation: excluded per slice scope (coordinator
  handles separately before merge/deploy).
