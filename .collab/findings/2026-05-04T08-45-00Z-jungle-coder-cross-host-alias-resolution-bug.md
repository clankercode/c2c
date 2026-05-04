# Cross-Host Alias Resolution Bug — #702

## When
Discovered 2026-05-04 during #702 e2e test execution.

## Symptom
Python e2e test `test_a1_to_b1_via_relay`:
```
c2c send b1 hello → error: unknown alias: b1
```

Even though:
- `a1` is registered on broker-a
- `b1` is registered on broker-b (separate broker volume)
- Both brokers are configured with `C2C_RELAY_URL=http://relay:7331`
- The relay is healthy

## Root Cause

`c2c_broker.ml` `enqueue_message` (line 2022):

```ocaml
if is_remote_alias to_alias then
  (* Remote alias: append to relay outbox *)
  C2c_relay_connector.append_outbox_entry t.root ~from_alias ~to_alias ~content ()
else
  with_registry_lock t (fun () ->
    match resolve_live_session_id_by_alias t to_alias with
    | Unknown_alias -> invalid_arg ("unknown alias: " ^ to_alias)
    ...
```

1. `is_remote_alias` checks for `@` in alias — `"b1"` has no `@`, so it's treated as a **local** alias.
2. `resolve_live_session_id_by_alias` looks up `"b1"` in the local registry only.
3. Not found → raises `Unknown_alias` → `"unknown alias: b1"`.
4. **The relay is never consulted.**

The broker needs a relay lookup fallback when an alias isn't found locally. This is a **real broker bug**, not a test issue.

## Cross-Host Messaging Requires `alias@host` Format

For the above send to work, it must be: `c2c send b1@relay hello` where `relay` must match the relay's configured `self_host`.

### What `self_host` must be

`C2C_RELAY_NAME=relay` must be set in the relay's environment, so `self_host = "relay"`.
With `host_acceptable ~self_host:"relay" (Some "relay") = true`, the alias `b1@relay` is accepted.

## Verified Working

With the following, cross-host messaging DOES work:
1. Relay: `C2C_RELAY_NAME=relay` → `self_host = "relay"`
2. Agents run `c2c relay connect` (connector loop: register, heartbeat, outbox forward, poll inbound)
3. Sends use `alias@relay` format: `c2c send b1@relay "hello"`
4. The relay's `host_acceptable` validates `relay` against `self_host = "relay"` → accepts

## Additional Issue Found: `c2c dead-letter --json` Reads Wrong Store

When run inside a **relay container**, `c2c dead-letter --json` reads the **broker's** file-based dead-letter path (`/var/lib/c2c/dead-letter.jsonl`), NOT the relay's SQLite `dead_letter` table.

This is because `dead-letter` is a broker subcommand, not a relay subcommand. The relay stores dead-letters in its `SqliteRelay` database, accessible via:
- Direct sqlite3: `sqlite3 /var/lib/c2c/c2c_relay.db "SELECT * FROM dead_letter"`
- HTTP API: `GET /dead_letter`

**Fix needed**: Add `c2c relay dead-letter [--json]` subcommand that reads from the relay's SQLite store.

## Status
**CLOSED** — fixed in 8399a22f + c2af3aad (cherry-pick of jungle-coder's 7e88576d..3eeac25a). `enqueue_message` now falls back to `append_outbox_entry` on `Unknown_alias` when relay is configured. Peer-PASS by stanza-coder.

## Severity
**Medium** — broker didn't fall back to relay for unknown bare aliases, breaking cross-host DM without `alias@host` format. Fixed.

## Related
- `c2c_broker.ml:enqueue_message` — the broker routing logic
- `c2c_relay_connector.append_outbox_entry` — the relay outbox path
- `docker-compose.e2e-multi-agent.yml` — the test topology
- `#379` — cross-host alias resolution design (S1-S3)
