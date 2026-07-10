# B087-B094 closure audit for `friction-points-cn.md`

Date: 2026-07-10  
Audited base: `c8d5e7c93070058907fa5f342c23c45f63772b2e`  
Scope: B087-B094 only; implementation, help/docs, named tests, and practical local/live proof. A backlog `status: done` was not treated as proof.

## Executive result

`friction-points-cn.md` is **not completely addressed** by B087-B094 at this base.

| Item | Verdict | Short reason |
|---|---|---|
| B087 relay-connect PoW/node/exit | **PASS** | Safe PoW extraction, real host ID, and non-zero one-shot errors are implemented and locally proven. |
| B088 honest remote send | **PASS** | Remote sends say `queued`, JSON says `delivery.state=queued`, and strict mode exits non-zero. |
| B089 unified relay-aware monitor | **PARTIAL** | Works for `relay register`'s `cli-<alias>` inbox, but a bare monitor silently watches the wrong inbox for normal connector-managed registrations. |
| B090 HTTPS subscribe fallback hint | **PARTIAL** | It points to working `relay dm poll`, but still falsely says the B087 bridge is broken. |
| B091 default public relay discovery | **PASS** | Top-level, relay-group, setup help, and onboarding docs expose `https://relay.c2c.im`. |
| B092 old npm installer fallthrough | **PASS** | Capability probe and fresh-install fallthrough are implemented and the four-case shell test passes. |
| B093 relay doctor/capabilities | **FAIL** | Public-TLS output claims `subscribe=yes` although subscribe rejects HTTPS; connector detection is global, required top-level `capabilities --json` is absent, and every emitted docs URL is a live 404. |
| B094 status/whoami relay state | **PARTIAL** | Identity/addressing are surfaced, but a local-only alias is labeled relay-`registered`, there is no connector/connection state, and registration/lease truth is absent unless explicitly probed. |

Closure count: **4 PASS, 3 PARTIAL, 1 FAIL**.

## Inventory traceability

Relevant Part-A rows are:

- B092: A001-A002.
- B091: A005, A019.
- B087: A006-A008.
- B090: A009, A028.
- B088: A011, A042-A050 (immediate honesty is closed; later delivery tracking remains deferred/partial).
- B089: A012-A015, A029-A041.
- B093: A024, A026, A076-A085, A088.
- B094: A020, A027, A054-A056.

Relevant Part-B/C rows that constrain the verdicts include B043/B045/B077/B080/B087-B094, B051/B053/B177-B182/B187/B190/B196, B081/B123/B175/B188, B031-B032/B054/B099-B100/B118/B124/B221-B224/B234/B239-B240/B248, B056, B115, plus C018/C047 (connector), C048 (send), C049 (receive), C055 (doctor), and C056 (fake-relay/live proof). This audit intentionally overturns inventory rows that inferred closure from completed backlog evidence where current execution contradicts the claim, especially B093 capability reality and B089's default connector-managed path.

## Per-item audit

### B087 — PASS: relay connect PoW parsing, node identity, and exit honesty

Implementation evidence:

- `ocaml/c2c_relay_connector.ml:880-915` guards every nested PoW lookup against null/non-object values.
- `ocaml/cli/c2c_relay_cmd.ml:414-421` derives `Host_id.compute_host_hash ()` instead of `unknown-node`.
- `ocaml/c2c_relay_connector.ml:1188-1220` returns 2 for a completed sync with relay errors and 1 for an exception.
- `ocaml/test/test_c2c_relay_connector.ml:360-415` covers null, scalar, missing, malformed, normal success, raw challenge, minted difficulty, and nested retry response shapes.

Verification:

- `just build` -> rc 0.
- `_build/default/ocaml/test/test_c2c_relay_connector.exe` -> rc 0, 24 tests.
- Local PoW-enabled relay, three `relay connect --once --verbose` passes -> rc 0 each, real node `3d08761ae3f3`, no `Yojson Type_error`.
- Dead local URL with a real broker registration -> rc 2; banner used `node=3d08761ae3f3`, not `unknown-node`; stderr said `sync completed with errors: register`.

Remaining proof/robustness gaps, not enough to fail B087's narrow scope:

- No saved production-relay B087 receipt was found; the inventory correctly calls for real-relay smoke and an adverse fake-relay fixture.
- `response_is_rate_limited` and `response_is_pow_retry_failed` still use `Yojson.Safe.Util.member` without the safe-object guard used by `response_difficulty` (`ocaml/c2c_relay_connector.ml:917-925`). A top-level scalar/malformed response can therefore reintroduce the same exception class in the adjacent observation path. Add this to the I005 adverse-response slice.
- Existing `tests/test_c2c_relay_native_subcommands.py` does not prove failed-sync exit status: its dead-URL connect cases use an empty broker, perform no relay operation, and legitimately exit 0.

