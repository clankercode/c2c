# friction-points-cn inventory — part B

Scope: `friction-points-cn.md:967-1985` only. The enclosing first heading is
`# Agent-Harness Integration Contract` at line 966; line 1985 ends mid-sentence,
so material beginning at line 1986 is deliberately excluded.

Audit date: 2026-07-10. This is an inventory, not an implementation change.

## Classification and authority

- `CLOSED`: current code/docs plus a completed backlog item substantively satisfy
  the normalized requirement.
- `PARTIAL`: a useful subset exists, but the source requirement is broader or its
  exact named proof is absent.
- `OPEN`: a pending backlog item or a current-surface gap directly tracks it.
- `DEFERRED`: a pending backlog item records an explicit Max/team decision to
  postpone it; that decision outranks this earlier proposal.
- `PROPOSAL`: only this source range requires it; no matching backlog authority
  was found. Coordinator/product triage is required before implementation.
- `CONSTRAINT`: milestone scope boundary, sequencing rule, or product invariant;
  closure means the current plan respects it, not that code was added.

Authority order used here: current canonical repo contracts and completed code /
tests > explicit backlog decisions > this 2026-07-07 proposal. Targeted discovery
used the codebase knowledge graph first, then literal/non-code searches as allowed
by `AGENTS.md`. “No exact test” means the exact source-proposed test name was not
found outside `friction-points-cn.md`; related tests may still exist.

## Evidence catalog

- `E01 ENV-DOC`: session precedence and the named variables are documented in
  `.collab/runbooks/c2c-env-vars.md:11-68` and `docs/commands.md:1126-1139`.
- `E02 I007`: `.backlog/ideas/I007-north-star-deferred-harness-ad.todo:1-16`
  is pending and explicitly defers full thin-adapter unification until canonical
  JSON and identity attestation land.
- `E03 I002`: `.backlog/ideas/I002-canonical-versioned-message-js.todo:1-15`
  is pending; it narrows v1 to current fields plus `delivery.state` and defers
  identity/trust/priority fields.
- `E04 B087`: completed B087 and `docs/changelog.md:20-24`; malformed PoW shape
  coverage exists at `ocaml/test/test_c2c_relay_connector.ml:360-414`.
- `E05 B088`: completed B088 and `docs/changelog.md:25-28`; honest remote-send
  tests exist at `ocaml/test/test_c2c_cli.ml:771-835`.
- `E06 B089`: completed B089 and `docs/changelog.md:29-31`; relay source,
  non-draining dedup, and gating tests exist at
  `ocaml/cli/test_c2c_monitor_logic.ml:192-314`; current flags are `--no-relay`
  / `--relay-interval`, not the proposal's `--relay-only` naming.
- `E07 B090`: completed B090 and `docs/changelog.md:32-34`; HTTPS/WSS fallback
  now points to relay DM polling.
- `E08 B093`: completed B093 and `docs/changelog.md:42-44`;
  `ocaml/cli/c2c_doctor_relay.ml:310-510,598-645` supplies structured checks,
  capability reporting, fix commands, JSON, and non-zero-on-FAIL.
- `E09 B098`: completed B098 and `docs/changelog.md:55-58`; the bus-never-RPC
  invariant and remote-message negative proof are at
  `ocaml/cli/test_c2c_approval_paths.ml:517-619`.
- `E10 B099`: completed B099 and `docs/changelog.md:59-61`; canonical skill
  framing and its Claude embedded gate are at
  `ocaml/cli/test_c2c_claude_skill_embedded.ml:252-289`.
- `E11 SCHEDULE`: native TOML schedules, idle gating, and self-DM firing are
  documented at `.collab/runbooks/agent-wake-setup.md:63-147` and implemented
  in `ocaml/c2c_schedule_fire.ml:1-35` / `ocaml/cli/c2c_setup.ml:1711-1747`.
- `E12 I003`: `.backlog/ideas/I003-deferred-trust-tiers-tofu-pinn.todo:1-15`
  explicitly defers trust tiers, TOFU, and priority gating.
- `E13 I004`: `.backlog/ideas/I004-deferred-delivery-read-receipt.todo:1-15`
  explicitly defers receipts / `send --wait` pending push and cursors.
- `E14 I005`: `.backlog/ideas/I005-fake-relay-fixture-regression.todo:1-16`
  is pending and tracks the fake relay, adverse fixtures, named P0 regressions,
  and CI-vs-nightly split.
- `E15 B100`: completed B100 and `docs/changelog.md:62-63`; the cross-machine
  alpha quickstart is `docs/relay-quickstart.md`.
- `E16 SITE`: current site hero/alpha/local flow are at `docs/index.md:1-64`;
  current flat navigation is `docs/_config.yml:22-34`; the proposed full
  Diátaxis IA is not present.
- `E17 MONITOR-SCHEMA`: current monitor JSON is documented at
  `docs/monitor-json-schema.md:20-211`, including `source=local|relay`; it is not
  the pending project-wide canonical message schema in I002.
- `E18 B092`: completed installer-fallthrough work is documented at
  `docs/changelog.md:38-41`; the source suite's exact named installer test was
  not found.
- `E19 I008`: `.backlog/ideas/I008-identity-model-machine-key-as.todo` records
  machine-key trust anchor + optional per-agent attestation, implementation
  deferred; it supersedes the source's unresolved binary choice.
- `E20 RELAY-E2E`: related two-broker connector roundtrip coverage exists in
  `tests/test_c2c_remote_send_e2e.py:181-251`, but not under the milestone's
  exact proposed test names and not as the complete I005 fake-relay oracle.
- `E21 REFERENCE`: current generated/runtime-oriented command material exists in
  `docs/commands.md`; curated reference entry points are `docs/reference/index.md`
  and `docs/reference/{identifiers,rooms,scopes}.md`.

## Agent-Harness Integration Contract inventory

