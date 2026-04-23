# Relay testing coverage review — 2026-04-23

## TL;DR

- **P0 bug in test harness**: `ocaml/test/test_relay.ml` (264 lines, 18 core
  InMemoryRelay tests covering register / heartbeat / send / send_all / rooms
  / gc / dead-letter) is **not registered in `ocaml/test/dune`** — it never
  runs. This is the largest coverage hole in the suite; every "test" in that
  file is currently cosmetic. Fix is a ~4-line stanza addition.
- No end-to-end HTTP test exists. Every auth / handler / timestamp-window /
  nonce / body-parse test hits internal helpers or `InMemoryRelay` directly.
  The actual `Cohttp_lwt_unix.Server` dispatch at `relay.ml:2688+` (routes,
  HTTP codes, body parsing, error JSON shape, rate-limiter interaction) is
  untested — regressions there only surface in live smoke tests.
- `relay_sqlite.ml` (929 LoC, the production storage backend) has **zero**
  dedicated tests. `relay_remote_broker.ml` is only tested for one regex
  off-by-one; `fetch_inbox`, `list_remote_sessions`, `poll_once`, and the
  cache module are untested.
- `relay_ws_frame.ml` (frame parser, masking, handshake) has **zero** tests.
- Negative-path coverage on the auth matrix is strong (auth_matrix.ml is
  the best-covered surface). Negative coverage on handlers is weak:
  malformed JSON, partial proof fields, oversized bodies, bad base64 — all
  untested at the handler level.
- Several tests depend on wall-clock (`Unix.sleep 1`, `Unix.gettimeofday`)
  without injectable clocks — latent flake risk, especially on loaded CI.

## Coverage map

| Module | LoC | Direct tests | Coverage (rough) | Biggest gap |
|---|---|---|---|---|
| `relay.ml` (Relay_server + InMemoryRelay + route dispatch) | 3211 | `test_relay.ml` (**unregistered**), `test_relay_auth_matrix.ml`, `test_relay_bindings.ml` | ~35% of public surface; 0% of HTTP dispatch path | No test constructs a real HTTP request and hits `callback`. All handler coverage is indirect via `InMemoryRelay` mutation + `auth_decision` unit. |
| `relay_identity.ml` | 219 | `test_relay_identity.ml` (8 tests) | ~80% | No test for `of_json` missing-field / bad-b64 error branches; happy path dominates. |
| `relay_enc.ml` | 185 | `test_relay_enc.ml` (10 tests) | ~85% | No multi-key concurrent `load_or_generate` test; fsync-crash simulation absent (but probably YAGNI). |
| `relay_signed_ops.ml` | 123 | `test_relay_signed_ops.ml` (7 tests) | ~75% | `verify_history_envelope` only tested for content-mismatch; missing-field / wrong-sig / tampered-ts paths absent. |
| `relay_ratelimit.ml` | 133 | `test_relay_ratelimit.ml` (7 tests) | ~65% | Token-refill / time-based recovery untested (only burst deny). `gc_interval`-driven cleanup path not tested with advanced time. |
| `relay_remote_broker.ml` | 140 | `test_relay_remote_broker.ml` (3 tests) | **~10%** | The test file reimplements the parser locally — it doesn't call `Relay_remote_broker.*` at all. `fetch_inbox`, `list_remote_sessions`, `poll_once`, `update_cache` have no assertions. |
| `relay_sqlite.ml` | 929 | **none** | **0%** | Everything: DDL, prepared statements, `SqliteRelay` implementing `RELAY`, concurrency via `with_lock`, schema version. Only tested by transitive compile. |
| `relay_ws_frame.ml` | 180 | **none** | **0%** | `read_frame` / `write_frame` / masking xor / handshake response. This is bespoke protocol code — highest bug-per-LoC risk in the tree. |

Representative: `test_relay.ml` contains
`test_relay_register_same_alias_different_node_raises_conflict` which
checks the core collision rule; because the file isn't in `dune`, if
someone ever regresses `InMemoryRelay.register`'s conflict branch, nothing
currently catches it.

