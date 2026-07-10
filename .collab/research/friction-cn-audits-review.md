# Independent review of friction closure audits T1-T3

Date: 2026-07-10

Reviewed inputs:

- T0 inventory at `/home/xertrov/src/c2c/.worktrees/friction-cn-inventory/.collab/research/` (all four inventory/review artifacts, 406 stable rows).
- T1: `/home/xertrov/src/c2c/.worktrees/friction-cn-audit-bugs/.collab/research/friction-cn-b087-b094-audit.md`.
- T2: `/home/xertrov/src/c2c/.worktrees/friction-cn-audit-contract/.collab/research/friction-cn-b095-b100-audit.md`.
- T3: `/home/xertrov/src/c2c/.worktrees/friction-cn-audit-futures/.collab/research/friction-cn-pending-futures-audit.md`.

The verdicts below assess each **audit artifact as reconciliation input**, not
whether the underlying feature tranche is complete.

## Verdicts

| Audit | Verdict | Decisive result |
|---|---|---|
| T1, B087-B094 | **PASS** | Its 4 PASS / 3 PARTIAL / 1 FAIL result survives criticism. The monitor, doctor/capability, stale subscribe explanation, and relay-status findings are directly supported by current code and focused/live receipts. |
| T2, B095-B100 | **FAIL pending reconciliation** | Its peek-auth, adapter-framing, discovery, and golden-path evidence is useful, but it silently selects the strict side of the B098 contract conflict and treats deferred cursor/ack work as current B096 closure work. Those are authority errors, not editorial nits. |
| T3, B101 + I002-I008 | **PASS with two gates** | Its actionable/deferred split and stale-I006 decomposition are sound. Any I005 B098 regression is blocked by the B098 authority decision, and I006 must be split rather than simply closed. |

## T1 attempted decisive criticisms

| Criticism sought | Evidence | Result |
|---|---|---|
| Monitor's `cli-<alias>` default might be an intentional complete B089 surface because connector users can pass overrides. | B089 requires a first-class relay-aware monitor; `decide_relay_watch` hard-codes the one-shot registration convention while the connector registers host/session, and `extract_relay_messages` converts error-shaped JSON to `[]`. | Rejected. Overrides do not make the default golden path correct or failure-honest. T1 PARTIAL stands. |
| B090 should PASS because it now points at a working poll fallback. | The fallback works, but emitted text still says the B087 connector is broken after B087 was fixed. | Rejected. The operational path is fixed, but contradictory current guidance is a real partial closure and belongs in the capability-consistency slice. |
| Doctor's capability report might mean theoretical relay capability, not client capability. | B093 expressly asks for a matrix “so agents self-configure”; `check_capabilities` maps reachability to subscribe readiness while the actual HTTPS subscribe command exits non-zero. | Rejected. Self-configuration requires observed client reality. T1 FAIL for B093 stands. |
| Machine-global connector discovery might be acceptable host status. | B093 asks whether the connector serving this broker/relay is running; isolated-broker output is contaminated by unrelated processes. | Rejected. Ownership/scope is part of truthfulness. |
| B094's “registered” might mean locally registered. | It appears inside a `Relay:` block next to URL/lease and B094 explicitly asks for relay registration state. | Rejected. The field is materially misleading. |

Validators/evidence: graph snippets for `extract_relay_messages`,
`check_capabilities`, and `detect_connector_processes`; direct source at
`ocaml/cli/c2c_monitor_logic.ml:242-264`,
`ocaml/cli/c2c_monitor_cmd.ml:637-746`,
`ocaml/cli/c2c_doctor_relay.ml:64-86,473-497`, and
`ocaml/cli/c2c_relay_state.ml:224-253`; T1's recorded focused tests and live
reproductions. No contrary test covering the failed paths was found.

## T2 attempted decisive criticisms

| Criticism sought | Evidence | Result |
|---|---|---|
| Peek might rely on route-level signed authorization even though the handler has no check. | `/poll_inbox` passes `verified_alias` and compares it to `alias_of_session`; `/peek_inbox` discards `verified_alias` and reads the requested key directly (`ocaml/relay.ml:3168-3192,4445-4455`). | Rejected. T2's peek ownership finding is decisive and critical. |
| B098's current supervisor gate could satisfy the strict backlog because supervisors are locally configured. | B098 says local-operator-only and unreachable from **any** relay-delivered message. Code explicitly allows remote supervisors; tests accept supervisor DMs and reject only non-supervisors; relay messages enter the same inbox without source provenance. | Criticism succeeds against T2's disposition. T2 proves a conflict but is not authorized to resolve it by deleting the current configured-supervisor contract. Operator/security authority must select strict-local versus weaker configured-supervisor RPC. |
| Cursor/ack absence means B096 must be reopened now. | B096 bundled peek and cursors, but later Max authority I004 explicitly defers server cursors, delivery/consume acks, and waits while polling remains canonical. | Criticism succeeds. Split immediate peek authorization from deferred I004; do not dispatch cursor/ack as current B096 work. |
| B099 might be closed because canonical Codex/OpenCode skill files match. | B099 requires every supported adapter to inject the fragment on session start and conformance-test it; static copies and a Claude-only embedded test do not prove activation. Bespoke renderers also lack a shared hostile-content boundary. | Rejected. The adapter completion gap stands, though full I007 tool/hook unification remains deferred. |
| T2's B100 bar might be broader than the bug. | B100 itself names install, local proof, relay setup/register, discovery, send, monitor/poll receive, verify, real expected output, and inline symptom/cause/fix. No single current public page/test covers that sequence. | Rejected. PARTIAL stands. |

Validators/evidence: graph-first discovery of `handle_poll_inbox`,
`handle_peek_inbox`, `inbox_verdict_if_trusted`, common/OpenCode/Kimi renderers;
full B095-B100 backlog bodies; direct approval code/tests and relay route source.

## T3 attempted decisive criticisms

| Criticism sought | Evidence | Result |
|---|---|---|
| I006 remains factually correct because relay discovery still needs a known address. | `c2c list --relay` now performs authenticated relay listing and can return previously unknown live peers. | Rejected for the original premise. T3 correctly splits remaining ambiguity/cards/directory-policy work instead of implementing I006 as written. |
| Reusing the production in-memory relay is insufficiently “fake.” | The goal is deterministic protocol/failure behavior, not a second implementation; production relay state plus a reusable HTTP fault layer is the stronger executable oracle. | Rejected. T3's I005 reframe is sound. |
| I002 could absorb trust/priority fields from the source now. | I002's later explicit Max decision keeps v1 lean and reserves I003/I008 fields. | Rejected. T3 preserves authority correctly. |
| I005 can immediately add the exact B098 regression. | The expected result depends on the unresolved strict-local versus configured-supervisor contract. | Criticism succeeds as a dispatch gate only. Build neutral fixture support now; block the B098 semantic vector until authority resolves the contract. |
| T3's three-way parallel start misses critical audit hotfixes. | T3 scope is pending futures, not T1/T2 gaps. | Rejected as an audit failure, accepted as a reconciliation expansion: security hotfixes outrank the futures start set. |

Validators/evidence: full B101/I002-I008 bodies; current message encoder,
self-update, relay test-server and discovery evidence recorded by T3; dependency
and row mapping checked against all 406 inventory entries.

## Review conclusion

Use T1 and T3 as reviewed evidence. Use T2's factual findings only after applying
the two corrections above. Security severities are advisory; the coordinator
owns final classification and the operator owns the B098 contract decision.