| ID | Source heading + lines | Normalized requirement | Implementation / backlog evidence | Disposition + authority | Dependencies | Required tests / docs / live proof | Closure |
|---|---|---|---|---|---|---|---|
| B001 | Principle 971-981 | One c2c core exposes a stable contract; every harness adapter is a thin binding. | E02 | DEFERRED by I007 (Max/team), despite source wording. | I002, I008. | Cross-adapter conformance suite and architecture docs. | DEFERRED |
| B002 | Environment contract 985-993 | Resolve identity in order: `C2C_MCP_SESSION_ID`, harness-native ID, persisted fallback. | E01 | CLOSED for documented/current resolution. | Harness exports. | Golden precedence tests across all harnesses. | CLOSED |
| B003 | Environment contract 995-1002 | Publish the six listed auto-register/room/relay/broker variables. | E01 | CLOSED for docs; no single introspection output. | None. | Docs drift check for env dictionary. | CLOSED |
| B004 | Environment contract 1004-1008 | Provide `c2c env --json`. | E02; no command found. | DEFERRED as part of I007. | Stable env resolver. | CLI contract test + JSON fixture. | DEFERRED |
| B005 | Environment contract 1010-1012 | Env JSON identifies the current agent. | E02; `whoami --json` is related, not the requested aggregate. | DEFERRED with B004. | B004. | Assert resolved alias/session and provenance. | DEFERRED |
| B006 | Environment contract 1010-1013 | Env JSON identifies the selected broker. | E02, E01. | DEFERRED aggregate; underlying resolver is documented. | B004. | Explicit/default/cross-repo broker fixtures. | DEFERRED |
| B007 | Environment contract 1010-1014 | Env JSON identifies the selected relay. | E02; E08 reports relay separately. | PARTIAL; aggregate command deferred. | B004, relay config. | Saved/env/flag precedence fixtures. | PARTIAL |
| B008 | Environment contract 1010-1015 | Env JSON reports registration state. | E02; current `whoami`/doctor cover related state. | PARTIAL; aggregate command deferred. | B004, registry. | Registered/unregistered fixtures. | PARTIAL |
| B009 | Canonical message/event JSON 1021-1025 | One versioned schema covers send results, poll/monitor events, and MCP returns. | E03. | OPEN; I002 is authoritative and narrower for v1. | Existing JSON surface inventory. | Schema validator across all three surface classes. | OPEN |
| B010 | Canonical message/event JSON 1027-1052 | Schema includes the shown envelope, identity, routing, safety, reply, and delivery fields/enums. | E03, E17. | PARTIAL; I002 defers identity/trust/priority fields. | I008, I003, receipts. | Published schema + positive/negative vectors. | PARTIAL |
| B011 | Canonical message/event JSON 1054 | Streaming monitor uses NDJSON; batch poll uses arrays. | E17; batch-wide canonical schema pending E03. | PARTIAL. | I002. | Stream line parser and poll-array schema tests. | PARTIAL |
| B012 | Tool / MCP schema 1060-1074 | Define the listed logical toolset once, with identical names/parameters, generated from one published JSON Schema. | E02; current MCP and pi names remain parallel. | DEFERRED by I007. | I002, adapter generators. | Schema equality tests for every adapter. | DEFERRED |
| B013 | Tool / MCP schema 1076 | Tool returns use canonical message JSON. | E03, E02. | OPEN behind I002/I007. | B009, B012. | Validate every generated tool return. | OPEN |
| B014 | Prompt framing 1080-1081 | Ship one canonical prompt/skill fragment and inject it through every adapter. | E10; only Claude embedded gate was located. | PARTIAL: canonical fragment done; every-adapter proof incomplete. | Adapter installers. | Per-adapter install/transcript tests. | PARTIAL |
| B015 | Prompt framing 1082-1084 | Fragment states peer messages are untrusted third-party data, not instructions. | E10. | CLOSED by B099. | None. | Embedded/copy sync gates for all adapters. | CLOSED |
| B016 | Prompt framing 1082-1085 | Fragment teaches self-identification. | E10. | CLOSED in canonical fragment. | `whoami`. | Assert every installed fragment contains current recipe. | CLOSED |
| B017 | Prompt framing 1082-1086 | Fragment teaches `alias@hostid` addressing. | E10; B094 in changelog. | CLOSED substantively. | Relay identifiers. | Adapter content gates + docs link. | CLOSED |
| B018 | Prompt framing 1082-1087 | Fragment explains trust tiers. | E10, E12. | DEFERRED for real tiers; current framing says aliases are not authority. | I003/I008. | Trust model docs and enforcement vectors when enabled. | DEFERRED |
| B019 | Prompt framing 1082-1088 | Fragment states FYI does not mean act-on. | E10. | CLOSED by B099. | None. | Content sync gate. | CLOSED |
| B020 | Prompt framing 1082-1089 | Fragment includes a verb cheat-sheet. | Canonical c2c skill has core command tables; E10. | CLOSED substantively. | Command registry drift control. | Generated/checked command examples. | CLOSED |
| B021 | Monitor/send wrappers 1095-1101 | Provide `c2c monitor --json` as the receive primitive. | E06, E17. | CLOSED. | Relay config for relay source. | CLI help and JSON smoke. | CLOSED |
| B022 | Monitor/send wrappers 1103-1105 | Monitor emits canonical NDJSON. | E17, E03. | PARTIAL: NDJSON exists; project-wide canonical schema pending. | I002. | Schema validator per output line. | PARTIAL |
| B023 | Monitor/send wrappers 1103-1106 | Monitor watches local plus relay. | E06. | CLOSED, relay-aware by default when configured. | Relay URL + alias. | Local+relay same-stream integration. | CLOSED |
| B024 | Monitor/send wrappers 1103-1107 | Monitor output is line-buffered. | Current monitor is streaming; no exact source-named proof found. | PARTIAL. | CLI runtime. | PTY/pipe buffering regression. | PARTIAL |
| B025 | Monitor/send wrappers 1103-1108 | Monitor supports heartbeat events. | No direct matching current proof located; schedules are E11. | PROPOSAL. | Event schema decision. | Offline timer test and docs. | OPEN |
| B026 | Monitor/send wrappers 1103-1109 | Monitor auto-reconnects. | Relay watcher retries, but no exact contract proof found. | PARTIAL. | Relay failure policy. | Drop/recover integration with backoff. | PARTIAL |
| B027 | Monitor/send wrappers 1103-1110 | Monitor exits non-zero on terminal failure. | Auth/identity terminal semantics not found under exact proposed test. | OPEN under I005/M1 tests. | Error taxonomy. | Auth failure exit-code test. | OPEN |
| B028 | Monitor/send wrappers 1114-1120 | `c2c send --json` returns canonical delivery-state JSON. | E05; canonical envelope pending E03. | PARTIAL: truthful `delivery.state` closed, canonical schema open. | I002. | Send schema validation for queued/accepted/delivered. | PARTIAL |
| B029 | Managed push/transcript injection 1124-1134 | Define one documented hook contract and one idle/wake schedule format; existing hook/schedule pieces bind it. | E11, E02. | PARTIAL: schedule contract exists; cross-harness hook contract deferred. | I007. | Per-harness transcript injection + schedule conformance. | PARTIAL |
| B030 | Managed push/transcript injection 1136 | Approval injection is local-operator/supervisor-only and unreachable by remote peers. | E09. | CLOSED by canonical safety invariant. | Supervisor binding. | Negative remote-message regression remains mandatory. | CLOSED |
| B031 | Capability negotiation 1140-1146 | Provide `c2c capabilities --json` or equivalent doctor output. | E08. | CLOSED via doctor capability check / command surface recorded by B093. | Relay probe. | JSON contract and reality cross-check. | CLOSED |
| B032 | Capability negotiation 1148-1150 | Report working receive paths: poll/subscribe/connect. | E08. | CLOSED substantively. | Live/configured relay scheme. | Fake + real transport matrix. | CLOSED |
| B033 | Capability negotiation 1148-1151 | Report available tools. | E08 reports relay capabilities, not the full harness tool inventory. | PARTIAL. | Tool registry. | Compare reported set to actual invocation. | PARTIAL |
| B034 | Capability negotiation 1148-1152 | Report relay scheme and constraints. | E08. | CLOSED. | URL scheme. | HTTPS/http fixtures and real probe. | CLOSED |
| B035 | Versioning/conformance 1158-1160 | Put `schema_version` on wire messages. | E03. | OPEN, explicitly retained in pending I002. | Schema v1. | Schema validator rejects missing version. | OPEN |
| B036 | Versioning/conformance 1158-1161 | Publish JSON Schemas. | E03. | OPEN. | B035. | Publication/drift gate. | OPEN |
| B037 | Versioning/conformance 1158-1162 | Publish conformance test vectors. | E02, E14. | OPEN; fake relay/adapters pending. | I002, I005. | Vector runner against core and adapters. | OPEN |
| B038 | Versioning/conformance 1158-1165 | Publish a checklist enabling adapter self-verification before release. | E02. | DEFERRED by I007. | B036-B037. | Self-check command in CI. | DEFERRED |
| B039 | Meta recommendation 1169-1180 | Prevent N divergent bridges using env introspection, canonical JSON, generated tools, shared prompt, monitor JSON, and one hook contract; keep adapters thin. | E02, with safety subset E10 and receive subset E06. | DEFERRED umbrella; subsets independently closed/partial. | B004, B009, B012, B014, B021, B029. | End-to-end adapter conformance matrix. | DEFERRED |

## Implementation Roadmap inventory

