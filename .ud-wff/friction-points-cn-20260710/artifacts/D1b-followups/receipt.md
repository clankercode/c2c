# D1b output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-d1b-followups`
- Tips: `33e08705` (relay-quickstart) + `03ffb991` (get-started) + `dfae5aaf`
  (justfile). Base `c8d5e7c9` (origin/master), independent follow-up slice.
- Item 1: removed the phantom `c2c relay rooms knock/knocks/approve-knock/
  deny-knock` CLI family from docs/relay-quickstart.md; replacement prose
  verified truthful (relay routes exist in relay.ml, MCP knock tools exist in
  c2c_mcp.ml, LOCAL `c2c rooms knock` family is real and NOT denied — only
  `relay rooms` lacks it; CLI path = invite --invitee-pk).
- Item 2: get-started Step 4 loopback replaced with two-alias pattern
  (broker refuses self-sends); both troubleshooting rows fixed; reviewer
  reproduced the recipe verbatim on a throwaway broker (self-send rc=1 with
  exact error string; round-trip rc=0 both ways; no unstated env).
- Item 3: nine justfile recipes (build, build-cli, build-server, check,
  install-cli, install-mcp, install-hook, install-all, clean) moved from
  `${DUNE_WATCHDOG_TIMEOUT:-60}` to `:-900`; zero `:-60` left; override
  mechanism unchanged; `clean` inclusion justified (dune lock contention).
  Plain `just check` (no override) rc=0 — closes the H5-run IssueRecorded on
  cold-worktree rc=124 timeouts.
- Live peer-PASS (independent opus reviewer, not author or its subagent):
  PASS first pass. Evidence IN slice worktree: reviewer's own PLAIN
  `just check` rc=0 (build-clean-IN-slice-worktree-rc=0); CLI enum re-verified
  against the worktree binary; scope exactly 3 files; no --amend anomaly.
  Signed artifact `dfae5aaf-fable-warden.json` (v2, build_rc=0, all targets).
- Carry-forward → D1c (queued): phantom relay-rooms-knock residue in
  docs/llms.txt:137-138, docs/commands.md:994-997,
  docs/c2c-research/relay-rooms-spec.md:240,242. (connect.md hits seen by the
  reviewer are the pre-D1 base copy — already fixed on
  friction-d1-connect-golden 43cac304.)
