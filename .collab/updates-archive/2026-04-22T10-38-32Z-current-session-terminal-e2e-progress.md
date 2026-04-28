## Session Recovery: Terminal E2E Framework

- Current `HEAD`: `393ba3a` (`test: fix fake pty winsize cleanup`)
- Current plan: [docs/superpowers/plans/2026-04-22-terminal-e2e-framework-implementation.md](/home/xertrov/src/c2c/docs/superpowers/plans/2026-04-22-terminal-e2e-framework-implementation.md:1)
- Current status:
  - Task 1 complete: artifact collector + terminal driver core
  - Task 2 complete: `Scenario` + `scenario` fixture
  - Task 3 complete: `TmuxDriver`
  - Task 4 complete: `FakePtyDriver` + fake child fixture + parity smoke
  - Task 5 next: Codex / codex-headless adapters and capability probes

### Commits Landed In This Slice

- `1ffad81` `docs: add terminal e2e framework design`
- `181e49f` `docs: add terminal e2e framework plan`
- `b255310` `test: add terminal e2e framework core types`
- `85acbdb` `test: note e2e terminal artifacts ignore`
- `97f3234` `test: restore terminal e2e framework import path`
- `8c21a99` `test: harden terminal e2e framework core`
- `5b9936e` `test: package terminal e2e helpers`
- `3e80dd0` `test: harden terminal artifact collection`
- `2dd863b` `test: tighten terminal artifact collector contract`
- `43b1cd8` `test: confine terminal artifact paths`
- `238ae0f` `test: add scenario orchestration for terminal e2e`
- `993ab4f` `test: fix task 2 scenario capability and cleanup`
- `b88f9d5` `test: harden task 2 scenario lifecycle`
- `9587fc7` `test: add tmux terminal driver`
- `f0d19b4` `test: tighten tmux driver start contract`
- `7c2f189` `test: harden tmux driver launch contract`
- `020ea78` `test: add fake pty terminal driver`
- `cde21ca` `test: harden fake pty driver`
- `393ba3a` `test: fix fake pty winsize cleanup`

### Verification State

- Latest full framework run:
  - `pytest -q tests/test_terminal_e2e_framework.py`
  - Result: `25 passed, 1 skipped`
- Latest Task 4 focused regression run:
  - `pytest -q tests/test_terminal_e2e_framework.py -k 'winsize_setup_fails or closes_openpty_fds_when_launch_fails or start_sets_winsize_from_terminal_spec'`
  - Result: `3 passed, 23 deselected`

### Files Added So Far

- `tests/e2e/framework/terminal_driver.py`
- `tests/e2e/framework/artifacts.py`
- `tests/e2e/framework/scenario.py`
- `tests/e2e/framework/tmux_driver.py`
- `tests/e2e/framework/fake_pty_driver.py`
- `tests/e2e/fixtures/fake_terminal_child.py`

### Important Current Behavior

- `scenario` fixture is still minimal and does not yet wire real drivers/adapters.
- `TmuxDriver.start()` now passes `spec.env` through tmux `-e KEY=VALUE` flags rather than relying on subprocess env.
- `FakePtyDriver.start()` now:
  - applies terminal size via `TIOCSWINSZ`
  - cleans up both PTY fds if winsize setup fails
  - cleans up both PTY fds if `Popen()` fails
- Fake child tests now fail if `/quit` does not produce `BYE` before forced stop.

### Next Unblocked Step

Start Task 5 from the plan:

1. Read the Task 5 section in the plan.
2. Spawn a fresh worker to implement:
   - `tests/e2e/framework/client_adapters.py`
   - `tests/test_terminal_e2e_client_adapters.py`
   - minimal `scenario.py` / `conftest.py` updates required by Task 5
3. Keep using the same review loop:
   - spec review first
   - quality review second
   - follow-up commits only, no amend

### Known Worktree Drift To Avoid Touching

These files were already dirty or unrelated during this session and should be handled carefully:

- `ocaml/c2c_mcp.ml`
- `ocaml/cli/c2c.ml`
- `tests/test_c2c_deliver_inbox.py`
- `todo.txt`
- `functions/`
- `scripts/x-add-todo-hook.fish`

### Todo Note Already Added

`todo.txt` already includes the follow-up note that once the current terminal E2E work is done, the newly landed Codex binaries should unblock the previously gated Codex / codex-headless plan items and those should be re-planned and implemented next.