| ID | Source heading + lines | Normalized requirement | Implementation / backlog evidence | Disposition + authority | Dependencies | Required tests / docs / live proof | Closure |
|---|---|---|---|---|---|---|---|
| B040 | Prioritization rule 1189-1192 | Sequence correctness/safety, then setup usability, then hardening/polish. | Completed B087-B100 followed this order. | CONSTRAINT respected by current backlog. | None. | Backlog ordering review. | CLOSED |
| B041 | Prioritization rule 1193-1196 | Treat canonical message JSON as a dependency hub and sequence it early. | E03. | OPEN/high-priority idea. | JSON surface inventory. | I002 acceptance suite. | OPEN |
| B042 | Prioritization rule 1193-1196 | Resolve identity granularity before the trust stack. | E19, E12. | CONSTRAINT resolved in design, implementation deferred. | I008 before I003. | ADR + attestation/trust tests when built. | DEFERRED |
| B043 | P0 #1 1202-1208 | `relay connect` resolves a real node rather than `unknown-node`. | E04. | CLOSED by B087. | Host/node resolver. | Connector identity regression. | CLOSED |
| B044 | P0 #1 1202-1212 | PoW parser matches actual relay response and handles null/malformed shape. | E04. | CLOSED for parser guard. | Relay contract/version. | Fake adverse fixture + real relay nightly. | PARTIAL |
| B045 | P0 #1 1208-1210 | Caught sync exceptions cause non-zero exit, never silent exit 0. | E04. | CLOSED by B087 implementation; exact suite-wide guard still open. | Error propagation. | Connector exit test + global swallowed-exception audit. | PARTIAL |
| B046 | P0 #2 1214-1220 | Remote send reports `queued` versus `accepted` truthfully. | E05. | CLOSED for queued/delivered states; relay-ack semantics remain schema work. | Connector state. | State matrix test. | CLOSED |
| B047 | P0 #2 1218-1222 | Warn when no connector is live. | E05. | CLOSED. | Connector detection. | No-connector CLI test. | CLOSED |
| B048 | P0 #3 1225-1232 | Ship/inject untrusted-data prompt framing. | E10. | CLOSED by B099, subject to all-adapter proof gap B014. | Adapter installers. | Per-adapter content tests. | PARTIAL |
| B049 | P0 #3 1229-1232 | Remote peer cannot reach approval/PreToolUse paths. | E09. | CLOSED by B098. | Supervisor/local verdict model. | Mandatory negative regression. | CLOSED |
| B050 | P0 #3 1234 | Lock in “message bus, never RPC”; no message directly triggers action. | E09 and canonical `CLAUDE.md` safety note. | CLOSED as architecture invariant. | None. | Security review for every new approval-like path. | CLOSED |
| B051 | P0 #4 1236-1250 | Ship at least one supported HTTPS production-relay receive path: fixed connector or first-class polling monitor. | E06, E07. | CLOSED via relay-aware monitor/polling. | Relay identity/config. | Live HTTPS receive smoke. | CLOSED |
| B052 | P1 #5 1256-1265 | Define canonical versioned message JSON early, including `schema_version`. | E03. | OPEN. | B041. | I002 schema suite. | OPEN |
| B053 | P1 #6 1267-1276 | Unified `monitor --json` combines local+relay, relay-by-default, on canonical schema. | E06, E17, E03. | PARTIAL: sources unified; canonical schema pending. | B051, B052. | Same-stream schema test. | PARTIAL |
| B054 | P1 #7 1278-1282 | Relay-aware doctor/capabilities; every FAIL includes `fix_command`. | E08. | CLOSED by B093. | Relay probe. | Inject each failure and assert fix. | CLOSED |
| B055 | P1 #8 1284-1288 | Publish cross-machine golden-path quickstart. | E15. | CLOSED by B100. | Working honest commands. | Follow verbatim on two hosts. | CLOSED |
| B056 | P1 #8 1284-1288 | Surface relay URL in `relay setup --help`. | `docs/changelog.md:35-37` (B091). | CLOSED. | Default relay constant. | CLI help snapshot. | CLOSED |
| B057 | P1 #9 1290-1296 | Resolve whether `identity_pk` is per-agent or per-host before pinning. | E19. | CLOSED as decision: machine trust anchor + optional agent attestation. | None. | Promote to ADR and keep docs aligned. | CLOSED |
| B058 | P1 #9 1290-1298 | Surface identity and implement TOFU pinning after the granularity decision. | Identity surfacing closed by B094/B097; E12 defers TOFU. | PARTIAL/DEFERRED. | I008, I003. | Key-change and allowlist tests. | DEFERRED |
| B059 | P2 #10 1304-1308 | Implement trust tiers plus rate/spam limits. | E12; PoW/rate-limit work exists separately. | DEFERRED for trust tiers. | I008. | Tier enforcement + abuse/load tests. | DEFERRED |
| B060 | P2 #10 1304-1308 | Cap unknown peers at FYI. | E12. | DEFERRED by I003. | Trust classification. | Unknown-peer priority negative test. | DEFERRED |
| B061 | P2 #10 1304-1308 | Trust-gate interrupt and `--blocking`. | E12. | DEFERRED by I003. | B060. | Unknown denied; allowlisted accepted. | DEFERRED |
| B062 | P2 #11 1310-1318 | Add delivery/read receipts and `send --wait[=accepted&#124;delivered&#124;read]`. | E13. | DEFERRED by I004. | Push transport, server cursors/acks. | Privacy-preserving receipt E2E. | DEFERRED |
| B063 | P2 #11 1318-1320 | Design at-least-once and cursor semantics before shipping receipts. | E13. | CONSTRAINT explicitly preserved. | Relay protocol design. | Model/property tests for loss/duplication. | DEFERRED |
| B064 | P2 #12 1322-1336 | Unify adapters with generated tools, shared prompt, hook contract, and vectors over one core. | E02. | DEFERRED by I007. | I002, I008; safety fragment already E10. | All-adapter conformance. | DEFERRED |
| B065 | P2 #13 1338-1340 | Add debug bundle, address cards/tokens, and unified discovery. | No matching single backlog item; I006 tracks relay discovery only. | PROPOSAL / partially captured. | Identity/address format. | Product spec + privacy/security review. | OPEN |
| B066 | Cross-cutting 1342-1344 | Version canonical JSON now to preserve adapter evolution. | E03. | OPEN/high priority. | I002. | Version compatibility tests. | OPEN |
| B067 | Cross-cutting 1342-1345 | Identity granularity gates trust tiers. | E19, E12. | CONSTRAINT respected. | I008 before I003. | ADR/backlog dependency link. | CLOSED |
| B068 | Cross-cutting 1342-1346 | Deliberately choose canonical HTTPS receive transport because it shapes monitor/adapters. | E06 records polling/peek as current canonical. | CLOSED for current phase; push deferred. | Relay constraints. | Live HTTPS smoke and docs. | CLOSED |
| B069 | Cross-cutting 1342-1347 | Version relay PoW/auth/cursor wire contracts before risky coordinated changes. | PoW work exists; canonical event/cursor schema still E03/E13. | PARTIAL. | I002/I004. | Fake-vs-real drift tests. | PARTIAL |
| B070 | Cross-cutting 1342-1348 | Document bus-never-RPC as foundational, not configurable. | E09. | CLOSED. | None. | Security invariant review. | CLOSED |
| B071 | Only three before dogfood 1350-1352 | Ship a working, honest bridge. | E04 plus current relay docs/E20. | PARTIAL: fixed connector path exists, live proof must remain. | Prod relay. | Two-host live connector smoke. | PARTIAL |
| B072 | Only three before dogfood 1350-1353 | Ship honest send plus one real receive path. | E05, E06. | CLOSED. | Relay config. | Two-host send/receive proof. | CLOSED |
| B073 | Only three before dogfood 1350-1354 | Ship safety framing plus approval lockdown. | E09, E10. | CLOSED. | Adapter distribution. | Safety regressions. | CLOSED |

## Test and Conformance Suite inventory

