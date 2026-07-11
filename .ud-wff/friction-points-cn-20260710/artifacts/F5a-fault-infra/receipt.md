# F5a output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-f5a-fault-infra`
- Tip: `fbb16453` (single commit). Base `8b2c4c0c` (H6 peer-PASSed tip).
  **Dune lane H4→J1→H5→H6→F5a COMPLETE.**
- `ocaml/test/relay_test_support.ml` — scripted fault server (generalized
  fresh from H6's fixture; fork-based because suites drive the c2c binary as a
  subprocess client): bind+listen before fork, ephemeral port, SO_REUSEADDR,
  idempotent SIGKILL+waitpid stop (ECHILD-safe), request capture fsynced
  before response, per-route response sequencing, status faults 401/429/5xx,
  delay, truncated-body (real Content-Length advertised), malformed JSON,
  close-without-response, closed_port helper; blocking client with sound
  fault taxonomy (Http|Refused|Timeout|No_response|Bad_response). ZERO relay
  semantics (no competing relay). Deps: unix+yojson only.
- `ocaml/test/relay_test_support_real.ml` — REAL production
  `Relay.Relay_server(Relay.InMemoryRelay).make_callback` on cohttp over a
  pre-bound loopback socket; byte-identical functor application to
  test_pow_relay's (reviewer grep-confirmed); relay.ml untouched.
- Self-tests: test_relay_test_support 10/10; reviewer ran it THREE times
  (rc 0/0/0 — no lifecycle/port flakiness). Proof migration: H6's
  test_c2c_list_relay fixture swapped onto the shared support with assertions
  untouched (13/13). Zero production-code diff (all files under ocaml/test/).
- ocaml/test/dune: exactly two disclosed hunks — H6 stanza gains the support
  lib + comment; trailing append of two library stanzas + one test stanza
  with lane-completion comment. No new opam deps.
- Full `just test-ocaml` 98 suites green in-worktree (worker); PoW/relay
  suites re-verified by reviewer (pow_relay 15, pow 5, pow_policy 6,
  relay_remote_broker 3) + lane siblings (22/26/23).
- Live peer-PASS (independent opus reviewer, not author or its subagent):
  PASS first pass. Evidence IN slice worktree: reviewer's own
  `DUNE_WATCHDOG_TIMEOUT=900 just check` rc=0
  (build-clean-IN-slice-worktree-rc=0). Signed artifact
  `fbb16453-fable-warden.json` (v2, build_rc=0, all targets).
- Advisory nits for F5b/F5c: bracket API sufficient (no module fork needed);
  a sequential-brackets-shared-backend variant may be wanted later.
- Out-of-scope carried: test_relay_remote_broker pins a local COPY of the
  /remote_inbox/ path parser rather than the production function; test_pow_relay
  still carries its own loopback pattern (F5b may migrate it when adopting).
