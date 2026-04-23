# Relay security review — 2026-04-23

## TL;DR
Crypto primitives (Ed25519 via mirage-crypto) and the signed-request path are well-built, but the authorization layer has several gaps: the signed-request identity is never bound to the `from_alias` in message bodies (spoofing), the SQLite backend silently overwrites the TOFU identity pinning (trivial takeover), the Bearer token compare is not constant-time, `/remote_inbox/<session>` shells out with a path-traversal-prone path segment, and the token-bucket rate limiter is configured for endpoints (`/pubkey`, `/mobile-pair`, …) that the server does not actually serve — so no real peer route is rate-limited. Read-only room endpoints are also unauthenticated and leak invite-only room metadata and history.

## Critical findings

1. **Signed requests do not bind `from_alias` in body → message spoofing.**
   `relay.ml:2179-2188` (`handle_send`), `:2190-2198` (`handle_send_all`).
   `try_verify_ed25519_request` (`:2533-2581`) verifies the Ed25519 header and returns `Ok (Some alias)` with the *signer's* alias, but `make_callback` discards that alias (`:2660-2664`) and handlers trust the `from_alias` field in the JSON body unchanged. An attacker with a valid identity for alias `A` can send DMs with `from_alias = "B"` — peers see the message as coming from B. Room `send_room` has the bind via `verify_room_send_envelope` comparing `sender_pk` to `identity_pk_of from_alias`, but `/send` and `/send_all` do not. **Fix**: in the `ed25519_verified` branch, thread the verified alias down to every mutation handler and reject requests where `body.from_alias <> verified_alias` (with an explicit allowlist for the self-auth routes that bootstrap via body-level proofs).

2. **SQLite `register` silently overwrites TOFU identity binding.**
   `relay.ml:1014` — the UPSERT is `... ON CONFLICT(alias) DO UPDATE SET ... identity_pk=excluded.identity_pk`, and nothing above the UPSERT checks the prior `identity_pk` column. `InMemoryRelay.register` (`:499-510`) correctly returns `alias_identity_mismatch` when a new pk differs from the bound pk, but the SQLite path has no such check. Combined with finding #3, once the alias's lease is expired and GC'd, the next `/register` from a different identity replaces the binding, and from then on `try_verify_ed25519_request` will happily validate sigs against the new pk. Hijack path: wait for TTL, re-register with attacker's pk, impersonate. **Fix**: before the UPSERT, `SELECT identity_pk FROM leases WHERE alias=?`, and if the row exists with a non-empty pk that differs from the submitted one, return `alias_identity_mismatch`. Also enforce the allowlist check that `InMemoryRelay` performs at `:481-497`.

3. **`/remote_inbox/<session_id>` is path-traversal-prone on the remote host.**
   `relay.ml:2788-2791` → `relay_remote_broker.ml:32-39`. The `session_id` component is taken directly from the URL path and interpolated into `cat %s/inbox/%s.json` via `shell_quote`. `shell_quote` correctly prevents *shell* injection but does nothing about literal path components: a request to `/remote_inbox/..%2F..%2F..%2Fetc%2Fpasswd` (or simply `/remote_inbox/../../../etc/passwd`) resolves to `cat '/broker_root/inbox/../../../etc/passwd.json'` on the remote host, reading arbitrary files that the remote SSH account can read. The route is classified `is_admin` (`relay.ml:1811`), so in a token'd deployment a Bearer token is required, but (a) in dev mode there is no gate, and (b) admin-token compromise is not the only concern — this also enables a relay operator with Bearer to read arbitrary files on the remote broker host, a privilege they shouldn't have. **Fix**: validate `session_id` against a strict regex (e.g. `^[A-Za-z0-9_-]{1,64}$`) before dispatch and reject anything else with 400. Also strip `/`, `.`, NUL.

4. **Bearer token comparison is not constant-time.**
   `relay.ml:1781`: `token' = t` uses OCaml structural equality, which short-circuits on first mismatching byte. Over LAN/Railway network jitter the signal is noisy, but on local Unix sockets or co-tenant infrastructure this is a standard timing side-channel. **Fix**: compare via a constant-time routine (XOR-accumulate over `max(len a, len b)` bytes, or use `Eqaf.equal` from opam).