| ID | Source heading + lines | Normalized requirement | Implementation / backlog evidence | Disposition + authority | Dependencies | Required tests / docs / live proof | Closure |
|---|---|---|---|---|---|---|---|
| B074 | Governing rule 1365-1369 | Every dogfood bug becomes a named regression test. | E14 pending; only some named/related tests exist. | OPEN. | Bug catalog. | One-to-one bug/test audit. | OPEN |
| B075 | Governing rule 1367-1369 | Hermetic in-process fake relay is executable spec and canonical schema is shared oracle. | E14, E03. | OPEN. | I005 + I002. | CI fake-relay suite. | OPEN |
| B076 | Unit/CLI 1371-1377 | CI covers argument parsing. | Broad existing CLI tests; no source-specific gap backlog. | PARTIAL/ongoing quality gate. | Command registry. | Per-command parse matrix. | PARTIAL |
| B077 | Unit/CLI 1371-1378 | CI covers exit codes. | Related B087/B088 tests; global discipline absent. | PARTIAL. | Error taxonomy. | Success/failure exit matrix. | PARTIAL |
| B078 | Unit/CLI 1371-1379 | Every subcommand's `--json` validates against published schema. | E03 pending. | OPEN. | I002. | Enumerate JSON commands + schema validation. | OPEN |
| B079 | Unit/CLI 1371-1380 | CI detects wire/schema drift. | No canonical event schema yet. | OPEN. | E03. | Golden/generated schema drift gate. | OPEN |
| B080 | Unit/CLI 1382-1386 | Failure paths return non-zero and no command swallows exceptions into exit 0. | B087 fixed one instance; exact global named test absent. | PARTIAL. | Command audit. | `test_no_command_exits_zero_on_caught_exception`. | OPEN |
| B081 | Unit/CLI 1388-1391 | Remote send without connector reports queued/warns and never unqualified `ok`. | E05. | CLOSED. | None. | Existing B088 tests remain. | CLOSED |
| B082 | Fake relay 1393-1399 | Fake relay implements register/PoW. | E14. | OPEN. | Relay contract. | Register/PoW fixture vectors. | OPEN |
| B083 | Fake relay 1393-1400 | Fake relay implements DM send/poll. | E14. | OPEN. | Relay contract. | Send/poll roundtrip. | OPEN |
| B084 | Fake relay 1393-1401 | Fake relay implements list. | E14. | OPEN. | Relay contract. | List fixture. | OPEN |
| B085 | Fake relay 1393-1402 | Fake relay implements status. | E14. | OPEN. | Relay contract. | Status fixture. | OPEN |
| B086 | Fake relay 1393-1403 | Fake relay implements rooms. | E14. | OPEN. | Relay contract. | Room lifecycle fixture. | OPEN |
| B087 | Adverse fixtures 1407-1409 | Fake relay serves malformed/null PoW, including difficulty-off-null. | E14; unit parser shapes E04 are not relay fixture. | OPEN. | B082. | Full connector failure fixture. | OPEN |
| B088 | Adverse fixtures 1407-1410 | Fake relay serves 401 unauthorized. | E14. | OPEN. | Auth fixture. | Client exit/error assertion. | OPEN |
| B089 | Adverse fixtures 1407-1411 | Fake relay serves 429 rate-limit. | E14. | OPEN. | Rate-limit fixture. | Retry/backoff assertion. | OPEN |
| B090 | Adverse fixtures 1407-1412 | Fake relay serves 5xx. | E14. | OPEN. | Server-error fixture. | Retry/non-silent failure assertion. | OPEN |
| B091 | Adverse fixtures 1407-1413 | Fake relay serves slow/timeout behavior. | E14. | OPEN. | Clock/timeouts. | Bounded timeout/backoff test. | OPEN |
| B092 | Adverse fixtures 1407-1414 | Fake relay serves truncated JSON. | E14. | OPEN. | Parser. | Graceful parse failure test. | OPEN |
| B093 | Adverse fixtures 1407-1415 | Fake relay serves schema-version mismatch. | E14, E03. | OPEN. | Published schema/version policy. | Compatibility/rejection test. | OPEN |
| B094 | Fake relay 1417 | Malformed/null PoW makes connector fail gracefully and non-zero, not Yojson-crash. | E04 related parser test; exact connector fixture pending E14. | PARTIAL. | B087. | Exact named connector regression. | PARTIAL |
| B095 | Fake relay 1419 | Run identical vectors against fake in CI and real relay nightly. | E14. | OPEN. | Stable vector runner, real secrets. | CI/nightly parity report. | OPEN |
| B096 | Relay integration 1421-1427 | Test register → list → DM send → poll plus receipt. | E20 covers related roundtrip; receipt semantics deferred E13. | PARTIAL/DEFERRED receipt. | Fake relay, receipts. | Flow test with explicit state. | PARTIAL |
| B097 | Relay integration 1425-1428 | Test rooms end-to-end. | Existing relay room tests exist; I005 fake oracle pending. | PARTIAL. | Fake relay rooms. | Fake + nightly real room lifecycle. | PARTIAL |
| B098 | Relay integration 1425-1429 | Test cross-host using two brokers on one fake relay. | E20 is related two-broker coverage; I005 exact fixture pending. | PARTIAL. | Fake relay. | Exact two-broker test. | PARTIAL |
| B099 | Transport matrix 1431-1434 | Assert `capabilities --json` matches actual behavior. | E08 capability reporting; exact reality test absent. | PARTIAL. | Executable probes. | `test_capabilities_matches_reality`. | OPEN |
| B100 | Transport matrix 1431-1434 | HTTPS/WSS subscribe is either supported/tested or fails with documented error consistent with capabilities/docs. | E07 fixes hint; exact named consistency test absent. | PARTIAL. | E08 capability schema. | Subscribe/capabilities/docs consistency test. | PARTIAL |
| B101 | Delivery probe 1436-1440 | Send a unique self-marker and assert arrival to guard “ok but nothing delivered.” | Related live/e2e scripts; no exact canonical gate located. | PARTIAL. | Relay/live environment. | Fake CI + live nightly marker. | PARTIAL |
| B102 | Adapter conformance 1442-1449 | Given canonical message JSON, adapters expose identical logical tool schemas. | E02, E03. | DEFERRED/OPEN. | I002/I007. | Tool-schema vectors. | DEFERRED |
| B103 | Adapter conformance 1442-1450 | Adapters resolve identity identically. | E01 docs; no all-adapter vector suite. | PARTIAL. | Harness env simulation. | Cross-adapter precedence vectors. | OPEN |
| B104 | Adapter conformance 1442-1450 | Adapters inject identical canonical prompt framing. | E10 proves canonical/Claude; all-adapter suite absent. | PARTIAL. | Adapter installers. | Install artifact comparison for 5 clients. | PARTIAL |
| B105 | Adapter conformance 1452-1457 | Conformance covers Claude Code, pi, Codex, and kimi adapters. | E02 lists broader set including OpenCode. | DEFERRED by I007; source list itself omits OpenCode. | I007. | Five-client matrix, using current canonical reach. | DEFERRED |
| B106 | Env golden 1459-1469 | Golden-test `c2c env --json` precedence: explicit, harness-native, persisted. | E01 documents precedence; command deferred E02. | DEFERRED. | B004. | Simulated-env golden tests. | DEFERRED |
| B107 | Safety invariant 1471-1474 | Every adapter injects untrusted-data framing. | E10; exact all-adapter named test absent. | PARTIAL. | Adapter artifacts. | `test_adapter_injects_untrusted_data_framing` per adapter. | PARTIAL |
| B108 | Safety invariant 1471-1474 | Negative test proves no adapter lets remote messages reach approval/PreToolUse action. | E09 proves core path; adapter matrix absent. | PARTIAL. | Adapter approval hooks. | Per-adapter negative E2E. | PARTIAL |
| B109 | Schema drift 1476-1478 | Generated tool schemas equal canonical source. | E02. | DEFERRED by I007. | I002. | Generated-file sync gate. | DEFERRED |
| B110 | Chaos 1480-1486 | Relay drop mid-sync reconnects with backoff, no loss/duplication, heartbeat emitted. | No matching complete test located. | PROPOSAL/I005-adjacent. | Connector retry model. | Nightly chaos test. | OPEN |
| B111 | Chaos 1480-1487 | Two watchers on one alias have defined ownership and no silent double-consume. | E06 non-draining peek/dedup mitigates; full ownership test absent. | PARTIAL. | Inbox consumption semantics. | Two-process race test. | PARTIAL |
| B112 | Chaos 1480-1488 | Connector-down outbox growth is diagnosed, then recovery drains in order. | E08 reports outbox; existing outage tests related. | PARTIAL. | Connector/outbox. | Nightly outage/recovery ordering test. | PARTIAL |
| B113 | Chaos 1480-1489 | Lease expiry mid-session gracefully re-registers or clearly errors. | E08 diagnoses lease; recovery test not located. | PARTIAL. | Relay lease model. | Real-TTL/nightly test. | OPEN |
| B114 | Chaos 1480-1490 | Large payload/flood exercises rate-limit plus dead-letter behavior. | Existing rate/relay work related; no suite match. | PARTIAL. | PoW/rate-limit/DLQ. | Nightly load/flood test. | OPEN |
| B115 | Install/upgrade 1492-1500 | Old c2c lacking `self-update` falls through gracefully during `install.sh`. | E18. | CLOSED behavior; exact proposed named test absent. | Installer fixture. | Container install regression. | PARTIAL |
| B116 | Install/upgrade 1502-1507 | Containerized matrix covers fresh, npm, binary, and PATH-shadowed installs. | No complete matrix evidence located. | PROPOSAL. | Release artifacts/containers. | Four matrix jobs. | OPEN |
| B117 | Install/upgrade 1509 | Test checksum verification with and without SHA tools. | Installer verifies checksums; exact dual-path test not located. | PARTIAL. | Platform tool matrix. | Container tests for present/absent SHA tools. | OPEN |
| B118 | Doctor tests 1511-1516 | `doctor --json` gives `fix_command` for every known failure. | E08. | CLOSED for B093 relay failure catalog; “every known” remains ongoing. | Failure catalog. | Catalog completeness audit. | PARTIAL |
| B119 | Doctor tests 1513-1518 | Inject every fake-relay failure and assert the correct FAIL/fix. | E14 pending. | OPEN. | I005, E08. | Table-driven failure injection. | OPEN |
| B120 | CI split 1520-1530 | Every PR runs offline unit/CLI, schema, exit, fake-relay, adapter, install, and doctor suites. | Several subsets exist; E03/E14/E02 remain pending. | PARTIAL. | B075-B119. | CI workflow job inventory. | PARTIAL |
| B121 | Nightly split 1532-1539 | Nightly runs real-relay drift, chaos, two-host, load/perf, and real-TTL lease expiry. | No complete current matrix located. | PROPOSAL. | Secrets/hosts/flaky policy. | Scheduled workflow with retained evidence. | OPEN |
| B122 | Named regressions 1541-1543 | Add `test_relay_connect_null_pow_challenge_exits_nonzero`. | Exact name absent; related E04 parser test only. | OPEN under I005. | Fake relay. | Exact connector/exit regression. | OPEN |
| B123 | Named regressions 1541-1544 | Add `test_send_remote_no_connector_reports_queued`. | Exact name absent; equivalent E05 tests exist. | CLOSED substantively. | None. | Preserve equivalent B088 cases or alias exact name. | CLOSED |
| B124 | Named regressions 1541-1545 | Add `test_subscribe_https_url_clear_error_matches_capabilities`. | Exact name absent; E07 behavior exists. | PARTIAL. | E08. | Add consistency test. | OPEN |
| B125 | Named regressions 1541-1546 | Add `test_relay_list_requires_alias`. | Exact name absent. | PROPOSAL. | Relay auth semantics. | Add/triage named regression. | OPEN |
| B126 | Named regressions 1541-1547 | Add `test_install_over_old_npm_falls_through`. | Exact name absent; E18 behavior done. | PARTIAL. | Installer fixture. | Add exact/equivalent container regression. | OPEN |
| B127 | Named regressions 1541-1548 | Add `test_no_command_exits_zero_on_caught_exception`. | Exact name absent. | OPEN. | Command audit. | Static/dynamic exit discipline test. | OPEN |
| B128 | Named regressions 1541-1549 | Add `test_adapter_injects_untrusted_data_framing`. | Exact name absent; Claude equivalent E10. | PARTIAL. | Adapter matrix. | Add per-adapter vector. | OPEN |
| B129 | Named regressions 1541-1550 | Add `test_remote_message_cannot_reach_approval_path`. | Exact test exists twice; E09. | CLOSED. | Supervisor binding. | Keep mandatory security regression. | CLOSED |

