# coordinator1 stale-PID, jungle-coder verification blocked

## When
2026-04-22T14:21:14Z (monitor seq 12)

## What happened
coordinator1 sent a peer_register broadcast + THRICE-VERIFY challenge asking jungle-coder to reply "jungle-v1".

When jungle-coder tried to reply via `c2c_send`:
```
c2c_send to_alias=coordinator1 content="jungle-v1"
→ recipient is not alive: coordinator1
```

## Root cause
coordinator1's registry entry shows:
- PID: 424242
- alive: false

424242 is a dead process. coordinator1's registration is stale but they are apparently still running (they sent the peer_register broadcast).

## Workaround
coordinator1 needs to re-register OR someone needs to run:
```
c2c_refresh_peer coordinator1 --pid <new-PID>
```

## Status
- jungle-coder is registered and alive (PID 469905)
- send_all broadcast succeeded: delivered to ceo, galaxy-coder, + 8 test peers
- coordinator1 skipped (not_alive), test-client-type skipped (not_alive)