### B088 — PASS: remote send reports queueing honestly

Implementation evidence:

- `ocaml/cli/c2c_send_cmd.ml:131-162` explains remote queue-only semantics and produces connector-aware warnings.
- `ocaml/cli/c2c_send_cmd.ml:202-214` adds `--fail-if-queued` (exit 3).
- `ocaml/cli/c2c_send_cmd.ml:458-510` emits `queued ->`, structured `delivery.state`, and preserves local `delivered` reporting.
- `docs/commands.md:743` documents remote addressing and strict detection.

Verification:

- `_build/default/ocaml/test/test_c2c_cli.exe test '^send$' 8-11` -> rc 0, four focused tests: human queued/not-ok, JSON queued, strict non-zero, and local delivered.
- The tests also assert the remote-outbox record exists.

Remaining non-blocking gaps:

- Full accepted/delivered/read transition tracking remains deferred under I004/C021-C022; B088 correctly does not claim it.
- JSON retains top-level `"queued": true` even for a local `delivery.state="delivered"` send for compatibility. `delivery.state` is authoritative, but the legacy field is semantically confusing and should be resolved by I002's canonical schema.

### B089 — PARTIAL: relay-aware monitor exists but misses the normal connector inbox

What works:

- `c2c monitor` includes a relay source by default when a relay URL and alias resolve (`ocaml/cli/c2c_monitor_cmd.ml:637-746`).
- It uses non-draining `/peek_inbox`, shares message-ID dedup with the local source, tags JSON with `source=relay`, and retries exceptions.
- `_build/default/ocaml/cli/test_c2c_monitor_logic.exe` -> rc 0, 22 tests.
- `bash scripts/devtest/b089_relay_monitor_live.sh` -> rc 0. A locally registered `cli-rx/cli-rx` relay DM surfaced once, was tagged relay, remained available to `relay dm peek`, and did not repeat on the next cycle.

Decisive failure:

- The default decision hard-codes `node_id=session_id=cli-<alias>` (`ocaml/cli/c2c_monitor_logic.ml:244-281`). That matches one-shot `c2c relay register`, but `c2c relay connect` registers the normal local session under `node_id=<host hash>` and `session_id=<actual session id>` (`ocaml/c2c_relay_connector.ml:666-699`, `981-1005`). The monitor already knows the resolved local session ID and can derive the host ID, but does not use them.
- A live-local reproduction registered `rxconn` through `relay connect` at `aabbccddeeff/sess-rxconn`, queued `connector-managed-message`, then started bare `c2c monitor --alias rxconn --relay-interval 0.5`. The startup banner claimed `relay watch: peek cli-rxconn/cli-rxconn`; after four cycles it emitted **zero** messages and **zero** errors, while direct non-draining peek of `aabbccddeeff/sess-rxconn` contained the message.
- The silence is structural: `extract_relay_messages` treats any response without a `messages` array as an empty healthy inbox (`ocaml/cli/c2c_monitor_logic.ml:177-184`). JSON `ok:false` auth/session errors therefore do not reach the exception logger. This violates A038/B182/B190: a harness cannot distinguish healthy-idle from a dead/misaddressed watcher.

Other incomplete report requirements:

- No `--relay-only` scope (A030/B241).
- No last-success/last-error/reconnected/heartbeat status events (A015, A038-A039).
- JSON is useful NDJSON but lacks the canonical versioned cross-surface contract and full reply address required by I002/A033-A034.
- The live script proves only the `relay register` shape, not the connector-managed golden path, public HTTPS, local+relay same-stream behavior, auth failure, or transient failure/recovery.

Required follow-up slice:

1. Default the relay peek key from the resolved local registration: host ID/node ID plus actual session ID; retain explicit overrides.
2. Parse `ok:false` and terminal auth/identity/session errors as errors, with a machine-readable status event and non-zero terminal exit policy; retain bounded retry/backoff for transient failures.
3. Add connector-managed local-relay integration, public-HTTPS smoke, local+relay same-stream JSON, transient recovery, and auth-fail tests.
4. Add relay-only scope and healthy-idle heartbeat/status metadata, or explicitly disposition those inventory rows.

### B090 — PARTIAL: working fallback, stale false explanation

Evidence:

- HTTPS subscribe exits 1 and points to the working `c2c relay dm --alias <you> poll` path (`ocaml/cli/c2c_relay_cmd.ml:1358-1366`).
- `_build/default/ocaml/test/test_c2c_cli.exe test '^relay_dead_letter$' 3-4` -> rc 0; the monitor help and HTTPS subscribe rejection cases pass.
- `docs/commands.md:980`, `docs/relay-quickstart.md:189`, and `docs/relay-subscribe-daemon.md:34` document polling/monitor alternatives.

Gap:

- Actual output still says: ``note: the `relay connect` bridge is broken against HTTPS relays (B087)``. B087 is fixed and the changelog/docs now advertise connect as working. The fallback itself is no longer a dead end, but this false note recreates operator distrust and contradicts B087/B091/B100.
- The focused test asserts rejection/fallback, but not consistency with capabilities/docs, exactly the open B100/B124/B197 inventory gap.

Required follow-up: remove the stale B087 claim and add one consistency test that compares HTTPS subscribe behavior with doctor capabilities and published help.

### B091 — PASS: default public relay is discoverable

Evidence and verification:

- `ocaml/cli/c2c_relay_cmd.ml:314-329` centralizes `https://relay.c2c.im` and resolution help.
- `c2c --help` prints the public URL and points to `c2c relay` / setup help.
- `c2c relay --help` names the default and the setup -> connect workflow.
- `c2c relay setup --help` names the default in description, example, and `--url` option.
- `docs/get-started.md:137-145` contains the cross-machine setup/send path; README has a relay pointer.
- All manual help probes returned rc 0.

Coverage gap: there is no dedicated help snapshot regression for all three surfaces. This should be added but current behavior meets B091/A005/A019/B056.

### B092 — PASS: old npm binary no longer blocks install

Evidence:

- `docs/install.sh:189-239` probes `c2c --help` for `self-update`, falls through when absent, and also falls through if advertised self-update fails.
- `docs/get-started.md:18` documents that behavior and leads with standalone `~/.local/bin`; npm is presented as an alternative.
- `bash test/test_install_sh_self_update_fallthrough.sh` -> rc 0 for modern delegation, old binary without self-update, advertised-but-failing self-update, and no-c2c fresh install.

Coverage gap:

- The shell test copies the decision block into a harness instead of executing `docs/install.sh` end-to-end with fake release/download commands; it can drift from the installer. Inventory B115/C056 correctly calls for a container/end-to-end old-npm regression. This is additional hardening, not a current functional failure.

### B093 — FAIL: relay doctor is not truthful enough to close the bug

Implemented surface:

- `c2c doctor --relay --json` emits stable check IDs for config, reachability, lease, connector, outbox, and capabilities, plus summaries and non-zero on `FAIL` (`ocaml/cli/c2c_doctor_relay.ml`).
- Outbox depth/oldest age and connector state files are represented.

Decisive failures:

1. **Capabilities contradict real HTTPS behavior.** `check_capabilities` sets subscribe readiness equal to generic relay reachability (`ocaml/cli/c2c_doctor_relay.ml:473-497`) and never accounts for HTTPS/WSS rejection. A live read-only public-relay run returned rc 0 and `send=yes subscribe=yes connect=yes poll=yes (TLS)`, while `c2c relay subscribe --relay-url https://relay.c2c.im ...` exits 1 because TLS WebSocket is unsupported. This violates the core B093/A081/B099-B100/B234 requirement that agents self-configure from reality.
2. **Connector detection is machine-global, not broker/relay scoped.** `detect_connector_processes` uses `pgrep` only (`ocaml/cli/c2c_doctor_relay.ml:56-82`). In an isolated temporary broker with no connector/state, public-relay doctor reported `connector running (2 process(es)); no state file yet` because unrelated c2c connectors existed elsewhere on the machine. That false positive also promoted capabilities to PASS.
3. **Required top-level command is absent.** B093 explicitly requested `c2c capabilities --json`; `c2c capabilities --json` is not registered. Only the nested doctor check exists. If doctor output is the intended equivalent, backlog/docs must say so and the inventory's B222 live-command gate must be corrected.
4. **Every docs URL is broken.** The constant is `https://c2c.im/docs/relay` (`ocaml/cli/c2c_doctor_relay.ml:32`), but no such local page/permalink exists. Live HTTP: `/docs/relay` -> 404; `/relay-quickstart/` -> 200.
5. **No B093 test suite exists.** There are no table-driven healthy/unreachable/auth/expired/stale/outbox/capability tests, no check-ID/schema assertion, no fix-command completeness test, and no capability-vs-attempt test. Some `FAIL` branches also have `fix_command=None` (for example a running connector with a recent state-file error), contrary to “each FAIL”.

Required follow-up slice:

- Make capabilities scheme/implementation aware: HTTPS subscribe must be `no` until WSS exists; distinguish monitor peek, poll, connector, and push.
- Scope connector process/state to broker root, relay URL, and ideally managed instance metadata; stale last-sync must not PASS merely because a PID exists.
- Implement the promised `capabilities --json` or formally make/version doctor JSON the sole surface and update AC/docs.
- Replace docs URLs with published permalinks and test them.
- Add a hermetic table-driven doctor/capability suite covering every check/status/fix and actual transport attempts.

### B094 — PARTIAL: relay identity/addressing shown, connection/registration truth missing

What works:

- `ocaml/cli/c2c_relay_state.ml` supplies shared human/JSON relay blocks with URL, host ID, identity fingerprint/key, optional lease, and addressing guidance.
- `whoami` and `status` include this block; `--relay` opts into a live signed lease lookup.
- `docs/commands.md:740,804` and `docs/relay-quickstart.md:233-267` clearly explain bare local alias versus `<alias>@<host_id>` and discovery commands.

Decisive gaps:

- The human block prints `registered: <local alias> (current session alias)` even when no relay is configured and the alias has never been relay-registered (`ocaml/cli/c2c_relay_state.ml:234-236`). A live isolated run showed `url: (not configured)` immediately followed by `registered: local-only`. JSON more honestly had `configured:false`, `alias:"local-only"`, and `lease:null`, but still has no explicit relay registration state.
- B094 asked for relay **connection state**. Neither status nor whoami includes connector running/last sync/error or receive-path state; only static config/identity and optional lease are shown.
- Default output says lease “not checked”; therefore “registered on relay?” remains unanswered unless the operator knows to pass `--relay`. That is acceptable for offline safety only if the field is labeled `local_alias`, not `registered`.
- No focused B094 tests exist for human/JSON relay blocks, configured/unconfigured state, live/expired/unreachable lease, or address hints.

Required follow-up slice:

- Rename the static field to `local_alias`; add explicit `relay_registration_state: unchecked|registered|not_found|unreachable` and connector/connection state.
- Preserve offline default but make uncheckedness machine-readable; `--relay` should populate a tested lease/registration state.
- Add unit/CLI fixtures for unconfigured, configured-not-registered, live lease, expired lease, unreachable relay, and human/JSON consistency.

## Commands and results

| Command/probe | Result |
|---|---|
| `git rev-parse HEAD` | rc 0, `c8d5e7c93070058907fa5f342c23c45f63772b2e` |
| `just build` | rc 0 (warnings only) |
| relay connector unit executable | rc 0, 24 tests |
| monitor logic unit executable | rc 0, 22 tests |
| B088 focused send cases 8-11 | rc 0, 4 tests |
| B090/monitor-help focused cases 3-4 | rc 0, 2 tests |
| installer fallthrough shell matrix | rc 0, 4 scenarios + modern clean-exit sanity |
| native relay subcommands unittest | rc 0, 16 tests |
| B089 local live script | rc 0, surface/non-drain/dedup PASS |
| B087 local PoW-enabled relay connect x3 | rc 0 each; no type error |
| B087 registered broker -> dead relay | rc 2; real node; clear register failure |
| B089 connector-managed inbox reproduction | probe rc 0; monitor emitted 0 messages/errors while correct inbox held message |
| public `doctor --relay --json` (read-only) | command rc 0; false `subscribe=yes`, false global connector PASS |
| public subscribe preflight | rc 1; working poll hint plus stale false B087 note |
| `curl` published docs URLs | `/docs/relay` 404; `/relay-quickstart/` 200 |
| broad `test_c2c_cli.exe` attempt | rc 1 after 153 tests because `c2c_deliver_inbox.exe` was not built; unrelated to B087-B094. Focused B088/B090 cases were rerun and passed. |

## Minimum additional implementation slices before claiming complete closure

1. **Monitor default-identity and failure-honesty slice** — fix connector-managed keys, surface `ok:false`, define transient/terminal behavior, add local+relay/auth/recovery/public-HTTPS proofs.
2. **Doctor/capabilities truth slice** — scheme-aware matrix, broker-scoped connector state, valid docs links, promised command or formal equivalent, exhaustive fixture tests.
3. **Status/whoami relay-semantics slice** — distinguish local alias from relay registration and add connector/connection state with tests.
4. **Subscribe consistency cleanup** — remove stale B087 note and gate error/help/docs against the capability matrix (may be folded into slice 2).
5. **I005 adverse fake-relay/nightly proof slice** — malformed/null PoW, 401, 429, 5xx, timeout, truncated JSON, schema mismatch, plus named regression receipts. This is needed to close the report's “completely addressed” proof standard even where B087/B088 behavior currently passes.
