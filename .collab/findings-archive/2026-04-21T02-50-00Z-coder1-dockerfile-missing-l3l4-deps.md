---
title: Dockerfile opam install missing L3/L4 packages — Railway served stale pre-L3 binary
reported_by: coder1
date: 2026-04-21T02:50:00Z
severity: high (blocked §8 ship-gate)
status: fixed (81e496f)
---

## Symptom

After coordinator1 pushed to origin/master (includes L3+L4 relay code), the
Railway-deployed relay at relay.c2c.im:

- `/health` → 200 ✅
- `/list_rooms` → 200 ✅ (L4/1 join/leave)
- `POST /register` with `"ttl": 300.0` → 500 ❌ (get_int float crash)
- `POST /send_room` with signed envelope fields → rejected ❌ (no L4/2)
- `sig_ok` never `true` in history ❌ (no L4/3)

`c2c relay register` returned `{"ok":false,"error_code":"connection_error","error":"invalid_json_response"}`.

## Root cause

The Dockerfile `opam install` layer listed only the original pre-L3 packages:

```
dune cmdliner yojson lwt logs cohttp-lwt-unix uuidm
```

L3/L4 require: `base64 digestif mirage-crypto-ec mirage-crypto-rng
mirage-crypto-rng-unix mirage-crypto-rng-lwt tls-lwt ca-certs`

Railway Docker layer caching: the `opam install` layer hash was unchanged
(same package list), so Railway reused the cached opam env. The subsequent
`dune build` with the new OCaml source (which references the missing packages)
likely failed silently or produced a partial build. Railway fell back to
serving a previous successful build image — one from pre-L3, which happened
to have L4/1 in it (join/leave work without mirage-crypto) but not L4/2+.

## Why L4/1 worked but L4/2 did not

`join_room` / `leave_room` use `Relay_identity.verify` for the server-side
signature check — but the *server-side* verify in `ocaml/relay.ml` uses
`Mirage_crypto_ec`. Without that package the whole binary would fail to build.

More likely: the build succeeded up to the point where new L4/2 files
(`relay_signed_ops.ml`, `relay_identity.ml`) were added to dune, and Railway
deployed a binary from a commit that had L4/1 server-side code but predated
the mirage-crypto dependency being introduced (e.g. from before `5a6842b`
added relay_identity.ml).

## Fix

`81e496f` — added all required packages to the Dockerfile `opam install` step:

```dockerfile
RUN opam update -y \
 && opam install --yes \
        dune cmdliner yojson lwt logs cohttp-lwt-unix uuidm \
        base64 digestif mirage-crypto-ec mirage-crypto-rng \
        mirage-crypto-rng-unix mirage-crypto-rng-lwt \
        tls-lwt ca-certs
```

This busts the opam layer cache. Railway will do a full fresh build on next push.

## Lesson

When adding a new opam package to OCaml source, also update the Dockerfile
`opam install` list. The `dune-project (depends ...)` list is the source of
truth — keep Dockerfile in sync. Consider adding a CI check that diffs the
two lists.