## Product and Website Positioning inventory

| ID | Source heading + lines | Normalized requirement | Implementation / backlog evidence | Disposition + authority | Dependencies | Required tests / docs / live proof | Closure |
|---|---|---|---|---|---|---|---|
| B130 | Summary 1563-1567 | Lead product story with cross-machine, cross-harness peer dogfood proof. | E16 leads local simplicity; cross-host is below fold. | PROPOSAL/product decision. | Verified proof artifact. | Landing copy review + link to reproducible demo. | OPEN |
| B131 | Headline 1569-1573 | Use “c2c — the messaging layer for AI agents” and inbox/cross-session/machine/harness lead. | E16 uses “Instant Messaging” / “Simple DMs.” | PROPOSAL; current site copy differs. | Product owner approval. | Copy/SEO/OG consistency review. | OPEN |
| B132 | 30-second pitch 1575-1579 | Explain user value: replace manual copy/paste with agent handoff/questions/coordination. | E16 partially conveys messaging, not this full pitch. | PARTIAL/product copy. | Landing redesign. | Human comprehension review. | OPEN |
| B133 | 30-second pitch 1581-1583 | Give harness authors a distinct pitch: bind one neutral contract for cross-harness reach. | E02 defers contract; E16 mentions five clients but no author track. | DEFERRED technically; copy PROPOSAL. | I007. | Harness-author landing section. | DEFERRED |
| B134 | Core mental model 1585-1592 | Explain alias+inbox, local broker, optional relay, and DM/broadcast/rooms. | E16 “How It Works” covers broker/send/receive/extras. | CLOSED substantively. | None. | Docs link/check. | CLOSED |
| B135 | Core mental model 1593-1595 | State agents are peers, not endpoints; messaging is autonomous reasoning, not RPC. | E09 canonical safety; landing does not foreground it. | CLOSED invariant / PARTIAL positioning. | None. | Prominent security/product copy. | PARTIAL |
| B136 | What c2c is not 1597-1599 | Explicitly say c2c is not RPC/command channel. | E09; not prominent on site. | CLOSED architecture / PARTIAL website. | None. | Security/concepts page. | PARTIAL |
| B137 | What c2c is not 1597-1600 | Explicitly say local-first, not hosted SaaS; relay optional. | E16 hero says local-first/no local server. | CLOSED. | None. | Site copy regression. | CLOSED |
| B138 | What c2c is not 1597-1601 | Explicitly say c2c is not an agent framework/orchestrator. | No prominent current page located. | PROPOSAL/product docs. | None. | Concepts/about copy. | OPEN |
| B139 | What c2c is not 1597-1602 | Explicitly say c2c is agent-first, not a human chat app. | Current docs are agent-oriented; exact statement absent. | PARTIAL. | None. | Product copy. | OPEN |
| B140 | What c2c is not 1597-1603 | Explicitly say verified provenance is not a trust oracle for content. | E09/E10 imply this; exact website statement absent. | PARTIAL. | Identity docs. | Security page. | OPEN |
| B141 | Why now 1605-1610 | Explain parallel agents, harness fragmentation, swarm plumbing, and urgent data-not-instructions safety. | Pieces exist across docs; no consolidated section located. | PROPOSAL/product copy. | Product IA. | “Why now” section review. | OPEN |
| B142 | CTA 1612-1617 | Golden path first proves local messaging. | E16 starts with local flow. | CLOSED. | None. | Fresh-install smoke. | CLOSED |
| B143 | CTA 1612-1617 | Golden path then connects machines via relay. | E15 and E16 relay links. | CLOSED. | Relay quickstart. | Two-host live proof. | CLOSED |
| B144 | Honesty note 1619-1623 | Position c2c explicitly as alpha and avoid overstated reliability. | E16 alpha status + E15 limitations. | CLOSED. | Status maintenance. | Docs drift/status review. | CLOSED |
| B145 | Above-fold 1625-1627 | Use the proposed “agents write code / c2c lets them talk” sentence above fold. | E16 uses different hero. | PROPOSAL/product decision. | Product owner approval. | Copy test. | OPEN |

## Website / Docs Information Architecture inventory

