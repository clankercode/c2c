# Finding: #674 cross-host E2E test — CLI flag bugs

**Severity**: High — all 8 tests fail at setup before any assertion runs
**File**: `docker-tests/test_kimi_opencode_cross_host.py`
**Commit**: 817f0889
**Date**: 2026-05-03
**Reviewed by**: test-agent

## Symptom

All 8 tests ERROR at `registered_agents` fixture (setup phase). Root cause: `c2c` CLI subcommands used in the test don't accept the flags the test passes.

## Bug 1 — `register --relay-url` doesn't exist

**Location**: `register()` helper, line 61
```python
c2c_in(container, f"register --alias {alias} --relay-url {RELAY_URL}")
```

**Error**:
```
c2c: unknown option '--relay-url'
```

`c2c register` only accepts `--alias`, `--json`, `--session-id`. The relay URL is already configured via `C2C_RELAY_URL` env var in the container (set by compose). Fix: remove `--relay-url <url>` from the register call.

## Bug 2 — `list --relay-url` doesn't exist

**Location**: `test_agents_see_each_other`, line 157
```python
relay_list = c2c_in(container_a, f"list --relay-url {RELAY_URL}")
```

Same issue. `c2c list` only accepts `--all`, `--enriched`, `--json`. Cross-host visibility is via `C2C_RELAY_URL` env. Fix: use `c2c list` (no relay-url arg) and accept that both agents will see peers on their own broker; OR the test should query the relay's registry via a different mechanism.

## Bug 3 (likely) — `send` with `alias@relay-url` format

**Location**: `send_dm()` helper + `test_a_to_b_dm`, line 168
```python
send_dm(container_a, f"{AGENT_B}@{RELAY_URL}", test_msg)
# → c2c send agent-b1@http://c2c-e2e-relay:7331 "..."
```

`c2c send` accepts `ALIAS MSG...`. The `alias@host` syntax is documented in the send help as the remote delivery format, but the host part may need to be just a hostname/IP, not a full URL with scheme and port. Unconfirmed — didn't get far enough to hit this.

## Test structure — otherwise sound

The helper functions, fixtures, and test classes are well-structured:
- `poll_until_message` with timeout is the correct pattern for async delivery
- `ensure_compose_up` fixture correctly skips if containers aren't running
- Room operations (`rooms join`, `rooms send`, `rooms history`) use correct CLI syntax
- `test_echo_roundtrip` correctly validates bidirectional DM

## Fixes needed

1. Remove `--relay-url {RELAY_URL}` from `register()` call (env var handles relay routing)
2. Remove `--relay-url` from `list` call; accept that cross-host visibility is via the relay's forwarding, not a list query
3. Verify or fix `alias@host` syntax for `send` — may need `agent-b1@relay` (hostname only, not full URL) or just `agent-b1` if both brokers share the same relay via env var
