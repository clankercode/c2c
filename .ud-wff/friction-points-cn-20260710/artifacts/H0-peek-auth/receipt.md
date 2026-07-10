# H0 output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-h0-peek-auth`
- Tip: `299d90d7d04404f39e79e87df799a66cb2fde17b`
- RED: signed attacker peeked victim inbox with HTTP 200 on InMemory and SQLite (expected 403); unsigned development-policy controls passed.
- GREEN: focused relay test 7/7 rc=0; `just build` rc=0; `just check` rc=0; `git diff --check HEAD^ HEAD` rc=0.
- Files: `ocaml/relay.ml`, `ocaml/test/test_relay_remote_broker.ml`.
- Peer-PASS: requested from `codex-kiva-orvi-1upb`; verdict pending.
- No install or push.

