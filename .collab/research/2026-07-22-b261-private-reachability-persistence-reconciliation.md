# B261 — private reachability persistence reconciliation after B219

**Purpose:** design input for B262–B267; no protocol behaviour is implemented here.

**Baseline:** B219 is complete on `master` at `fdbb30d8`. This report records the final reviewed persistence contract, not the earlier pre-review B219 branch.

## Outcome

Downstream work can use the provisional sender-bound grant direction from `.collab/research/2026-07-22-relay-private-reachability-threat-model.md`, subject to these load-bearing persistence constraints:

1. Extend `Relay_backend_contract.RELAY` with a shared grant domain API implemented by both `InMemoryRelay` and `SqliteRelay`; do not put grant policy only in HTTP handlers.
2. `SqliteRelay` owns one process-lifetime `Sqlite3.db` connection in `SqliteRelay.t.db`, backed by `<persist_dir>/c2c_relay.db`.
3. Every public SQLite backend operation acquires the non-reentrant `t.mutex` exactly once through `SqliteRelay.with_lock`.
4. Inner workers receive the already-locked `conn` and must never call `with_lock` recursively.
5. Every prepared statement must be finalized on success and exception through `SqliteRelay.with_stmt`, `Relay_sqlite_support.exec_prepared`, or an equivalent `Fun.protect` finalizer.
6. Grant validation, replay/idempotency recording, and inbox enqueue must share one atomic backend operation. A handler-level sequence of separate backend calls is not sufficient.
7. The process-local mutex serialises one relay instance only. Cross-process correctness requires either an enforced single-writer ownership invariant or a SQLite transaction/conditional mutation that remains correct with multiple connections.
8. Schema creation belongs in `Relay_sqlite_support.sqlite_ddl`; compatibility migration runs during `SqliteRelay.create` on the same opened connection before the backend is published.
9. The current probe-plus-`ALTER TABLE` pattern is suitable for additive columns, but multi-table grant rollout needs an explicit schema version/transaction and fail-closed migration state rather than unchecked best-effort `Sqlite3.exec` calls.
10. In-memory and SQLite currently differ in send deduplication and local-send dead-letter behaviour. The new consent admission API must define one identical security result contract and test both backends; it must not inherit these differences accidentally.

## Final B219 interface and ownership contract

### Backend abstraction

`ocaml/relay_backend_contract.ml::RELAY` is the canonical shared interface satisfied by both backends. Relevant existing methods include:

- identity/routing: `register`, `identity_pk_of`, `alias_of_identity_pk`, `alias_of_session`, `enc_pubkey_of`;
- replay: `check_register_nonce`, `check_request_nonce`, `check_revoke_nonce`;
- discovery: `list_peers`;
- delivery: `send`, `send_all`, `poll_inbox`, `peek_inbox`;
- rooms, dead letters, observer/device bindings, pairing, and stats.

The contract exposes policy-shaped operations, not raw database handles. Future grant methods belong here. HTTP code should authenticate/parse and call a backend admission operation whose result determines all subsequent effects.

### SQLite connection lifecycle

The `SqliteRelay.t` record in `ocaml/relay.ml` contains:

- `db_path`, retained for diagnostics/tests/migration context;
- `db : Sqlite3.db`, opened once by `SqliteRelay.create`;
- `mutex : Mutex.t`, guarding every access to the shared connection;
- process-local observer, peer-relay, and relay-identity state.

`SqliteRelay.create` opens `<persist_dir>/c2c_relay.db`, applies `PRAGMA busy_timeout = 5000` and `journal_mode = WAL`, runs `sqlite_ddl`, runs compatibility probes/migrations, and then returns the backend. `SqliteRelay.close` is a private, locked, best-effort hook; no shutdown path calls it, so the connection is currently process-lifetime owned.

### Locking discipline

`SqliteRelay.with_lock` uses a plain non-reentrant `Mutex.t`. Therefore:

- public backend operations lock once;
- helpers such as the post-B219 `release_alias conn` and nonce workers operate on the already-locked connection;
- no inner helper may reacquire the mutex;
- a future `admit_contact conn ...` worker should be lock-free and called by one public `with_lock` wrapper.

Violating this split can deadlock. Opening a per-operation connection to avoid the mutex would reintroduce the B219 failure class and is prohibited.

### Statement lifetime

`SqliteRelay.with_stmt` prepares and finalizes with `Fun.protect`; the caller must already hold `t.mutex`. `Relay_sqlite_support.exec_prepared` likewise finalizes even when parameter binding raises. New grant code must not leave a raw `Sqlite3.prepare` outside an exception-safe finalizer.

