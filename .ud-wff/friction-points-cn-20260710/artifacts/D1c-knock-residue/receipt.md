# D1c output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-d1c-knock-residue`
- Tips: `3a0bbcc1` (purge) + `12119367` (peer-review fix, coordinator-authored
  NEW commit). Base `c8d5e7c9`.
- Purged the phantom `c2c relay rooms knock/knocks/approve-knock/deny-knock`
  CLI family from: docs/llms.txt, root llms.txt (in-family extension,
  reported + accepted), docs/commands.md (prose note + the pipe-delimited
  summary-row enum at :1084 — fix commit), and
  docs/c2c-research/relay-rooms-spec.md (route-form + as-shipped marker at
  ~240-247, plus §8 CLI table replaced with an explicit
  design-intent-never-shipped note — fix commit).
- Real surfaces documented truthfully: signed relay routes (/knock_room,
  /list_room_knocks, /approve_room_knock, /deny_room_knock in relay.ml),
  MCP room tools (c2c_mcp.ml), and the REAL local `c2c rooms knock` family
  (preserved, affirmatively cross-referenced — never denied).
- Review cycle: initial opus review FAIL (two missed loci — the pipe-enum
  form evaded the literal grep, and spec §8 self-contradicted the new note);
  coordinator fix `12119367`; same reviewer delta re-review PASS (re-ran both
  literal and pipe-form greps; enum matches binary help verbatim; notes
  mutually consistent).
- Residual accounting (verified by reviewer via git grep on sibling tips):
  docs/connect.md fixed at D1 tip 43cac304; docs/relay-quickstart.md fixed at
  D1b tip 33e08705. Zero phantom references remain anywhere once all branches
  merge.
- Live peer-PASS (independent opus reviewer, not author or its subagent).
  Evidence IN slice worktree: reviewer's own
  `DUNE_WATCHDOG_TIMEOUT=900 just check` rc=0
  (build-clean-IN-slice-worktree-rc=0; docs-only delta reuses it). Signed
  artifact `12119367-fable-warden.json` (v2, build_rc=0, all targets).
