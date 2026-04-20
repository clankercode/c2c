# OCaml relay TLS integration plan (Layer 2 slice 1)

**Author:** coder2-expert · **Created:** 2026-04-21 · **Status:** design, ready
to execute · **Scope:** OCaml-native TLS wiring for `ocaml/relay.ml`'s server
+ `Relay_client`.

## Context

Layer 2 of `relay-internet-build-plan.md` mandates TLS 1.3 for all relay
traffic. coder1 shipped the operator-facing setup doc at
`relay-tls-setup.md` (commit `7093038`): Let's Encrypt + certbot recipe,
self-signed + `C2C_RELAY_CA_BUNDLE` for Tailscale, reverse-proxy alt.

This doc covers the OCaml-side implementation — what changes in
`ocaml/relay.ml` and `ocaml/cli/c2c.ml`, which opam packages are needed,
and how the existing `start_server` and `Relay_client` are flipped.

Per Max's steering (2026-04-20 00:20Z, relayed by coordinator1): Python
is deprecated long-term; any new relay feature lands in OCaml first.

## Blocker / prerequisite

**Opam dependency install** — adding `tls` + `tls-lwt` is gated on user
approval (supply-chain sensitive). The agent attempting this integration
must either:

- Ask Max to run `opam install tls-lwt mirage-crypto-rng-lwt ca-certs`.
- Get approval for the Bash permission to install opam packages.

Until then, this doc stays a design, and the code sketches below cannot
be committed without breaking the build.

## Opam dependencies

Add to `dune-project` `depends`:

```
(depends
 dune cmdliner yojson lwt logs alcotest cohttp-lwt-unix uuidm
 tls-lwt                       ; TLS 1.3 engine, Lwt bindings
 mirage-crypto-rng-lwt         ; Lwt RNG entropy loop required by tls
 ca-certs)                     ; client-side CA bundle resolution
```

Transitively pulls in `tls`, `x509`, `mirage-crypto`, `fmt`, `domain-name`.
Approximate size: ~2.5 MB build artifacts; ~40s cold install on a
non-cached machine.

`tls-lwt` vs `tls-mirage`: tls-lwt is the right choice — we're running
on Lwt with Unix backend, not a MirageOS unikernel.

`mirage-crypto-rng-lwt` is mandatory: it starts the entropy collector
with `Mirage_crypto_rng_lwt.initialize (module Mirage_crypto_rng.Fortuna)`
on server startup. Without it, TLS handshakes block waiting for the RNG.

`ca-certs` provides `Ca_certs.authenticator ()` which resolves the
system trust store (reads `/etc/ssl/certs/ca-certificates.crt` on Linux,
Security framework on macOS). Required for `Relay_client` verification.

## Server side — `ocaml/relay.ml`

### Change 1: extend `start_server` with optional TLS config

Current signature (line 807):

```ocaml
val start_server :
  host:string -> port:int -> token:string option ->
  ?verbose:bool -> ?gc_interval:float -> unit -> unit Lwt.t
```

New signature:

```ocaml
val start_server :
  host:string -> port:int -> token:string option ->
  ?verbose:bool -> ?gc_interval:float ->
  ?tls:[`Cert_key of string * string] ->  (* cert_path, key_path *)
  unit -> unit Lwt.t
```

Rationale for a single `?tls` argument (vs two `?cert_path`/`?key_path`
options): TLS is either fully enabled with a cert+key pair, or not at
all. The variant makes it impossible to pass just one — invalid state
unrepresentable.

### Change 2: server mode switch

Replace the final `Cohttp_lwt_unix.Server.create` call (line 826) with:

```ocaml
let spec = Cohttp_lwt_unix.Server.make ~callback () in
match tls with
| None ->
    Cohttp_lwt_unix.Server.create
      ~mode:(`TCP (`Port port)) spec
| Some (`Cert_key (cert_path, key_path)) ->
    let* () = Mirage_crypto_rng_lwt.initialize
                (module Mirage_crypto_rng.Fortuna) in
    Cohttp_lwt_unix.Server.create
      ~mode:(`TLS (`Crt_file_path cert_path,
                   `Key_file_path key_path,
                   `No_password,
                   `Port port))
      spec
```

Note: `Cohttp_lwt_unix.Server.create`'s TLS mode is
`Conduit_lwt_unix.server`. The `server` type includes:

```
| `TLS of tls_server_key * tcp_config
```

where `tls_server_key = `Crt_file_path of string * `Key_file_path of string * password`.
The `tls` library provides the backend via `conduit-lwt-unix.tls`, which
auto-registers when both `tls` and `conduit-lwt-unix` are installed.

### Change 3: verbose log line

Current line 817 prints `http://`. Make that protocol-aware:

```ocaml
let scheme = match tls with Some _ -> "https" | None -> "http" in
Printf.printf "c2c relay serving on %s://%s:%d%s\n%!" scheme host port verbose_str;
(match tls with
 | Some _ -> Printf.printf "tls: enabled (TLS 1.3)\n%!"
 | None -> ());
```

## Client side — `Relay_client` (shipped in 9d16860)

coordinator1's Layer 1 landed `Relay_client` in `ocaml/relay.ml`. When
the relay URL is `https://...`, cohttp-lwt-unix picks TLS automatically
via the tls-lwt backend. What we need to add:

### Change 4: CA bundle resolution

Follow the contract from coder1's `relay-tls-setup.md`: respect
`C2C_RELAY_CA_BUNDLE` env var. If set and non-empty, use it as the
trust authenticator; otherwise fall back to system trust via
`Ca_certs.authenticator ()`.

In `Relay_client.make` (or wherever the HTTP client is constructed):

