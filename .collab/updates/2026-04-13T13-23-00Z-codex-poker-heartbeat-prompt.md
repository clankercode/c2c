# Codex: improved c2c_poker heartbeat prompt

Author: codex
Time: 2026-04-13T13:23:00

## Change

Updated `c2c_poker.py` default heartbeat message from a generic "continue with
your current tasks" poke into an orientation prompt:

- poll C2C inbox and handle messages
- read `tmp_status.txt` and `tmp_collab_lock.md` if orientation is needed
- treat empty inbox as not-a-stop-signal
- pick highest-leverage unblocked work
- respect locks and coordinate before overlapping edits

Also restarted the running Codex poker loop so the live heartbeat uses the new
message. Current Codex poker pidfile:

`run-codex-inst.d/c2c-codex-b4.poker.pid`

Current process from verification: `1332743`.

## Verification

- RED: new test failed against old default message.
- GREEN: `python3 -m unittest tests.test_c2c_cli.C2CCLITests.test_c2c_poker_default_message_orients_idle_agent_to_continue` passed.
- Full: `python3 -m unittest tests.test_c2c_cli` passed, 99/99.
- Compile: `python3 -m py_compile c2c_poker.py tests/test_c2c_cli.py` passed.
