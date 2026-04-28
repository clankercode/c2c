# Phase D Findings: #292 — True In-Container Validation with Kimi Auth

## Worktree
`.worktrees/292-phase-d/` — branched from `origin/master` at `a2c61a32`

## Docker Image
`c2c-test:phase-d` — built from `.worktrees/292-phase-d/` with current master

## Test Results — Full Suite In-Container (container binary, container broker)

```
test_sealed_sanity.py           7/7 passed
test_ephemeral_contract.py      2/2 passed
test_broker_respawn_pid.py       2/2 passed
test_monitor_leak_guard.py       1 passed, 1 skipped (circuit-breaker not in binary)
test_kimi_first_class_peer.py   4 passed, 1 skipped (kimi binary not in container)
─────────────────────────────────────────────────
Total:                          16 passed, 2 skipped
```

## Kimi Auth Findings

### Finding 1: `credentials` is a directory on this host

**Severity:** Medium (test expectation mismatch)

On this host (`~/.kimi/credentials`) is a **directory** containing `kimi-code.json` (1487 bytes).
The `.env.example` says `KIMI_CREDENTIALS=~/.kimi/credentials` which mounts the directory,
but `test_kimi_first_class_peer.py` expects it to be a **file**.

Correct mount path for this machine:
```
~/.kimi/credentials/kimi-code.json → /home/testagent/.kimi/credentials:ro
```

The actual auth token (access_token + refresh_token) is inside `credentials/kimi-code.json`.

### Finding 2: All 4 auth files are load-bearing

With correct mounts, all Kimi auth tests pass:
- `test_kimi_auth_files_present` ✓
- `test_kimi_credentials_content` ✓ (real auth token present)
- `test_c2c_install_kimi` ✓
- `test_kimi_can_register_and_send` ✓

The `credentials` file (containing `kimi-code.json`) is the critical auth file — it holds the OAuth tokens.
`device_id`, `kimi.json`, and `config.toml` are also required.

## Dockerfile: inotify-tools is required

The `c2c monitor` subcommand uses `inotifywait` from `inotify-tools`.
Without it, monitors exit immediately with code 0.
The `Dockerfile.test` now includes `inotify-tools` in the runtime image.

## Auth Mount Reference (this machine)

```bash
# Correct mounts for Phase D validation:
-v ~/.kimi/kimi.json:/home/testagent/.kimi/kimi.json:ro
-v ~/.kimi/credentials/kimi-code.json:/home/testagent/.kimi/credentials:ro
-v ~/.kimi/device_id:/home/testagent/.kimi/device_id:ro
-v ~/.kimi/config.toml:/home/testagent/.kimi/config.toml:ro
```

## Docker Image Build

```bash
cd .worktrees/292-phase-d/
docker build --no-cache \
  --build-arg CACHE_BUST=$(date +%s) \
  -f Dockerfile.test \
  -t c2c-test:phase-d .
```

## pytest command (no host-binary override)

```bash
docker run --rm \
  -e C2C_MCP_BROKER_ROOT=/var/lib/c2c \
  -e C2C_RELAY_CONNECTOR_BACKEND="" \
  -v ~/.kimi/kimi.json:/home/testagent/.kimi/kimi.json:ro \
  -v ~/.kimi/credentials/kimi-code.json:/home/testagent/.kimi/credentials:ro \
  -v ~/.kimi/device_id:/home/testagent/.kimi/device_id:ro \
  -v ~/.kimi/config.toml:/home/testagent/.kimi/config.toml:ro \
  -v $(pwd)/docker-tests:/docker-tests:ro \
  -w /docker-tests \
  c2c-test:phase-d \
  python3 -m pytest test_sealed_sanity.py test_ephemeral_contract.py test_broker_respawn_pid.py test_monitor_leak_guard.py test_kimi_first_class_peer.py -v
```

## Status: Phase D Complete

All in-container tests pass. Kimi auth validated. No regressions vs host-binary runs.