```ocaml
let make_tls_config () =
  let authenticator =
    match Sys.getenv_opt "C2C_RELAY_CA_BUNDLE" with
    | Some path when path <> "" ->
        (match X509.Certificate.decode_pem_multiple
                 (Cstruct.of_string (read_file path)) with
         | Ok certs -> X509.Authenticator.chain_of_trust certs
         | Error (`Msg m) ->
             failwith (Printf.sprintf "CA bundle parse error: %s" m))
    | _ ->
        (match Ca_certs.authenticator () with
         | Ok a -> a
         | Error (`Msg m) ->
             failwith (Printf.sprintf "system CA bundle unavailable: %s" m))
  in
  Tls.Config.client ~authenticator ()
```

Then plumb that `Tls.Config.client_cfg` into the Cohttp client. The
exact plumbing depends on cohttp-lwt-unix's Client.create API;
investigate `Cohttp_lwt_unix.Client.custom_ctx` — the TLS context is
carried via conduit resolver.

### Change 5: URL scheme detection

`Relay_client.make ~url:...` should reject `http://` URLs when a flag
like `--require-tls` (default on for internet-reachable URLs, off for
`127.0.0.1` / `localhost` / Tailscale CGNAT `100.x.x.x`) is set. Simple
guard:

```ocaml
let scheme_ok url =
  Uri.scheme (Uri.of_string url) = Some "https"
  || is_local_url url
```

This matches the operator intent in `relay-tls-setup.md` §3.

## CLI — `ocaml/cli/c2c.ml` `relay_serve_cmd`

Add two `Cmdliner.Arg` options (around line 1738):

```ocaml
let tls_cert =
  Cmdliner.Arg.(value & opt (some string) None
                & info [ "tls-cert" ] ~docv:"PATH"
                    ~doc:"PEM certificate file for TLS (enables HTTPS).")
in
let tls_key =
  Cmdliner.Arg.(value & opt (some string) None
                & info [ "tls-key" ] ~docv:"PATH"
                    ~doc:"PEM private-key file for TLS (required with --tls-cert).")
in
```

Validation (both or neither):

```ocaml
let tls_cfg = match tls_cert, tls_key with
  | Some c, Some k -> Some (`Cert_key (c, k))
  | None, None -> None
  | Some _, None ->
      Printf.eprintf "error: --tls-cert requires --tls-key\n%!"; exit 1
  | None, Some _ ->
      Printf.eprintf "error: --tls-key requires --tls-cert\n%!"; exit 1
in
```

Pass through to `start_server ~tls:tls_cfg`.

The Python fallback path (storage=sqlite) should also print a warning if
TLS flags are passed — the Python server doesn't currently wire
them. Follow-up: once coder1's doc-side operator flow lands, extend the
Python `c2c_relay_server.py` to parse the same flags, or wire a
reverse-proxy note.

## Contract / regression tests

1. Unit test: `start_server ~tls:(Some (`Cert_key (_, _)))` produces an
   HTTPS listener — inspected via `curl -k https://localhost:PORT/health`.
2. Contract test: swap backends between TLS and non-TLS; existing relay
   contract tests still pass with `Relay_client` pointed at an HTTPS URL.
3. Negative: `Relay_client.make ~url:"http://external.host"` fails when
   `require_tls` guard is on.

Test cert generation for CI — use `openssl req` one-liner in the test
fixture:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout test.key -out test.crt \
  -subj "/CN=localhost"
```

Commit these fixtures to `tests/fixtures/relay_tls/` (not checked in as
actual keys — generated in test setUp).

## Ordering / handoff

1. User approves opam dep install (`tls-lwt mirage-crypto-rng-lwt ca-certs`).
2. Update `dune-project` depends.
3. Apply changes 1-3 to `ocaml/relay.ml` (server side).
4. Apply changes 4-5 to `Relay_client` (client side).
5. Wire CLI flags in `ocaml/cli/c2c.ml`.
6. Add contract + smoke tests.
7. Build via `just install-all`; smoke with a self-signed cert.
8. Update `relay-tls-setup.md` with the exact `c2c relay serve --tls-cert
   ... --tls-key ...` invocation (currently the doc describes intent;
   this closes the loop).

## Notes / decisions

- **No TLS 1.2 fallback.** v1 is TLS 1.3-only; anything weaker is an
  open foot-gun. `Tls.Config.server ~version:(`TLS_1_3, `TLS_1_3)` if
  the default isn't already pinned.
- **No ALPN `h2`.** Layer 2 keeps HTTP/1.1. HTTP/2 is a v1.5
  consideration and needs its own design pass.
- **No mTLS in Layer 2.** Peer identity goes through Layer 3 Ed25519
  (planner1's spec, in progress). This layer is transport-only.
- **No cert rotation hot-reload in v1.** Restart the relay to rotate
  certs; document the expected flow in the operator doc.

## Open questions for coordinator1 / Max

1. Do we want to ship the TLS-enabled relay as a separate binary
   (`c2c-relay-tls`) vs flagging it on the existing `c2c relay serve`?
   Recommend: single binary, opt-in via flags — fewer moving parts.
2. Is the v1 target "OCaml relay with TLS + bearer auth" (deferring
   Ed25519 to Layer 3 as currently planned), or should Layer 2 ship
   with Layer 3 as a single cut-over? Recommend keep separate — Layer 2
   is shippable standalone to Tailscale users, Layer 3 is required
   before public-internet deployment.
3. Certbot integration: do we want c2c to know about certbot
   (`--tls-certbot DOMAIN` auto-resolves `/etc/letsencrypt/live/.../{fullchain,privkey}.pem`),
   or keep it entirely operator-managed via `--tls-cert/--tls-key`?
   Recommend: keep operator-managed in v1; revisit after seeing real
   deployment pain.
