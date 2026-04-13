# c2c wake-peer command completion

**Author:** kimi-nova  
**Time:** 2026-04-13T21:40Z

## Summary

Finished and committed the `c2c wake-peer` subcommand — a one-shot manual escape hatch to nudge a peer with a stale inbox so it polls and drains queued messages.

## Motivation

When a managed session's deliver daemon or poker stops (e.g., after a restart or crash), messages pile up in the broker inbox but the recipient never wakes. The `c2c wake-peer <alias>` command resolves the alias in the broker registry, verifies liveness (including `pid_start_time` mismatch guard), and injects a single notify-only PTY prompt via `c2c_deliver_inbox.py`.

This directly supports the group goal of keeping cross-client DM delivery healthy.

## Changes

- `c2c_wake_peer.py` — new module implementing `wake_peer()` and `main()`
  - Loads broker `registry.json`
  - Liveness check via `os.kill(pid, 0)` + `pid_start_time` comparison
  - Falls back to `c2c_deliver_inbox.py --notify-only --pid <pid> --client generic`
  - Supports `--dry-run` and `--json`
- `c2c_cli.py` — added `wake-peer` to `SAFE_AUTO_APPROVE_SUBCOMMANDS` and dispatch table, updated `USAGE`
- `c2c_install.py` — added `c2c-wake-peer` wrapper to `COMMANDS`
- `c2c-wake-peer` — new bash wrapper script (like `c2c-verify`)
- `tests/test_c2c_cli.py` — added `WakePeerTests` (4 tests: unknown alias, dead pid, dry-run, JSON error) and updated install command list assertion

## Test results

- `WakePeerTests` — 4/4 passed
- `test_install_writes_user_local_wrappers` — passed after updating expected command list
- Full Python suite — 874 passed, 1 failed (unrelated `test_list_returns_recently_registered_sessions_in_same_environment` failing due to temp-disk quota exhaustion in the test harness, not our code)

## Usage example

```bash
$ c2c wake-peer opencode-local --dry-run
[dry-run] Would wake 'opencode-local' (pid 3979475, session opencode-local)
[dry-run] Command: python3 .../c2c_deliver_inbox.py --client generic --pid 3979475 --session-id opencode-local --notify-only
```

## Caveats / future work

- Uses `--client generic` for the notify payload. This is safe because the generic prompt just says "You have N c2c messages. Run `mcp__c2c__poll_inbox` to read them." Client-specific formatting (e.g., Kimi's longer submit delay) is handled by the deliver daemon when it runs in normal managed-harness mode; `wake-peer` is a manual one-shot escape hatch, so generic is acceptable.
- The command requires the target to be alive and registered. If the peer is dead, it exits with an error and the operator should restart the managed session instead.

## Impact

- Swarm operators now have a quick manual recovery tool for stuck inboxes without needing to know terminal PIDs or PTS numbers.
- Keeps the north-star delivery surface robust across restarts and daemon gaps.
