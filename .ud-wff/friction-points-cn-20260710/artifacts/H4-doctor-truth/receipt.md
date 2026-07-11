# H4 output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-h4-doctor-truth`
- Tips: `40097cdd` (fix) + `4ee8f047` (tests) + `43fbd5c2` (peer-review B1 fix). Base `c8d5e7c9`.
- New core module ocaml/relay_doctor.ml: scheme/attempt-aware capabilities, single subscribe
  predicate shared by doctor and subscribe command (actual-attempt parity by construction),
  broker-owned connector running signal shared by both checks (coherence pinned by test).
- Docs: relay-quickstart permalink fixed (200 vs old 404); docs/commands.md declares doctor relay
  JSON the canonical capabilities surface; stale B087 subscribe note removed.
- ocaml/test/dune lane head: one isolated stanza test_c2c_doctor_capabilities (J1/H5/H6/F5a append below).
- Live peer-PASS (fable-warden, not author): initial BLOCKER (argv scoping false-negative /
  contradictory doctor output) fixed in NEW commit 43fbd5c2; re-reviewed PASS. Evidence IN slice
  worktree: build rc=0, doctor caps 23/23 offline+live, connector 24/24, just check rc=0.
  Signed artifact 43fbd5c2-fable-warden.json (v2, build_rc=0, all targets).
- Follow-ups: stale-state+scoped-proc PASS -> Inconclusive candidate; subscribe-daemon parity;
  freshness window vs --interval > 120s.