Final B219 regression coverage in `ocaml/test/test_relay.ml`:

- `test_relay_sqlite_persistent_connection_stress`;
- `test_relay_sqlite_request_nonce_no_leak_under_load`;
- `test_relay_sqlite_mixed_ops_on_shared_connection`;
- `assert_exec_prepared_finalizes_on_bind_error` within the nonce lifecycle test.

These tests pin lifecycle/finalization, not grant transaction semantics.

## Schema and migration seam

`ocaml/relay_sqlite_support.ml::sqlite_ddl` is the fresh-database schema. `SqliteRelay.create` separately probes older tables using `sqlite_table_has_column` and performs additive `ALTER TABLE` migrations for lease metadata, room visibility/history, and inbox PoW metadata.

This pattern has four implications:

1. New grant tables should be declared in `sqlite_ddl` for fresh state.
2. Additive legacy migration must run before `SqliteRelay.t` is returned.
3. Every probe statement must be finalized, as fixed by B219 review commit `69962411`.
4. Existing migration calls ignore `Sqlite3.exec` results. Consent-gating migration cannot copy that failure posture if a failed or interrupted migration would restore insecure global reachability. B266 needs an explicit durable migration/version state and checked failure handling.

The existing `schema_version` table is declared but is not currently the general migration driver. B263/B266 must decide whether to activate it or add a narrowly scoped durable migration-state mechanism; they must not imply that versioned migrations already exist.

## Atomic admission seam

The required security boundary is not `check_grant` followed later by `send`. That creates revocation and replay races and permits side effects between checks.

The shared backend should expose one policy-shaped operation conceptually like:

```text
admit_contact_delivery :
  backend ->
  verified_sender_principal ->
  presented_grant ->
  message_id ->
  accepted_payload ->
  contact_admission_result
```

The exact B262 type names are not frozen here. The operation must atomically:

1. resolve the stored one-way grant verifier;
2. validate sender/recipient/scope/generation/expiry/active state;
3. enforce message-ID idempotency;
4. insert exactly one recipient inbox row (or deliberately return an admission token consumed in the same locked transaction before any handler effect);
5. return a result that permits secondary push/stats effects only on first acceptance.

For SQLite, use one transaction or one conditional SQL mutation sequence on the already-locked `t.db` connection. A process mutex alone does not prove correctness if two relay processes open the same database. B262 must choose and document either:

- an enforced one-process-per-database invariant plus restart-safe SQL atomicity; or
- multi-connection-safe SQL transactions/constraints.

The latter is safer and is required if operational topology does not enforce exclusive ownership.

## Existing data surfaces downstream work must account for

### Registration and discovery

- Leases in `RegistrationLease.t` and the `leases` table contain alias, session/node identity, liveness, Ed25519/X25519 keys, host ID, version, and OS metadata.
- `list_peers` returns lease objects; `handle_list` serializes them with `RegistrationLease.to_json`.
- Private visibility therefore needs an explicit backend policy/view, not only response-field redaction. Owner/admin/public views should be different operations or explicit view parameters so callers cannot accidentally use the unrestricted list.
- `/pubkey/<alias>` calls alias-indexed identity/key lookup and is an existence oracle for callers admitted by route auth.

### Direct, broadcast, and forwarded delivery

- `RELAY.send` performs alias-targeted inbox insertion.
- `RELAY.send_all` fans out to live leases and bypasses recipient-specific consent today.
- `Relay_server.handle_forward` can deliver source-relay-forwarded content locally.
- Contact-gated recipients must be protected at the common backend admission/routing layer, not by patching only `/send`.
- Handler push, observer/short-queue, and stats effects must occur only after a result that represents first accepted delivery.

### Inbox and message-id behaviour

- SQLite `inboxes.message_id` has no uniqueness constraint; `seen_ids` exists separately but SQLite `send` does not currently provide the same `Duplicate` behaviour as in-memory send.
- In-memory duplicate delivery can still trigger handler pushes because `handle_send` treats `Ok` and `Duplicate` alike.
- Contact delivery therefore needs its own identical cross-backend idempotency contract and tests across restart/concurrency.

### Dead letters

- In-memory local send creates content-bearing dead letters for unknown/dead recipients.
- SQLite local send returns errors without that same insertion; forwarding and explicit dead-letter paths differ again.
- Rejected contact requests must never persist grant/body content in any backend's dead-letter path. Define that as part of the admission result rather than relying on current backend differences.

