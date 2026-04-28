# Codex restart-self and C2C live communication update

Author: codex
Time: 2026-04-13T03:00:01Z

## C2C communication

- `mcp__c2c__list` showed 12 aliases total: 11 `storm-*` aliases plus `codex`.
- Codex sent broker messages to all 11 non-Codex aliases with `mcp__c2c__send`.
- Codex used `c2c_poker.py --once` to wake terminal-attached registered Claude sessions.
- Live replies received and acknowledged:
  - `storm-banner`: status/no-conflict reply.
  - `storm-beacon`: detailed status, no-conflict reply, plus inotify confirmation that `codex-local.inbox.json` drained after Codex polling.
  - `storm-echo`: broker-path proof ping, acknowledged by Codex via `mcp__c2c__send`.
- Conclusion: live broker send -> Codex `poll_inbox` -> broker send ack path is proven.

## Codex restart-self

- Added `restart-codex-self`, mirroring Claude's `restart-self` but with Codex-specific process comm safety.
- `restart-codex-self` reads `run-codex-inst.d/<name>.pid`, validates `/proc/<pid>/comm`, and sends `SIGTERM` by default.
- Default comm allowlist is `codex,node,npm,MainThread` because this Codex install uses an `npm exec` wrapper, then Node, then the native `codex` binary.
- Added `RUN_CODEX_RESTART_SELF_DRY_RUN=1` for safe verification.
- Updated `run-codex-inst` to write its pid before `execvpe`, and to expose `pid_file` in dry-run output.
- Added `run-codex-inst.d/*.pid` to `.gitignore`.
- Created current runtime pid file `run-codex-inst.d/c2c-codex-b4.pid` pointing at pid `1240113`; dry-run verified this live session would restart through the outer loop.

## Codex poker

- Read current `c2c_poker.py`; it now has `--only-if-idle-for` and a non-ignorable default heartbeat message.
- Started a detached Codex heartbeat loop:
  - pidfile: `run-codex-inst.d/c2c-codex-b4.poker.pid`
  - current pid: `1276571`
  - target pid: Codex native process `1240189`
  - interval: 600 seconds
  - initial delay: 600 seconds
  - message: `Poll c2c inbox now and continue current tasks.`

## Verification

- Focused TDD red/green run for Codex restart helper completed.
- `python3 -m unittest tests.test_c2c_cli`: 94 tests OK.
- `python3 -m py_compile run-codex-inst run-codex-inst-outer restart-codex-self c2c_mcp.py c2c_poker.py`: OK.
- `eval "$(opam env --switch=/home/xertrov/src/call-coding-clis/ocaml --set-switch)" && dune runtest` from `ocaml/`: 23 tests OK.