| ID | Source heading + lines | Normalized requirement | Implementation / backlog evidence | Disposition + authority | Dependencies | Required tests / docs / live proof | Closure |
|---|---|---|---|---|---|---|---|
| B146 | Principles 1636-1641 | Separate tutorial/how-to/explanation/reference using Diátaxis. | E16 shows a flat page list, not explicit four-way IA. | PROPOSAL. | Docs migration plan. | Link/content-type audit. | OPEN |
| B147 | Principles 1636-1641 | Treat agent/machine navigability as first-class via `llms.txt`, inline schemas, stable anchors. | `llms.txt` and anchors exist; inline canonical schemas pending E03. | PARTIAL. | I002. | Agent retrieval/deep-link test. | PARTIAL |
| B148 | Landing flow 1643-1647 | Hero has one-liner, cross-harness proof, and primary Quickstart CTA. | E16 hero one-liner/client list; no explicit primary CTA/proof. | PARTIAL. | Product copy. | Rendered-page visual/content review. | OPEN |
| B149 | Landing flow 1643-1648 | Show two-column value proposition for users vs harness authors. | Not present in E16. | PROPOSAL. | I007 messaging. | Responsive visual review. | OPEN |
| B150 | Landing flow 1643-1649 | Show mental-model diagram: peers/inboxes/broker/relay/DM-room-broadcast. | E16 has cards, not diagram. | PROPOSAL. | Design asset. | Visual accessibility review. | OPEN |
| B151 | Landing flow 1643-1650 | Show copy-pasteable “Local in 2 commands” teaser. | E16 has a longer local command block. | PARTIAL. | Valid shortest flow. | Fresh shell copy/paste smoke. | PARTIAL |
| B152 | Landing flow 1643-1651 | Include “what it is / is not.” | Not a dedicated landing section. | PROPOSAL. | B136-B140. | Content review. | OPEN |
| B153 | Landing flow 1643-1652 | Provide secondary CTAs to Concepts, Integrate, GitHub. | GitHub/config and docs links exist; Concepts/Integrate tracks do not. | PARTIAL. | IA tracks. | Link checker. | OPEN |
| B154 | Landing flow 1643-1653 | Add subtle site-wide alpha banner linking a status page, near top but outside hero. | E16 has hero status block; no site-wide status-page banner. | PARTIAL / source placement differs. | Status page. | All-layout render check. | OPEN |
| B155 | Start here nav 1659-1666 | Tutorials include intro, local quickstart, cross-machine quickstart, and first conversation. | E16 has index/get-started/connect/relay quickstart, labels differ. | PARTIAL. | Navigation restructure. | Nav/link coverage. | PARTIAL |
| B156 | Concepts nav 1668-1677 | Concepts cover mental model, broker-vs-relay, identity/addressing, rooms/broadcast, delivery states, and prominent security model. | Overview/reference pages cover subsets; no dedicated security model page. | PARTIAL. | I002/I003 for delivery/trust. | Concept-page inventory. | OPEN |
| B157 | How-to nav 1679-1688 | How-to guides cover cross-machine, monitor, rooms, relay registration/self-host, memory/schedules, and review/handoff/swarm recipes. | Pages/runbooks cover many, not as one public track. | PARTIAL. | Docs IA migration. | Task-success audit. | OPEN |
| B158 | Integrate nav 1690-1697 | Dedicated harness-author track covers contract overview, five harness setups, adapter+vectors, and message schema. | Client delivery/matrix exist; contract/schema/vector track deferred E02/E03. | DEFERRED/PARTIAL. | I002/I007. | Harness-author journey test. | DEFERRED |
| B159 | Reference nav 1699-1708 | Generated reference covers every CLI flag, MCP tools, message/doctor/capability schemas, env, exits, relay HTTP API. | E21 has strong CLI/reference subsets; not all listed generated artifacts. | PARTIAL. | Code generation + I002. | Generated-source drift gate. | OPEN |
| B160 | Troubleshooting nav 1710-1715 | Troubleshooting includes doctor guide, symptom→cause→fix, centralized limitations/status, and FAQ. | Known issues and inline tables exist; no clearly centralized complete track. | PARTIAL. | Status page. | Broken-path routing audit. | OPEN |
| B161 | About nav 1717-1721 | About includes roadmap, changelog, and contributing. | Changelog exists; roadmap/contributing nav not found. | PARTIAL. | Public roadmap policy. | Link/nav audit. | OPEN |
| B162 | IA decisions 1723-1725 | Local and cross-machine quickstarts are separate, explicitly labelled nav items. | E16 has Get Started, Connect, Relay Quickstart; labeling not exact. | PARTIAL. | Nav redesign. | First-time navigation test. | PARTIAL |
| B163 | IA decisions 1723-1726 | Security model is a prominent Concepts page linked high. | E09/E10 content exists; public prominent page absent. | PROPOSAL. | Security doc synthesis. | Link/placement review. | OPEN |
| B164 | IA decisions 1723-1727 | Harness authors get Integrate track; canonical JSON cross-links Integrate/Reference. | E02/E03 deferred/open. | DEFERRED. | I002/I007. | Cross-link test. | DEFERRED |
| B165 | IA decisions 1723-1728 | Generate reference from CLI/schemas, do not hand-maintain. | Commands include generated/runtime material but docs remain mixed; E21. | PARTIAL. | Generator ownership. | Drift gate. | OPEN |
| B166 | IA decisions 1723-1729 | Every rough edge routes to a workaround; subscribe→polling and relay-connect→working path. | E07 and E15 do this for current relay rough edges. | CLOSED for cited examples; ongoing docs rule. | Known-limitations catalog. | Link/status drift test. | CLOSED |
| B167 | IA decisions 1723-1730 | Expand `llms.txt`, inline schemas, and stable anchors so agents answer tasks without source reading. | `llms.txt` exists; schemas pending E03. | PARTIAL. | I002. | Agent retrieval benchmark. | PARTIAL |
| B168 | Alpha caveats 1732-1736 | Create one specific “What works today / known limitations” page. | `docs/known-issues.md` exists, but exact status consolidation is incomplete. | PARTIAL. | Status ownership. | Status/feature-matrix consistency audit. | PARTIAL |
| B169 | Alpha caveats 1732-1737 | Site-wide subtle banner links to status, never in hero headline. | E16 status is hero metadata, not requested placement. | PROPOSAL/conflicts current placement. | B168. | Layout render review. | OPEN |
| B170 | Alpha caveats 1732-1738 | Use targeted inline callouts only on rough features, each pointing to a working alternative. | E07/E15 substantively implement relay examples. | CLOSED as current docs practice. | Working fallback. | Broken-link/command smoke. | CLOSED |
| B171 | Alpha caveats 1732-1739 | Pair limitations with roadmap/momentum. | No systematic current status-to-roadmap pairing found. | PROPOSAL. | Public roadmap. | Content audit. | OPEN |
| B172 | Net recommendation 1743-1745 | Adopt the combined Diátaxis/two-quickstart/security/Integrate/generated/machine-readable/status-page IA. | E16/E21 show partial pieces only. | PROPOSAL umbrella; duplicates B146-B171. | All IA rows. | Full information-architecture review. | OPEN |

## First Milestone: Honest Cross-Machine DM Loop inventory