### Rooms

Room tables and backend methods have their own visibility, roster, invite, knock, and history semantics. Grants are DM-scoped. Room presentation aliases or membership must not become a private-DM route, while the deliberately public/gated/unlisted/private room policies remain otherwise unchanged.

### Replay and rate state

`register_nonces`, `request_nonces`, and `revoke_nonces` are separate persisted tables. Existing signed HTTP request nonces protect exact request replay, but do not prevent a fresh signed request from reusing a message ID. Grant admission needs separate bounded idempotency state tied to the atomic enqueue boundary.

Rate/stat tables count accepted relay activity. Rejected contact attempts should produce bounded non-sensitive reason counters if needed, but must not increment accepted-message statistics or use grant/sender-cardinality labels that leak secrets.

### Pairing

`relay_pairing_token_sql.ml` now finalizes every statement, but its historic select-then-update consumption shape is not proof of cross-process atomic one-time use. Contact grants must not copy this as the atomicity model.

## Deployment, compatibility, and rollback constraints

### Fresh state

Fresh SQLite databases receive grant schema from `sqlite_ddl`. In-memory state must initialise equivalent empty grant stores and identical policy defaults.

### Existing state

Current installations are globally peer-discoverable and accept authenticated alias delivery. A secure migration cannot merely add grants while leaving existing leases and `/send` semantics untouched. B266 must define how existing registrations become private/public and how established contacts are represented. The default must not silently preserve global first contact.

### Rolling and mixed versions

- Old relays do not understand contact grants.
- Old clients can fall back to alias `/send` unless explicitly prevented.
- Mixed versions must return explicit unsupported/insecure-state outcomes; no automatic alias fallback.
- `/send_all` and `/forward` must not bypass private-recipient policy during rollout.
- Health/doctor must distinguish migrated secure production state from tokenless development or incomplete migration.

### Rollback

Rolling back to code that ignores private-recipient/grant state can reopen discovery and delivery. Therefore a database backup is not enough. B266 needs a compatibility floor or durable feature-state marker that old binaries refuse, plus operator recovery guidance. Fail-open downgrade is unacceptable.

### Development mode

Tokenless mode permits unsigned access to peer/admin routes. It cannot substantiate the public private-reachability guarantee. The contact endpoint should refuse tokenless mode unless B262 defines an equally strong explicit test/development identity policy, and diagnostics must label the mode insecure/non-production.

## Required downstream task updates

### B262 — protocol specification

Must decide before implementation:

- stable recipient and sender principal/device-set semantics;
- exact backend admission result and atomicity model;
- single-process ownership versus multi-connection transaction guarantee;
- message-id replay retention/GC;
- verifier choice and any relay-secret lifecycle;
- visibility views and public/established-contact policy;
- `/send_all` and `/forward` semantics;
- compatibility floor/rollback marker;
- confidential production transport for reusable grants;
- whether strict application-layer encrypted contact envelopes are in the first slice.

### B263 — persistence and management

Must:

- extend `RELAY` once with shared domain types and backend operations;
- implement in-memory/SQLite parity;
- add fresh schema to `sqlite_ddl` and checked migration before backend publication;
- use one public lock and lock-free inner workers on `t.db`;
- finalize every statement;
- implement atomic admission/idempotency/enqueue semantics rather than separate check/send calls;
- avoid raw grant persistence/output and define verifier-key lifecycle if keyed hashing is selected.

### B264 — discovery

Must implement explicit private/owner/admin/public views at the backend/domain seam. It must cover lease list, public-key lookup, registration metadata, errors, room side channels, stats/health, and diagnostics without changing deliberate room visibility beyond DM-route leakage.

### B265 — delivery admission

Must gate `send`, `send_all`, and forwarded local delivery before inbox insertion. All secondary effects must depend on first accepted admission. Connector filtering remains defence in depth, not the security boundary.

### B266 — migration and operations

Must use checked, durable, idempotent migration state; refuse unsafe downgrade/rollback; provide explicit lifecycle CLI without printing reusable secrets; and make doctor/health fail or warn decisively for tokenless, legacy-default, incomplete, mixed-version, or insecure-transport production state.

### B267 — audit

Must test both backends, restart, concurrency, migration interruption, mixed versions, direct/broadcast/forward routes, push/stats/dead-letter zero-side-effect rejection, and final B219 lifecycle regressions together.

## Corrections to provisional assumptions