## Critical gaps

1. **`test_relay.ml` not wired into dune.** The 18 InMemoryRelay tests
   don't execute under `just test-ocaml`. This also means `poll_inbox`
   drain semantics, `send_all` sender-exclusion, `gc` expired-lease
   removal, `leave_room` membership mutation are all effectively
   untested right now even though test code exists.
   *Minimal test to close it*: add a `(test (name test_relay) (modules
   test_relay) (libraries c2c_mcp alcotest yojson unix))` stanza to
   `ocaml/test/dune` and convert `test_relay.ml`'s bespoke runner to
   alcotest (or leave it as-is and register with `(executable`... but
   dune's `test` stanza is simpler — the tests already run standalone).
   *Consequence of regression here*: silent breakage of the core
   message-routing contract; only caught by live dogfooding.

2. **No HTTP integration test.** Every route handler is reached only
   via unit-style calls. The dispatch match at `relay.ml:2688-2790`
   (method × path → handler + error-code shaping) is untested. The
   recent off-by-one bug on `/remote_inbox/` (commit 25dc1b1) and the
   `/list_rooms` 401 regression (commit af2a5f5) would both have been
   caught by a real HTTP test. *Minimal test to close it*: an
   alcotest-lwt case that calls `Relay_server.start` on port 0, hits
   `/health`, `/register` (signed), `/send`, `/poll_inbox`,
   `/remote_inbox/<id>`, `/gc` via `Cohttp_lwt_unix.Client`, and
   asserts status codes + JSON envelope for happy + one malformed body
   case per route.

3. **`relay_sqlite.ml` has no tests.** The production Railway relay is
   deployed with sqlite storage; every InMemoryRelay behaviour has a
   sqlite twin that is totally unvalidated. *Minimal test to close
   it*: apply the existing `test_relay.ml` scenarios to a tmp-dir
   `SqliteRelay.create` via a shared functor over the `RELAY`
   signature — one `Make (R : RELAY)` test module, two instantiations
   (InMemory + Sqlite). *Consequence of regression*: schema drift,
   silent data loss, lease-TTL off-by-one on the live relay; not
   caught by the auth matrix or binding tests.

4. **`relay_ws_frame.ml` has no tests.** Frame-length encoding has
   three size classes (7/16/64-bit length); masking is XOR with a
   rotating 4-byte key; the parser tolerates fragmentation. Any of
   those paths silently corrupting a payload would not be noticed
   until a WS client saw garbage. *Minimal test to close it*: for
   payload lengths `[0; 1; 125; 126; 65535; 65536]` round-trip
   `write_frame` → `read_frame` over an Lwt pipe and assert opcode +
   payload equality; separately, a fixed masked-frame byte sequence
   decoded to a known string.

5. **Signed-op timestamp window is only tested in-proc for register;
   the same check in `verify_room_op_proof` (relay.ml:2263) and
   `send_room` envelope verification (relay.ml:2556) is untested.**
   If one of those three uses ever drifts to a different constant,
   nothing catches it. *Minimal test to close it*: for each of the
   three sites, assert `timestamp_out_of_window` is returned when ts
   is `now + future_window + 10` and `now - past_window - 10`.

## Important gaps

6. **Malformed-body handler tests absent.** `handle_register`,
   `handle_send`, `handle_send_room`, `handle_join_room`, `handle_set_
   room_visibility` all parse JSON with `get_string` / `get_opt_string`
   / `decode_b64url`; none have a test that sends `{}`, `null`, wrong
   type for a field, or non-b64 in `identity_pk`. *Minimal test to
   close it*: a parametrised alcotest case feeding each handler a
   malformed body and asserting the error code is `bad_request` (not
   an unhandled `Invalid_argument`).

7. **Partial-proof branch (`partial_proof`) in register is covered
   only implicitly by `parse_ed25519_auth_missing_field`** which tests
   the Ed25519 *header* parser, not the register *body* path.
   *Minimal test to close it*: call `handle_register` (or post to
   `/register` via the integration harness) with `identity_pk` set
   but `signature` empty; assert `missing_proof_field` code.

8. **Nonce TTL expiry is untested.** `test_nonce_rejects_replay`
   confirms the cache rejects an immediate replay, but nothing verifies
   an old nonce becomes reusable after the TTL — nor that a nonce
   whose `ts` is outside the skew window is rejected *before* the
   cache records it (otherwise an attacker can poison the cache).
   *Minimal test to close it*: inject an old `ts` far outside window,
   call `check_register_nonce`, assert Error AND that the nonce can
   still be used later with a fresh `ts` (not recorded on reject).

9. **Rate-limiter is tested as a module but not wired to HTTP.**
   `Rate_limiter_inst` is instantiated at `relay.ml:1668`; the only
   call is at `relay.ml:2611` for structured logging. Whether the
   limiter actually denies a burst on `/pubkey/*` at the HTTP layer
   is unverified. *Minimal test to close it*: integration test that
   bursts 150 requests at `/pubkey/alice` and asserts ≥50 get 429.

10. **`send_room` without members / with sender not a member / with
    invite-only room and uninvited sender**. `test_relay.ml` covers
    the happy path; the ACL gates (not_a_member / not_invited) have
    no behavioural test. *Minimal test to close it*: register alice,
    set room visibility `invite`, don't invite her, call `send_room`,
    assert `not_invited`.

11. **`handle_remote_inbox` reads from a process-global cache
    (`Relay_remote_broker.get_messages`).** No test verifies the
    cache is namespaced by session_id. If two relays share the
    process, messages could cross. *Minimal test to close it*:
    `update_cache ~session_id:"a" [m1]; update_cache ~session_id:"b"
    [m2]; assert get_messages "a" = [m1]` and no bleed-through.

12. **`canonical_request_blob` / `sorted_query_string` edge cases.**
    Tested with two URIs. Missing: repeated query keys (`?a=1&a=2`),
    percent-encoded keys, empty-value keys (`?flag`). Any asymmetry
    between client and server canonicalisation causes silent 401.
    *Minimal test to close it*: property/table test on 6 URIs
    comparing `sorted_query_string` against a hand-computed expected.

## Minor / nits

- `test_relay_remote_broker.ml` **re-implements** `parse_remote_inbox_path`
  locally instead of calling into `relay.ml` / `relay_remote_broker.ml` —
  the test can pass while the real parser drifts. Replace with a call to
  the real function (or its helper) so regressions are caught.
- `test_lease_is_alive_after_ttl_expires` uses `Unix.sleep 1` with
  `ttl:0.01`. Correct but wall-clock bound; under CPU load could still
  fail. Prefer injecting `~now` into `is_alive` or widening the margin.
- `test_lease_touch_updates_last_seen` uses `Unix.sleep 1` — 2s of the
  suite's runtime. Use `Unix.sleepf 0.05` or an injected clock.
- `test_body_sha256_b64` hard-codes `"ungWv48Bz-pB..."` — correct but a
  large golden. Fine, but one-off brittleness: if base64 alphabet
  changes to `standard`, diff is opaque. Consider an accompanying
  "encode-then-decode-then-compare" check.
- `test_structured_log_json_fields` installs a global `Logs.reporter`
  and tears it down in the same function — if the test throws between
  those lines, the reporter leaks to subsequent tests. Wrap in a
  `Fun.protect`.
- `test_prefix8_truncation` asserts `"abcdefgh"` unchanged for the
  8-char input — correct — but no test for an empty-string input;
  likely fine, but one assert covers it.
- `test_relay_remote_broker.ml`'s `test_ansi_ls_line_parsing` asserts
  `String.trim` on a literal string equals itself; this tests `trim`
  (stdlib), not the remote broker. Delete or point at a real parser.
- The suite has **no `alcotest.run` seed** for `Random.self_init ()` ‑
  ids generated by `Relay_identity.generate` are non-deterministic,
  which is fine but makes failures not reproducible across runs.

## What's strong

- **Auth matrix** (`test_relay_auth_matrix.ml`) is excellent: it
  enumerates the (route-class × credential × dev/prod) product
  deliberately, including the tricky "body-level self-auth" bypass
  rows. This is the model every other surface should copy.
- **Identity / enc on-disk tests** cover the "security-critical"
  concerns nicely: 0600 enforcement, loose-perms refusal, corrupt-JSON
  refusal, tamper-rejection via sign/verify. File-mode tests are a
  strong signal of care.
- **Signed-op roundtrips** correctly exercise both directions
  (client produces proof → server verifies) across four distinct
  sign contexts, including tampering tests and ctx-distinctness
  assertions. These would catch the classic "same blob different
  ctx" cross-route replay bug.
- Deliberate regression test for the `/remote_inbox/` 14-char
  off-by-one (commit 25dc1b1) is exactly the right shape — a named
  test tied to a root-cause. More of this, please.

## Proposed new tests (prioritized)

1. **Register `test_relay.ml` in `dune`.** Non-negotiable; the code
   already exists. *Highest ROI in the tree.*
2. **HTTP integration harness** — `test_relay_http.ml`. Spin up
   `Relay_server.start` on an ephemeral port, exercise 6-8 routes
   end-to-end including one malformed-body case each. Closes gaps 2,
   6, 7, 9.
3. **Functor-ise `test_relay.ml`** over the `RELAY` signature and
   instantiate for both `InMemoryRelay` and `SqliteRelay` (tmp-file
   DB). Closes gap 3; ~50 tests for free over sqlite.
4. **`test_relay_ws_frame.ml`** — round-trip frames across all three
   length encodings + masking. Closes gap 4.
5. **Timestamp-window parity test** across the 3 signed-op sites
   (register, room-op, send-room). Closes gap 5.
6. **Handler negative-case matrix** — one alcotest case per handler
   for (empty body, null field, wrong type, bad b64). Closes gap 6.
7. **Nonce-cache expiry + poisoning test.** Closes gap 8.
8. **Rate-limiter HTTP-layer test** (depends on #2). Closes gap 9.
9. **Room ACL behaviour test** — invite-only enforcement on
   `send_room` / `join_room`. Closes gap 10.
10. **Remote-broker cache namespacing test** — replace the local
    parser re-impl with real calls. Closes gap 11.
11. **Query-canonicalisation edge-cases** (repeated / percent-encoded
    keys). Closes gap 12.
12. **Property-test candidates** (with `alcotest-qcheck` or
    `qcheck-alcotest`): `canonical_msg` round-trip (separator never
    collides with ctx bytes), `sorted_query_string` idempotence,
    `body_sha256_b64` vs a reference SHA256 oracle on random inputs,
    `parse_ed25519_auth_params` fuzzed for malformed header strings
    (no crashes, only `Error`). Each is ~10 lines and closes a class
    of bug rather than a single case.

## Scope of review

- **Files read**: `ocaml/test/test_relay.ml`,
  `ocaml/test/test_relay_auth_matrix.ml`,
  `ocaml/test/test_relay_bindings.ml`,
  `ocaml/test/test_relay_enc.ml`,
  `ocaml/test/test_relay_identity.ml`,
  `ocaml/test/test_relay_ratelimit.ml`,
  `ocaml/test/test_relay_remote_broker.ml`,
  `ocaml/test/test_relay_signed_ops.ml`,
  `ocaml/test/dune`, plus targeted sections of
  `ocaml/relay.ml` (auth_decision, handle_register,
  verify_room_op_proof, handle_remote_inbox, route dispatch,
  Rate_limiter_inst wiring), module headers of
  `ocaml/relay_sqlite.ml`, `ocaml/relay_ws_frame.ml`,
  `ocaml/relay_remote_broker.ml`.
- **Git context**: `git log` for `fix(relay...)` commits and
  `.collab/findings/*relay*` filenames (20+ entries) to identify bug
  classes that would have been caught by tests.
- **Explicitly out of scope** (per prompt): test *quality* style,
  feature completeness of the relay itself, code organisation of the
  source modules.
- **Not run**: no tests executed; assessment is by static reading. The
  `dune` registration claim is verified by grep.
