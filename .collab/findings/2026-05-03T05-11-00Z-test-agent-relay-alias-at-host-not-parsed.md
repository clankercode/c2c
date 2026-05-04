# Finding: relay doesn't parse `alias@host:port` in to_alias field — cross-host delivery silently fails

**Severity**: High — all cross-host DM and room messages silently fail to deliver
**File**: `ocaml/c2c_relay_connector.ml` (connector) or `ocaml/relay.ml` (relay side)
**Date**: 2026-05-03
**Reviewed by**: test-agent

## Symptom

When sending a message via `c2c send alias@host:port "msg"`, the message is appended to `remote-outbox.jsonl` and the relay connector forwards it to the relay, but the relay returns `unknown_alias` and the message is never delivered.

## Root cause

The outbox entry stores `to_alias` exactly as provided by the user:
```json
{"from_alias":"agent-a1","to_alias":"agent-b1@c2c-e2e-relay:7331","content":"hello-from-kimi-..."}
```

The relay connector reads this entry and sends it to the relay's `/inbox` endpoint. The relay then tries to look up a registration for the full string `"agent-b1@c2c-e2e-relay:7331"`, but only bare aliases are registered (e.g., `"agent-b1"`).

## Error observed

```
[relay-connector] sync: registered=1 heartbeated=0 fwd=0 failed=2 inbound=0
  [send: {"ok":false,"error_code":"unknown_alias","error":"no registration for alias \"agent-b1@c2c-e2e-relay:7331\""}]
```

## Expected behavior

The `to_alias` field should be parsed before lookup. Two possible fix locations:

1. **Connector side** (`c2c_relay_connector.ml`): Parse `to_alias` with `alias@host:port` logic before including it in the relay request. Extract bare `alias` and send that to relay's `/inbox` along with the original host for routing.

2. **Relay side** (`relay.ml`): When looking up `to_alias` for inbox delivery, parse the alias to extract the bare name if it contains `@`, and look up the bare alias in the registry.

## Affected paths

- `c2c send alias@host:port "msg"` — DM path
- `c2c rooms send <room> "msg"` — room cross-host delivery (same outbox mechanism)
- Any path that writes a remote `to_alias` to `remote-outbox.jsonl`

## Test impact

`docker-tests/test_kimi_opencode_cross_host.py` tests fail at all cross-host delivery assertions (4 DM/room tests). The test is structurally correct — it will pass once this bug is fixed.

## Reproduction

```bash
# Start e2e compose
docker compose -f docker-compose.e2e-multi-agent.yml up -d

# Register agents
docker exec c2c-e2e-agent-a1 c2c register --alias agent-a1
docker exec c2c-e2e-agent-b1 c2c register --alias agent-b1

# Send cross-host DM (appears to succeed)
docker exec c2c-e2e-agent-a1 c2c send agent-b1@c2c-e2e-relay:7331 "hello"

# Check outbox — message is there, never delivered
docker exec c2c-e2e-agent-a1 cat /var/lib/c2c/remote-outbox.jsonl

# Relay connector shows unknown_alias error
# Recipient never receives message
```