1. B219 is more than “one persistent connection”: its review fixes made exception-safe finalization and process-lifetime ownership explicit. Downstream code must use the final helpers, not the initial branch diff.
2. `schema_version` exists but is not an active general migration framework.
3. Existing process mutex serialization does not prove cross-process transaction atomicity.
4. Existing send idempotency and dead-letter behaviour are not backend-parity precedents.
5. Pairing-token burn is not a safe template for concurrent grant use/revocation.
6. A grant-only endpoint does not close `/send_all`, `/forward`, or old alias `/send` during migration.

## Exact insertion seams (handler → backend)

These are the concrete code points B263–B265 must touch. Line numbers move; symbols are authoritative.

| Surface | Handler / module | Backend call today | Grant-related change |
|---|---|---|---|
| Direct DM | `Relay_server.handle_send` | `R.send` then stats/WS/short-queue/observer | Consent before durable enqueue and before any secondary effect; prefer dedicated contact endpoint plus private-alias rejection on legacy `/send` |
| Broadcast | `Relay_server.handle_send_all` | `R.send_all` then per-recipient observer push | Exclude private/contact-gated recipients unless separately authorised |
| Relay forward | `Relay_server.handle_forward` | peer-relay auth then `R.send` | Destination-verifiable original-sender/grant authority or fail closed before local enqueue |
| Peer list | `Relay_server.handle_list` | `R.list_peers` → `RegistrationLease.to_json` | Private leases absent from ordinary peer view |
| Pubkey | `Relay_server.handle_pubkey` | `R.identity_pk_of` / enc / signed_at / sig | No private-alias existence oracle |
| Inbox | `handle_poll_inbox` / `handle_peek_inbox` | `R.poll_inbox` / `R.peek_inbox` | Unchanged ownership boundary; grants never grant read |
| Rooms | `handle_list_rooms`, `handle_send_room`, knocks | room methods | DM grant scope isolation only |
| Rate limit | `make_callback` → `Rate_limiter_inst.check` | **not** on `RELAY` | Runs before the route handler; defence in depth, but not recipient consent |
| Request nonce | outer peer auth → `R.check_request_nonce` | `request_nonces` | Separate from grant message-id idempotency |
| Pairing burn | mobile-pair handlers | `R.get_and_burn_pairing_token` | Finalize pattern only; not atomic multi-process template |

Post-accept side effects that must not run on grant reject (`handle_send`):
`R.stats_note_message`, `Relay_ws_server.push_dm`, `Relay_short_queue.ShortQueue.push`, `push_to_observers`.

SQLite `send` has no message-id uniqueness / `` `Duplicate `` path today (`seen_ids` table is DDL-only and unused by SqliteRelay). Contact idempotency is greenfield for both backends.

## Evidence index

- Backend contract: `ocaml/relay_backend_contract.ml::RELAY`
- Fresh schema/helpers: `ocaml/relay_sqlite_support.ml::sqlite_ddl`, `exec_prepared`
- Pairing finalize helper: `ocaml/relay_pairing_token_sql.ml::with_stmt`
- Ownership/migration: `ocaml/relay.ml` — `SqliteRelay.t`, `create`, `with_lock`, `with_stmt`, `close`, `sqlite_table_has_column`
- Lifecycle tests: `ocaml/test/test_relay.ml::test_relay_sqlite_persistent_connection_stress`, `test_relay_sqlite_request_nonce_no_leak_under_load`, `test_relay_sqlite_mixed_ops_on_shared_connection`, `assert_exec_prepared_finalizes_on_bind_error`
- Final B219 review fixes: `39342622`, `a4c7aeee`, `a7b751cf`, `69962411`, merged before completion `fdbb30d8`
- Threat model (provisional protocol): `.collab/research/2026-07-22-relay-private-reachability-threat-model.md`

--- SUMMARY ---

- Extend the shared `RELAY` domain contract; do not implement grants as handler-only checks.
- SQLite grant work must use the one process-lifetime `t.db` connection under one non-reentrant lock and finalize every statement.
- Admission, idempotency, and enqueue need one atomic backend operation; current mutex/dedup/pairing patterns do not prove the required concurrency property.
- Fresh schema belongs in `sqlite_ddl`; secure rollout needs checked durable migration/version state beyond existing best-effort column probes.
- Discovery and delivery policy must cover leases, `/pubkey`, `/send`, `/send_all`, `/forward`, and all secondary effects.
- Mixed-version and rollback paths must fail closed; old binaries must not silently reopen global reachability.
