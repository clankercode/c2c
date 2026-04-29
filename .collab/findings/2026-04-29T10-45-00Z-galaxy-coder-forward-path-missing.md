# Finding: forward_send used base peer URL instead of /forward path

**Date:** 2026-04-29T10:45:00Z
**Agent:** galaxy-coder
**Severity:** CRITICAL — forward requests routed to wrong endpoint

## Symptom
After fixing the netbase issue, forward requests to peer relays returned:
```
peer relay relay-b rejected request 404: {"ok":false,"error_code":"not_found","error":"unknown endpoint: /"}
```

## Root Cause
In `relay_forwarder.ml`, the `forward_send` function constructed the URI from `peer_url` directly:
```ocaml
let uri = Uri.of_string peer_url in
```

The `peer_url` is the base URL of the peer relay (e.g., `http://c2c-mesh-relay-b:18081`). The `/forward` path was never appended, so `Client.call` sent requests to `/` instead of `/forward`.

## Fix
```ocaml
let uri = Uri.of_string (peer_url ^ "/forward") in
```

## Status
**Fixed** in `.worktrees/relay-mesh-validation/` at commit `655be62c`.

## Discovery Path
1. 404 error showed requests were hitting root `/` instead of `/forward`
2. Reviewed `forward_send` code and found missing path append
3. Added `Printf.eprintf` debug logging to capture URI details
4. Confirmed URI was correct except for missing path
5. Appended "/forward" to resolve

## Files Changed
- `ocaml/relay_forwarder.ml`: `forward_send` — append "/forward" to peer_url