5. **Token-bucket rate limiter does not cover any real relay endpoint.**
   `relay_ratelimit.ml:57-71` — `policy_of_endpoint` only returns a policy for paths starting with `/pubkey`, `/mobile-pair`, `/device-pair`, `/observer`. None of those routes exist in `relay.ml` (grep the `make_callback` match on `:2684-2794`). Every `/register`, `/send`, `/send_all`, `/send_room`, `/poll_inbox`, `/room_history`, `/list`, etc. hits the `| None -> \`Allow` branch (`relay_ratelimit.ml:106`). **Effect**: an unauthenticated client can flood `/register` (creating garbage leases and consuming dedup table slots), `/send_all` when no token is set, or simply reload `/health` (which also shells out to `git rev-parse` — see minor #2) without any throttle. **Fix**: add policies for the actual peer routes. `/register` and `/send*` should be the priority. Also key by `(ip, path)` not just `ip` to avoid cross-endpoint starvation.

## Important findings

6. **Full body read before auth → unauthenticated DoS by body size.**
   `relay.ml:2651` — `Cohttp_lwt.Body.to_string body` is called before the auth decision. No `Content-Length` cap, no streaming limit. A client can POST 1 GB to `/send` with no credentials; the relay allocates the whole string, hashes it with SHA256, then rejects. **Fix**: enforce a max body size (e.g. 256 KiB for peer routes, 1 MiB for admin), preferably by rejecting large `Content-Length` before reading, and by wrapping body consumption in a byte-bounded reader.

7. **Room read endpoints are fully unauthenticated and leak invite-only rooms.**
   `relay.ml:1805` (`is_unauth` includes `/list_rooms` and `/room_history`) → `handle_list_rooms` (`:2067`) dumps `room_id`, `member_count`, and full `members` alias list for every room regardless of `visibility`. `handle_room_history` (`:2513-2520`) returns history verbatim for any `room_id` including invite-only. An invite-only room's whole transcript is readable by unauthenticated callers who guess/learn the `room_id`. **Fix**: for rooms where `visibility = "invite"`, require signed access and check `is_invited` (or `is_room_member_alias`) before returning history/member lists. For public rooms keep open access.

8. **SqliteRelay opens a fresh DB handle per operation and never closes it.**
   Every method in `SqliteRelay` calls `Sqlite3.db_open t.db_path` and never calls `db_close` or reuses the handle (e.g. `:1032`, `:1047`, `:1073`, `:1088`, `:1104`, `:1125`, `:1143`, …). Under load this leaks file descriptors until `EMFILE`; crashes the relay. Also precludes prepared-statement reuse. **Fix**: open once in `create` and store in `t`; all methods use the shared handle under `t.mutex`. Enable WAL mode once at open time (currently also re-run every op).

9. **Unsigned registration path lets anyone claim a free alias.**
   `relay.ml:2163-2168` — if `identity_pk/signature/nonce/timestamp` are all empty, the handler falls through to `R.register` with no proof. Alias conflict is only detected when an existing lease is `is_alive` (`:512-516`); after TTL expiry, an attacker re-registers and now owns the alias for routing. Only mitigation is the `allowlist` on `start_server`, which must be operator-configured. Combined with finding #2 in SQLite mode the hijack is silent. **Fix**: once any peer has registered an alias with a pk, flip to "signed-only" for that alias in both backends; the binding row should persist past lease TTL (currently `gc` deletes the entire `leases` row, including the pk, `:1225-1228`).

10. **`check_register_nonce` / `check_request_nonce` race in SQLite backend.**
    `relay.ml:1102-1116`, `:1123-1139` — the sequence is DELETE expired → SELECT nonce → INSERT. Two concurrent requests with the same nonce can both pass the SELECT (under WAL, reads don't block) and then both INSERT; the second INSERT fails on `PRIMARY KEY` with an unhandled rc (the `|> ignore` at `:1114`/`:1136` swallows it). Net effect is a small replay window under parallelism, not catastrophic but exploitable if the adversary races. **Fix**: use `INSERT OR ABORT` and treat rc = `CONSTRAINT` as "nonce already seen"; return `Error relay_err_nonce_replay` from that branch. Wrap in `BEGIN IMMEDIATE` for tight correctness.

11. **`handle_heartbeat` and `handle_poll_inbox` trust `node_id`/`session_id` from body.**
    Same class as #1. Any client that learns (or guesses short-form) `(node_id, session_id)` for a peer can drain their inbox. `try_verify_ed25519_request` at the header does not cross-check the body's session identifiers against the signer's registered `(node_id, session_id)`. **Fix**: in signed mode, on `/poll_inbox` and `/heartbeat`, reject if `body.session_id` is not owned by the verified alias (look up via `R.heartbeat` or a new `session_of_alias` helper).

12. **`get_client_ip` returns the TCP peer IP with no proxy awareness — so behind Railway the limiter keys everyone to one bucket.**
    `relay.ml:2583-2599`. Currently this is *safer* than trusting `X-Forwarded-For` (finding #5 notes the limiter doesn't fire anyway), but once rate limits are actually wired, the single-bucket problem becomes a cross-tenant DoS: one noisy tenant locks out all peers on the same Railway egress. **Fix**: when running behind a trusted proxy, key by `X-Forwarded-For` leftmost, but only when a `C2C_TRUST_PROXY=1` env var is set by the operator, and validate the proxy peer IP against an allowlist. Document the default as "direct TCP peer IP".

## Minor / nits

- **m1** `handle_health` shells out to `git rev-parse` on every `/health` hit when `RAILWAY_GIT_COMMIT_SHA` is unset (`relay.ml:2046-2051`). Cache once at startup.
- **m2** `relay_identity.save` writes to a `.tmp` path next to the final file (`:175`) then `rename`s — good — but does not `fsync` the fd before close (`close_out` at `:182`). On power loss the identity file can be zero-bytes. Add `Unix.fsync fd` before `close_out`.
- **m3** `canonical_request_blob` uses `String.uppercase_ascii` on the method but the sorted query string encoding (`relay.ml:96-107`) is not in the spec literal — small risk of client/server mismatch on params with `+`/space handling. Document explicitly.
- **m4** `parse_ed25519_auth_params` splits on `,` without handling quoted values — fine today since all values are b64url-nopad, but a forward-compat hazard if a future field contains `,`.
- **m5** Error messages leak some info: `"no registration for alias %S"` (`relay.ml:1274`) confirms non-existence of an alias to unauthenticated callers (minor enumeration; `/list` leaks the same).
- **m6** `Relay_remote_broker` uses `ssh -o StrictHostKeyChecking=no` (`relay_remote_broker.ml:35,65`) — disables host-key pinning for SSH. MITM on the SSH path is now possible. Should require an operator-provided `known_hosts`.
- **m7** `handle_admin_unbind` logs full alias via `Printf.printf "audit: ..."` (`relay.ml:2077`). Fine, but ensure stdout is captured into a durable log in production; otherwise audit trail is gone on restart.
- **m8** `invite_room` / `uninvite_room` accept `invitee_pk` as any non-empty string (`relay.ml:2357-2360`, `:2375-2377`) without validating it's 43-char b64url-nopad of a 32-byte key. Garbage pks end up pinned in `room_invites` and are unmatchable — denial of admission. Add a b64-shape check.
- **m9** `/gc` is a GET (`relay.ml:2701`) that mutates state (evicts leases, prunes inboxes). Bearer-gated, but still violates HTTP semantics and makes browser/crawler navigations destructive if a token ever leaks into a browser URL bar. Change to POST.

## What's strong

- **Crypto is right**: Ed25519 via `mirage-crypto-ec` is constant-time; sig and pk length checks in `Relay_identity.verify` (`relay_identity.ml:83-88`) fail closed on wrong size.
- **Canonical signing blobs** use a spec-tagged context (`c2c/v1/register`, `c2c/v1/request`, …) and a 0x1F unit separator (`relay_identity.ml:14,90-91`), preventing cross-protocol signature reuse.
- **Nonce + timestamp windows** are applied consistently on all signed paths; register/room windows (120s/30s, 600s TTL) and request windows (30s/5s, 120s TTL) are tight.
- **All SQL is parameterised** — no string-concatenated user input into queries in `relay.ml` or `relay_sqlite.ml`. No SQL injection surface.
- **Identity file on-disk hygiene**: `Relay_identity.save` forces `0700` parent dir and `0600` file; `load` refuses to read a file with loose perms (`relay_identity.ml:197-203`) — mirrors ssh.
- **Structured rate-limit logs** redact to 8-char prefixes (`relay_ratelimit.ml:52-54,75-88`), so ingress logs don't preserve full source IPs or pubkeys.
- **Env-gated rollouts**: `C2C_REQUIRE_SIGNED_ROOM_OPS` lets operators tighten room-op auth without a code change, and the signed-registration path is non-breaking to legacy clients.

## Scope of review

Files read with exact line refs above: `relay.ml` (3211 LOC, read roughly 1:2800 covering RELAY module type, both backends, auth + route handlers, client), `relay_identity.ml` (219 LOC, full), `relay_signed_ops.ml` (123 LOC, full), `relay_ratelimit.ml` (133 LOC, full), `relay_remote_broker.ml` (140 LOC, full), `relay_sqlite.ml` (partial 1:200 — DDL + helper pattern; the SqliteRelay methods mirror those in `relay.ml`'s inlined SqliteRelay and the findings about per-op `db_open` and UPSERT of `identity_pk` apply equally). `relay_enc.ml` and `c2c_relay_connector.ml` were listed in scope but not opened within the ~1500 LOC effective depth bound — treat any X25519 or connector findings as "needs verification".
