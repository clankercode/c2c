# Managed agy auto `agy-env.json` discovery

## Problem
Managed `c2c start agy` registered + ran deliver-watch, but `agy-env.json` was
missing unless a human bootstrapped LS + conversation. SessionStart often never
sees `ANTIGRAVITY_LS_ADDRESS`. Env path was also split: agentapi wrote
`~/.c2c/instances/` while managed start uses `~/.local/share/c2c/instances/`.

## Fix
- `C2c_agy_agentapi` uses managed instances dir (`C2C_INSTANCES_DIR` /
  `~/.local/share/c2c/instances`).
- `ensure_agy_env`: keep env only if LS `/healthz` is live; else discover from
  **pid-scoped** CLI log (`/proc/<pid>/fd/2`) — never “latest global log” when
  pid is known (that raced to a dead prior session). Parse
  `Language server listening … for HTTP` + last `Created conversation <uuid>`.
  Optional `/proc` listen-port probe. If LS known but no conversation, mint via
  `agy agentapi new-conversation` with `ANTIGRAVITY_PROJECT_ID=default-cli-project`.
- `c2c_agy_deliver.deliver_loop` calls `ensure_agy_env` each iteration.
- `deliver_messages` (DeliveryEndpoint) uses ensure too.

## Tests
`test_c2c_agy_agentapi` 8/8; existing `test_c2c_agy_deliver` 4/4.

## Live e2e (2026-07-21)
- Fresh `c2c start agy -n e2e-agy-wake --new-session` (no human turn).
- `agy-env.json` auto-written under managed instances dir within ~seconds:
  `ls_address=127.0.0.1:38625` (live HTTP LS on that pid), conversation minted
  `1d8ce0fc-…`.
- `c2c send e2e-agy-wake` → inbox drained `[]`; conversation `steps` 41→45 after
  second inject (agentapi accepted). Minted wake channel may not paint on the
  interactive TUI surface (agy agentapi background trajectory) — delivery is
  still agentapi-authoritative, not send-keys.

## Residual
- Sticky managed alias may differ from instance name (observed `handoff-test-1`
  for `e2e-agy-wake`); peers should use the printed broker alias.
- TUI visibility of agentapi-minted conversations is upstream agy behaviour.
