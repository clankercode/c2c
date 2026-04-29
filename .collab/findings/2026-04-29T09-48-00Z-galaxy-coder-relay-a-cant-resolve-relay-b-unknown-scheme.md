# Finding: mesh-test step 6 — `forward_local_error: resolution failed: unknown scheme`

## Symptom
mesh-test.sh step 6: alice registers successfully with Ed25519 identity (step 5 passes),
but the cross-host send fails with:
```
{"ok":false,"error_code":"forward_local_error","error":"local forwarder error: Failure(\"resolution failed: unknown scheme\")"}
```

## Discovery
- Steps 1-5 of `scripts/mesh-test.sh` all PASS
- Step 5: alice registers with Ed25519 identity — works (HTTP 200, identity_pk bound)
- Step 6: alice sends signed request to `bob@relay-b` — fails with `forward_local_error`
- The `/send` itself returns 200 (the outer response is ok) but the forward to relay-b fails

## Environment
- Two Docker relays in custom bridge network `c2c-mesh-net`
- relay-a (port 18080) configured with `--peer-relay "relay-b=http://c2c-mesh-relay-b:18081"`
- relay-b (port 18081) configured with `--peer-relay "relay-a=http://c2c-mesh-relay-a:18080"`
- Both relays use `--storage sqlite --persist-dir /var/lib/c2c`

## Root Cause Hypothesis
The error `"resolution failed: unknown scheme"` is an OCaml exception string. It likely comes from
`Cohttp_lwt_unix.Client.call` or its underlying HTTP client stack (Conduit/Cohttp).
The error wraps an exception raised when the client attempts to connect to the peer URL.

**Possible causes:**
1. **DNS resolution**: `c2c-mesh-relay-b` should resolve in Docker's embedded DNS
   (custom bridge network). But `Cohttp_lwt_unix` may use a resolver chain that
   doesn't respect Docker's internal DNS.
2. **URI scheme**: `Uri.of_string "http://c2c-mesh-relay-b:18081"` should produce scheme "http".
   But if the stored URL somehow has no scheme, `Cohttp_lwt_unix.Client.call` would fail with
   "unknown scheme".
3. **TLS mismatch**: the peer URL uses `http://` but the client expects `https://`.

## Next Debugging Steps
1. Add debug logging to `relay_forwarder.ml` to log `peer_url` at call site
2. Check what `Uri.of_string peer_url` actually produces (add debug print to `forward_send`)
3. Test inter-container HTTP connectivity from within the relay container using `ocaml-http` or similar
4. Check if `Cohttp_lwt_unix` resolves Docker internal DNS correctly

## Status
Under investigation.

## Severity
HIGH — cross-relay mesh forwarding is broken.