| ID | Source heading + lines | Normalized requirement | Implementation / backlog evidence | Disposition + authority | Dependencies | Required tests / docs / live proof | Closure |
|---|---|---|---|---|---|---|---|
| B173 | Goal 1762-1764 | A new user follows cross-machine quickstart verbatim and reliably sends/receives with truthful status and no silent failures. | E04-E07, E15. | PARTIAL: implementation/docs done; exact AC/nightly proof incomplete. | Prod relay. | Verbatim two-host run with saved receipt. | PARTIAL |
| B174 | In scope #1 1768-1772 | Remote send reports `accepted` when relay acknowledged. | E05 exposes delivery states; direct ack semantics need canonical schema/live proof. | PARTIAL. | Live connector/relay ack. | Accepted-state integration. | PARTIAL |
| B175 | In scope #1 1768-1773 | Remote send reports `queued` plus explicit warning when connector absent. | E05. | CLOSED. | Connector detection. | Existing B088 tests. | CLOSED |
| B176 | In scope #1 1775 | Never bare `ok`; `--json` exposes `delivery.state`. | E05. | CLOSED. | None. | Existing queued/json/fail-if-queued tests. | CLOSED |
| B177 | In scope #2 1777-1787 | First-class relay polling monitor polls on an interval. | E06; command shipped as configured default with interval flags, not `--relay`. | CLOSED substantively / naming superseded. | Relay URL/alias. | Interval fixture. | CLOSED |
| B178 | In scope #2 1785-1788 | Emit each new relay DM as one line. | E06. | CLOSED substantively. | Dedup state. | Multi-message line framing test. | CLOSED |
| B179 | In scope #2 1785-1789 | No hand-rolled poll/jq/sleep loop is needed. | E06, E15. | CLOSED. | First-class monitor. | Quickstart smoke. | CLOSED |
| B180 | In scope #2 1785-1790 | Relay monitor is line-buffered. | No exact buffering proof found. | PARTIAL. | CLI stream. | Pipe/PTY buffering regression. | OPEN |
| B181 | In scope #2 1785-1791 | Relay monitor survives transient poll errors. | Retry behavior exists but exact test absent. | PARTIAL. | Error retry policy. | Inject one transient then recovery. | OPEN |
| B182 | In scope #2 1785-1792 | Relay monitor exits non-zero on auth/identity failure. | Exact test absent. | OPEN. | Terminal error classification. | Proposed auth-fail test. | OPEN |
| B183 | In scope #3 1794-1799 | Every relay error yields non-zero exit. | E04 closes connector case, not proven command-wide. | PARTIAL. | Relay command audit. | Exit matrix. | OPEN |
| B184 | In scope #3 1794-1799 | Every relay error yields a clear human message. | B087/B090 improved cases; no command-wide proof. | PARTIAL. | Error catalog. | Snapshot failure messages. | PARTIAL |
| B185 | In scope #3 1801 | Malformed/null PoW never stack-crashes or exits 0; if bridge remains broken, fail loudly and point to working path. | E04, E07. | CLOSED behavior; full fake connector regression still E14. | Relay response fixture. | Exact B122 test + live malformed probe. | PARTIAL |
| B186 | In scope #4 1803-1805 | HTTPS/WSS subscribe hint points to monitor/polling, not broken connector. | E07. | CLOSED; actual fallback is relay DM poll. | None. | Hint/capabilities consistency test. | PARTIAL |
| B187 | AC1 1807-1809 | Host A relay-DM send reaches B through monitor within one poll interval. | E20 related; exact test absent. | PARTIAL. | Fake/real relay + monitor. | Exact CI fake + nightly real test. | OPEN |
| B188 | AC2 1807-1810 | No-connector send prints queued/not-ok, warns with command, JSON queued, and script can detect non-delivery. | E05; strict detection is opt-in `--fail-if-queued`. | CLOSED with documented opt-in exit. | None. | Preserve B088 triple. | CLOSED |
| B189 | AC3 1807-1811 | Null/malformed PoW connect exits non-zero with human cause; no Yojson crash/exit0/unknown-node. | E04. | PARTIAL: behavior closed, exact full connector fixture absent. | I005. | Exact B122 regression. | PARTIAL |
| B190 | AC4 1807-1812 | Relay monitor emits each DM, survives transient failure, exits non-zero on auth failure. | E06 covers emission/dedup; resilience/exit exact proof absent. | PARTIAL. | Error fixtures. | Exact proposed monitor test. | OPEN |
| B191 | AC5 1807-1813 | HTTPS/WSS subscribe error points to working receive path, not connector. | E07. | CLOSED behavior; exact named test absent. | None. | B124 consistency regression. | PARTIAL |
| B192 | Tests fixture 1815-1821 | Minimal fake relay fixture covers register/PoW, DM send/poll, and status. | E14. | OPEN. | I005. | Fixture self-tests. | OPEN |
| B193 | Tests 1823-1825 | Add `test_two_brokers_one_relay_dm_roundtrip`; fake in CI, real nightly. | Exact name absent; E20 related. | OPEN. | B192. | Exact dual-environment vector. | OPEN |
| B194 | Tests 1823-1826 | Add `test_send_remote_no_connector_reports_queued`. | Exact name absent; E05 equivalent tests. | CLOSED substantively. | None. | Keep equivalent cases. | CLOSED |
| B195 | Tests 1823-1827 | Add `test_relay_connect_null_pow_exits_nonzero`. | Exact name absent; E04 partial. | OPEN. | Fake PoW response. | Full process exit test. | OPEN |
| B196 | Tests 1823-1828 | Add `test_monitor_relay_emits_and_exits_nonzero_on_auth_fail`. | Exact name absent. | OPEN. | Auth fixture. | Add exact test. | OPEN |
| B197 | Tests 1823-1829 | Add `test_subscribe_https_hint_points_to_working_path`. | Exact name absent; E07 behavior done. | PARTIAL. | None. | Add exact/equivalent assertion. | OPEN |
| B198 | Docs 1831-1833 | Add cross-machine quickstart using honest commands. | E15. | CLOSED. | Honest send/monitor. | Verbatim live smoke. | CLOSED |
| B199 | Docs 1831-1834 | Subscribe/connect pages state current status and point to working monitor/poll path. | E07/E15; some current docs still recommend connector where appropriate. | PARTIAL/current behavior evolved. | Accurate live status. | Docs drift audit. | PARTIAL |
| B200 | Docs 1831-1835 | Document queued vs accepted send states. | E05 changelog/docs. | CLOSED substantively. | None. | Command docs search/snapshot. | CLOSED |
| B201 | Docs 1831-1836 | Add relay failure behaviors to symptom→fix table. | E15 quickstart contains troubleshooting; exact two entries need audit. | PARTIAL. | Current commands. | Table coverage review. | PARTIAL |
| B202 | Out of scope 1838-1840 | M1 does not require full rich broker↔relay auto-sync; honest failure is sufficient. | E04 fixed more than minimum; no violation. | CONSTRAINT satisfied/superseded by repair. | None. | Scope note only. | CLOSED |
| B203 | Out of scope 1838-1841 | M1 does not require WSS subscribe; polling is supported path. | E07/E06. | CONSTRAINT satisfied. | None. | Capability/docs consistency. | CLOSED |
| B204 | Out of scope 1838-1842 | M1 only adds minimal send JSON delivery state, not project-wide schema. | E05; E03 remains pending. | CONSTRAINT satisfied. | I002 later. | No premature schema claims. | CLOSED |
| B205 | Out of scope 1838-1843 | Trust tiers, priority gating, receipts/wait, and identity pinning remain later. | E12/E13/E19. | DEFERRED by explicit backlog authority. | I008 before I003; push/cursors before I004. | Deferred acceptance docs. | DEFERRED |
| B206 | Out of scope 1838-1844 | M1 can ship relay-only mode before unified local+relay monitor. | Current E06 already unifies configured relay with local. | SUPERSEDED by broader B089 implementation. | None. | Current default monitor tests. | CLOSED |
| B207 | Out of scope 1838-1845 | Harness unification, MCP changes, and doctor-relay are later slices. | Doctor already E08; harness remains E02. | PARTIAL/SUPERSEDED. | I007. | Track separately. | PARTIAL |
| B208 | Definition of done 1847-1849 | Cross-machine quickstart is verbatim-followable and works. | E15; no saved current two-host proof attached here. | PARTIAL. | Prod relay. | Fresh two-host transcript/receipt. | PARTIAL |
| B209 | Definition of done 1847-1850 | `delivery.state` is truthful. | E05. | CLOSED. | None. | State matrix. | CLOSED |
| B210 | Definition of done 1847-1851 | Broken bridge fails loudly, not silently. | E04. | CLOSED for reported bug. | None. | Full connector failure regression. | PARTIAL |
| B211 | Definition of done 1847-1852 | AC1-AC5 pass in CI against fake relay. | E14 pending. | OPEN. | B192-B197. | Fake-relay CI job. | OPEN |
| B212 | Definition of done 1847-1853 | AC1 runs nightly against real relay. | No exact nightly evidence located. | OPEN. | Secrets/real relay. | Scheduled real-relay job. | OPEN |

## Second Milestone: Self-Diagnosing, Unified Receive inventory

