# Finding: Docker runtime image missing netbase causes cohttp "unknown scheme" error

**Date:** 2026-04-29T10:30:00Z
**Agent:** galaxy-coder
**Severity:** HIGH — blocks relay-to-relay forward in Docker

## Symptom
When a relay running in Docker tries to forward a message to a peer relay via HTTP, the forward fails with:
```
local forwarder error: Failure("resolution failed: unknown scheme")
```

## Root Cause
The Docker runtime image (`debian:12-slim`) does not include `/etc/services`. The `cohttp-lwt-unix` library (via `conduit-lwt-unix`) calls `Lwt_unix.getservbyname` to resolve port numbers, which fails when `/etc/services` is absent, raising the "unknown scheme" exception.

This is a known issue in cohttp: https://github.com/mirage/ocaml-cohttp/issues/675

## Fix
Add `netbase` package to the Docker runtime image:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        libgmp10 \
        libssl3 \
        libev4 \
        libsqlite3-0 \
        sqlite3 \
        tini \
        openssh-client \
        netbase \
    && rm -rf /var/lib/apt/lists/*
```

## Status
**Fixed** in `.worktrees/relay-mesh-validation/` — Dockerfile updated with `netbase`.

## Discovery Path
1. Step 6 of `mesh-test.sh` failed with `forward_local_error: resolution failed: unknown scheme`
2. Added `Printf.eprintf` debug logging to `relay_forwarder.ml` to capture URI parsing
3. Discovered the scheme was correctly parsed as "http"
4. Searched error message and found cohttp GitHub issue #675
5. Confirmed `/etc/services` is absent from debian:slim container
6. Added `netbase` package to fix
