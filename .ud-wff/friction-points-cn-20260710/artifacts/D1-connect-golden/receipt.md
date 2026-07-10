# D1 output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-d1-connect-golden`
- Tips: `4a97faef` (connect.md golden-path rewrite) + `43cac304` (command
  harness). Base `c8d5e7c9` (origin/master), independent slice.
- `docs/connect.md` rewritten as ONE executable public-relay golden path:
  install → local proof (two aliases on an isolated temp broker; self-send is
  refused by design) → relay setup/register/status → discover → send →
  poll/peek/monitor → reply/verify, plus optional connector + rooms steps,
  11-row symptom/cause/fix table, and an explicitly-marked *documented*
  two-host receipt (loopback = relay-smoke-test.sh per deploy; two-host cites
  the 2026-04-14 Tailscale proof; state-changing steps quoted, not re-run
  against prod).
- Real doc bug fixed: `c2c relay rooms knock/knocks/approve-knock/deny-knock`
  do NOT exist on the CLI (enum is list|join|leave|send|history|invite|
  uninvite|set-visibility); knock flows are relay server routes + MCP tools.
- New gate `scripts/check-connect-commands.py` wired into `just check`
  (+ standalone `just check-connect-commands`): derives valid command paths
  from the built binary's `--help` at check time (drift-proof, not hardcoded);
  reviewer negative-tested 5 bogus commands (all caught) + commented-line skip.
  40/40 doc invocations pass.
- Live peer-PASS (independent opus reviewer, not author or its subagent): PASS
  first pass. Evidence IN slice worktree: reviewer's own `just check` rc=0
  (build-clean-IN-slice-worktree-rc=0, includes the new gate), 12+ command-truth
  audit vs binary help, JSON shapes matched relay_server_json.ml /
  RegistrationLease.to_json / json_of_send_result, live read-only probes
  (relay health + relay status) matched doc byte-for-byte. Signed artifact
  `43cac304-fable-warden.json` (v2, build_rc=0, all targets).
- Nits (non-blocking): lease JSON example shows a field subset (disclosed by
  the receipt's "normalized + schema" note); harness ENUM_LEAF/SUBGROUP
  structural hints are the one hardcoded surface.
- Out-of-scope doc bugs flagged for follow-up (NOT fixed here):
  1. `docs/relay-quickstart.md:657-661` still documents the nonexistent
     `relay rooms knock` family.
  2. `docs/get-started.md` Step 4 tells users to self-send a loopback test but
     the local broker refuses self-sends; needs the two-alias pattern
     connect.md Step 2 now shows.
  (Candidate: fold both into a small docs follow-up slice or Q1-adjacent pass.)
- Nav wiring pre-existing (verified, not edited): _config.yml header_pages +
  index.md links; `#relay-security` anchor preserved for relay-quickstart.