| ID | Source heading + lines | Normalized requirement | Implementation / backlog evidence | Disposition + authority | Dependencies | Required tests / docs / live proof | Closure |
|---|---|---|---|---|---|---|---|
| B213 | Goal 1877-1879 | One command receives local+relay and stable versioned JSON lets agents self-configure/diagnose. | E06/E08 closed receive/diagnosis; E03 schema open. | PARTIAL. | I002. | Unified stream + schema/capability suite. | PARTIAL |
| B214 | In scope #1 1883-1885 | Define and publish canonical message/event JSON v1. | E03. | OPEN. | I002. | Published schema + changelog. | OPEN |
| B215 | In scope #1 1887-1892 | `send --json`, `monitor --json`, and `poll --json` all emit schema v1. | E03. | OPEN. | B214. | Validate all three surfaces. | OPEN |
| B216 | In scope #1 1893-1900 | V1 includes schema version, identity object, source, priority, content, delivery. | E03 explicitly defers identity/trust/priority subset. | PARTIAL / narrowed by authoritative I002. | I008/I003. | Minimal-v1 schema now; versioned extension later. | PARTIAL |
| B217 | In scope #2 1902-1905 | Default `c2c monitor` watches local plus configured relay. | E06. | CLOSED. | Relay URL/alias. | Default-source integration. | CLOSED |
| B218 | In scope #2 1904-1906 | Fold M1 relay polling mode into unified monitor. | E06. | CLOSED substantively. | None. | Regression for relay enabled by config. | CLOSED |
| B219 | In scope #2 1908-1912 | Provide local-only and relay-only scope flags. | E06: `--no-relay` provides local-only; no `--relay-only` exact surface. | PARTIAL; naming/current UX differs. | Monitor source abstraction. | Scope-flag tests. | PARTIAL |
| B220 | In scope #2 1913-1915 | Unified monitor `--json` emits canonical NDJSON and relay correctness is default. | E17/E06; canonical schema pending E03. | PARTIAL. | I002. | Same-stream schema validator. | PARTIAL |
| B221 | In scope #3 1917-1924 | Provide `c2c doctor --relay`. | E08. | CLOSED. | Relay probe. | Doctor injected-failure suite. | CLOSED |
| B222 | In scope #3 1917-1924 | Provide `c2c capabilities --json` machine-readable matrix. | E08/B093 records capability surface; verify exact top-level CLI availability in release. | CLOSED per completed backlog, live command proof advisable. | Relay probe. | CLI help + JSON snapshot. | CLOSED |
| B223 | In scope #3 1926-1934 | Doctor reports configured, reachable, registered, lease, receive path, outbox depth, watcher state. | E08 covers configured/reachable/lease/connector/outbox/capabilities. | CLOSED substantively. | Connector state. | One fixture per check ID. | CLOSED |
| B224 | In scope #3 1936 | Every doctor FAIL includes `fix_command`. | E08. | CLOSED. | Failure catalog. | Completeness assertion. | CLOSED |
| B225 | In scope #3 1938 | Capabilities gives machine-readable “what works here.” | E08. | CLOSED substantively. | Scheme/probes. | Reality cross-check. | PARTIAL |
| B226 | Out of scope 1940-1942 | M2 keeps polling; deep connector push repair waits for M3+. | Current connector was repaired enough by E04, but polling remains canonical. | CONSTRAINT partly superseded. | Future push design. | Capability docs. | CLOSED |
| B227 | Out of scope 1940-1943 | Identity pinning/trust/priority await identity decision. | E19/E12. | DEFERRED by current authority. | I008 before I003. | Deferred backlog. | DEFERRED |
| B228 | Out of scope 1940-1944 | Receipts and wait remain later/relay-side. | E13. | DEFERRED. | Push/cursors. | I004 acceptance suite later. | DEFERRED |
| B229 | Out of scope 1940-1945 | Harness unification waits for schema. | E02/E03. | DEFERRED. | I002 then I007. | Backlog dependency enforcement. | DEFERRED |
| B230 | Out of scope 1940-1946 | M2 does not change rooms, memory, or schedules. | No evidence of scope violation required. | CONSTRAINT. | None. | Diff/scope review. | CLOSED |
| B231 | AC1 1948-1950 | Default monitor JSON emits local and relay DMs in one canonical NDJSON stream tagged by source. | E06/E17; canonical schema pending. | PARTIAL. | I002. | Exact same-stream test. | PARTIAL |
| B232 | AC2 1948-1951 | Send/monitor/poll JSON validate against schema v1 and carry `schema_version`. | E03. | OPEN. | I002. | Schema validator in CI. | OPEN |
| B233 | AC3 1948-1952 | Doctor JSON returns FAIL+fix for unreachable, unregistered, expired lease, inactive watcher; PASS healthy. | E08. | CLOSED behavior; exact proposed aggregate test absent. | Fake relay/state injection. | Exact table-driven test. | PARTIAL |
| B234 | AC4 1948-1953 | Capabilities matches real HTTPS behavior for poll/subscribe/connect. | E08 reports matrix; exact cross-check test absent. | PARTIAL. | Executable probes. | `test_capabilities_matches_reality`. | OPEN |
| B235 | AC5 1948-1954 | Local-only/relay-only scope correctly; default includes relay. | E06 provides default+local-only; relay-only exact flag absent. | PARTIAL. | Scope flags. | Exact scope test. | PARTIAL |
| B236 | Tests 1956-1958 | Extend fake relay to drive local+relay delivery in one run. | E14 pending. | OPEN. | I005. | Fixture integration. | OPEN |
| B237 | Tests 1956-1959 | Add `test_unified_monitor_emits_local_and_relay_json`. | Exact name absent; related E06 unit logic only. | OPEN. | B236. | Add exact process/integration test. | OPEN |
| B238 | Tests 1956-1960 | Add `test_all_json_surfaces_conform_to_schema_v1` with CI validator. | Exact name absent; E03 pending. | OPEN. | I002. | Add schema validator job. | OPEN |
| B239 | Tests 1956-1961 | Add `test_doctor_relay_flags_each_failure_with_fix`. | Exact name absent; E08 implementation exists. | PARTIAL. | Fake failure injection. | Add table-driven exact/equivalent test. | OPEN |
| B240 | Tests 1956-1962 | Add `test_capabilities_matches_reality`. | Exact name absent. | OPEN. | Executable capability probes. | Add fake + real variants. | OPEN |
| B241 | Tests 1956-1963 | Add `test_monitor_scope_flags`. | Exact name absent; related monitor gating tests E06. | PARTIAL. | Relay-only decision. | Add CLI scope test. | OPEN |
| B242 | Docs 1965-1967 | Add inline, agent-readable Message JSON schema v1 reference page. | E03 open; current monitor-only E17 is not project-wide schema. | OPEN. | I002. | Publish/link/schema drift check. | OPEN |
| B243 | Docs 1965-1968 | Update receive guide and cross-machine quickstart to unified monitor. | E06/E15/current commands docs. | CLOSED substantively. | None. | Command/doc smoke. | CLOSED |
| B244 | Docs 1965-1969 | Remove hand-rolled poll loop from golden path. | E15 points at first-class paths; some relay docs still show loop as fallback. | PARTIAL; fallback may remain outside golden path. | Accurate transport status. | Golden-path content audit. | PARTIAL |
| B245 | Docs 1965-1970 | Doctor/troubleshooting documents relay checks and capabilities. | E08 and command docs/changelog; dedicated guide completeness not verified. | PARTIAL. | None. | Docs coverage audit. | PARTIAL |
| B246 | Definition of done 1972-1974 | One monitor covers local+relay with canonical NDJSON. | E06/E17 closed sources, E03 open schema. | PARTIAL. | I002. | B237/B238. | PARTIAL |
| B247 | Definition of done 1972-1975 | All JSON surfaces conform to schema v1, CI-enforced. | E03. | OPEN. | I002. | B238. | OPEN |
| B248 | Definition of done 1972-1976 | Doctor-relay and capabilities truthfully report state with fixes. | E08. | CLOSED substantively; reality test open. | Live/fake probes. | B239/B240. | PARTIAL |
| B249 | Definition of done 1972-1977 | AC1-AC5 pass against fake relay. | E14 pending. | OPEN. | B236-B241. | CI job. | OPEN |
| B250 | Definition of done 1972-1978 | AC1 also runs nightly on real relay. | No exact nightly evidence located. | OPEN. | Real relay/secrets. | Scheduled job + retained result. | OPEN |

## Heading-coverage self-check

All headings intersecting lines 967-1985 were inventoried:

| Source heading | Source span within assigned range | Inventory IDs | Check |
|---|---:|---|---|
| `# Agent-Harness Integration Contract` (heading at 966) | 967-1181 | B001-B039 | Covered through all subheadings: Principle, Environment, Canonical JSON, Tool/MCP, Prompt, wrappers, push, capabilities, conformance, meta. |
| `# Implementation Roadmap` | 1184-1356 | B040-B073 | Covered P0/P1/P2, sequencing/risks, and three pre-dogfood priorities. |
| `# Test and Conformance Suite` | 1360-1554 | B074-B129 | Covered every test class, every listed fixture/adverse case, CI/nightly split, and each of the 8 named regressions separately. |
| `# Product and Website Positioning` | 1558-1627 | B130-B145 | Covered summary, headline, both pitches, mental model, every “not”, why-now, CTA, alpha, above-fold copy. |
| `# Website / Docs Information Architecture` | 1631-1745 | B146-B172 | Covered both principles, all 7 landing blocks, all 7 nav tracks with their full page lists preserved, all 6 IA decisions, all 4 caveat placements, net recommendation. |
| `# First Milestone: Honest Cross-Machine DM Loop` | 1749-1857 | B173-B212 | Covered goal, all in-scope behaviors, AC1-AC5 separately, fixture, all 5 named tests separately, docs, every out-of-scope boundary, every DoD item. |
| `# Second Milestone: Self-Diagnosing, Unified Receive` | 1861-1985 | B213-B250 | Covered goal, all in-scope behavior, every out-of-scope boundary, AC1-AC5 separately, all 6 test bullets (fixture + 5 names), all docs, every DoD item. Lines 1986+ intentionally excluded. |

Self-check counts:

- Total stable requirement rows: **250** (`B001`-`B250`).
- Exact source-proposed named tests in this range: **18 occurrences** (8 suite
  regressions + 5 M1 tests + 5 M2 tests); every occurrence has its own row even
  where names overlap semantically.
- Open/deferred/partial items remain classified rather than silently treated as
  closed. No source heading in the assigned range is unclassified.

## Open/unclassified summary

- **Unclassified normative items: 0.** Every normative item in the assigned
  range is represented directly or, for dense enumerations such as schema field
  sets/nav page sets, preserved verbatim in one atomic contract row.
- Highest-priority open implementation authorities: I002 canonical JSON and
  I005 fake relay/regression oracle.
- Explicitly deferred by later authority: I003 trust tiers/TOFU, I004 receipts
  and `send --wait`, I007 full harness-adapter unification, and I008 optional
  per-agent attestation implementation.
- Product/site IA requirements are mostly source-only proposals. They require a
  product/coord decision; current site copy and flat navigation must not be
  called “wrong” solely because they differ from this proposal.
- Main proof gaps despite completed B087-B100: exact fake-relay CI coverage,
  real-relay nightly ACs, all-adapter safety/conformance, command-wide exit-code
  discipline, line-buffer/transient/auth monitor behavior, and capability-vs-
  reality tests.
