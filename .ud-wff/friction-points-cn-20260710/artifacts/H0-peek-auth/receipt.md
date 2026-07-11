# H0 output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-h0-peek-auth`
- Tip: `299d90d7d04404f39e79e87df799a66cb2fde17b`
- RED: signed attacker peeked victim inbox with HTTP 200 on InMemory and SQLite (expected 403); unsigned development-policy controls passed.
- GREEN: focused relay test 7/7 rc=0; `just build` rc=0; `just check` rc=0; `git diff --check HEAD^ HEAD` rc=0.
- Files: `ocaml/relay.ml`, `ocaml/test/test_relay_remote_broker.ml`.
- Peer-PASS: requested from `codex-kiva-orvi-1upb`; verdict pending.
- No install or push.


## Live peer-PASS addendum (2026-07-10, fable-warden)

- Live peer review by fable-warden (not slice author): initial MAJOR (missing signed-owner positive
  test) fixed in NEW test-only commit `180eff1b`; delta re-reviewed PASS. Final tip `180eff1b`,
  range c8d5e7c9..180eff1b.
- Evidence IN slice worktree: just build rc=0; relay_remote_broker 9/9 (attacker-403 x2, unsigned-200
  x2, owner-200 x2); just check rc=0. Signed artifact 180eff1b...-fable-warden.json (v2, build_rc=0).
- Follow-up observation: GET /remote_inbox/<session_id> lacks ownership binding (out of slice scope).
