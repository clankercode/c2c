# `friction-points-cn.md` normative inventory, part C

Scope: source lines **1986-2836 only**. Stable IDs in this artifact are `C001` through `C057`.

This is an inventory, not a fresh commitment to the source roadmap. The milestone text was a proposal from Chris's Claude session on 2026-07-07. Dispositions below apply this authority order:

1. explicit Max decisions captured in `.backlog/ideas/`;
2. completed `.backlog/bugs/` records plus current implementation/docs;
3. pending backlog ideas;
4. the roadmap proposal itself.

Closure vocabulary:

- **CLOSED**: current implementation/backlog evidence satisfies the normalized item.
- **PARTIAL**: a narrower slice is complete, but the full source item is not.
- **OPEN-BACKLOGGED**: accepted work exists in a pending backlog item.
- **OPEN-DEFERRED**: explicitly retained but deferred by Max/current strategy.
- **DECISION-SETTLED / ADR-OPEN**: Max selected the direction, but the durable ADR and/or implementation remain open.
- **SUPERSEDED**: later authority rejected or replaced the source wording.
- **OPEN-UNCLASSIFIED**: no authoritative disposition or owned backlog item was found.
- **BOUNDARY**: a milestone scope constraint, not independently closable work.

## Authority reconciliation: identity model

The early roadmap repeatedly says “per-agent identity” and proposes migrating the relay `identity_pk` to a per-agent/session key (lines 2009, 2013-2017, 2075, 2118, 2298, 2415, 2602-2620, 2801-2803). That is **not the current decision**.

Max's later decision in `.backlog/ideas/I008-identity-model-machine-key-as.todo` is authoritative: keep the existing **machine-wide Ed25519 identity key as the relay trust anchor**, preserve one relay connection per machine, and optionally add a per-agent key attested by an in-band machine-signed certificate. Messages without an agent signature remain compatible. I008 explicitly rejects (a) TOFU as the per-agent-attestation bootstrap and (c) relay-registered per-agent keys. Current docs agree that `identity_pk` is a per-machine keypair (`docs/reference/identifiers.md`). Implementation is deferred under the trusted-swarm-first strategy, and the decision still needs promotion to an ADR.

Consequences for this inventory:

- source requirements to make the relay key itself per-agent are **SUPERSEDED**;
- requirements for agent-level distinction survive only as the optional, machine-attested I008 refinement;
- peer trust in I003 binds first to the pinned machine key and later may include the optional attested agent key;
- cursor/receipt wording that says “keyed to verified per-agent identity” must instead key durable authority to the verified machine anchor, with an optional attested agent discriminator if/when I008 lands.

## Milestone status snapshot

| Milestone | Source proposal | Current disposition |
|---|---|---|
| M3, Trusted Identity + Safe Priority | Per-agent relay identities, verified sender, TOFU, trust tiers and authority gating | Identity premise superseded by I008 machine-anchor decision. B097/B098/B099 are done. Full trust tiers/pinning are I003, **OPEN-DEFERRED**. |
| M4, Harness Unification | One env/schema/prompt/hook/conformance contract for all harnesses | I007 retains this as a deferred north star. B099 completed the shared safety-fragment slice; the rest is **OPEN-DEFERRED**. |
| M5, Reliable Push + Delivery Tracking | Persistent bridge, cursors, push, delivered state, `send --wait` | B087/B089/B096 and honest queued/delivered reporting from B088 provide partial substrate. Push, cursors, tracked remote delivery and waits remain deferred dependencies of I004. |
| M6, Read Receipts + Consume Acks | Signed, privacy-preserving, opt-in read receipts | Privacy design retained in I004; implementation explicitly **OPEN-DEFERRED**. |

## Inventory

### C001 — M2 tail: unify, diagnose, and stabilize the schema dependency

- **Source heading + lines:** Tail of Second Milestone / sequencing, lines 1986-1990.
- **Normalized requirement:** M2 should remove local-vs-relay receive reasoning with one monitor, make relay configuration self-diagnosing, and provide the canonical JSON dependency for later harness, receipt, and trust work; it should precede the riskier milestones.
- **Implementation/backlog evidence:** B089 relay-aware monitor and B093 relay doctor/capabilities are `done`; I002 is the pending canonical JSON item. `docs/changelog.md` records B089/B093 completion.
- **Disposition + authority:** The monitor/diagnostic portions are accepted and implemented. The schema portion is narrowed by Max's trusted-swarm-first decision in I002: v1 contains current fields plus `delivery.state`; identity/trust fields wait for later versions.
- **Dependencies:** I002; later I003/I004/I007 consume the schema.
- **Required tests/docs/live proof:** Existing B089/B093 regression suites and docs; I002 still needs a shared send/monitor/poll JSON conformance test and versioned schema reference.
- **Closure state:** **PARTIAL** — monitor and diagnosis closed; canonical schema open.

### C002 — M3 ordering and safety-before-scale rationale

- **Source heading + lines:** Third Milestone, Summary/Goal, lines 1994-2010.
- **Normalized requirement:** Establish truthful identity and enforce peer authority before scaling the same behavior across harnesses or inviting less-trusted agents.
- **Implementation/backlog evidence:** B098/B099 are done; I003 and I008 are deferred; I007 explicitly says harness unification comes last.
- **Disposition + authority:** Retained as sequencing guidance, but “per-agent identity” is replaced by I008's machine trust anchor plus optional attestation.
- **Dependencies:** I008 before I003; I002 and identity/trust before I007.
- **Required tests/docs/live proof:** Safety regression per adapter, plus identity/trust tests when I003/I008 land.
- **Closure state:** **PARTIAL** — core safety slices landed; identity/trust implementation deferred.

### C003 — M3 identity granularity

- **Source heading + lines:** Third Milestone, In scope §1, lines 2013-2017; AC1/DoD/sequence, lines 2075, 2083, 2118, 2132.
- **Normalized requirement:** Give recipients a way to distinguish co-located agents cryptographically without misrepresenting the relay's actual trust boundary.
- **Implementation/backlog evidence:** I008; `docs/reference/identifiers.md` documents one machine keypair; B097 surfaces `identity_pk`.
- **Disposition + authority:** **Source mechanism superseded by Max/I008.** Do not migrate the relay `identity_pk` to per-agent keys. Keep the machine anchor; optional per-session agent keys are machine-signed, carried in-band, and backward compatible.
- **Dependencies:** Formal ADR; envelope support; session-key lifecycle; I002 schema evolution.
- **Required tests/docs/live proof:** Replace proposed `test_per_agent_distinct_identity_keys` with tests for one stable machine anchor, distinct optional agent keys, valid/invalid machine-signed agent certs, first-message verification, and unsigned-message compatibility. Update identity/security reference and ADR.
- **Closure state:** **DECISION-SETTLED / ADR-OPEN**; implementation **OPEN-DEFERRED**.

### C004 — Verified sender fields and signature/alias binding

- **Source heading + lines:** Third Milestone, In scope §2, lines 2019-2026; AC2/tests/DoD, lines 2076, 2084, 2119.
- **Normalized requirement:** Delivered JSON should truthfully expose the signer's identity and verification result; the relay/broker must verify the signature and claimed sender, flagging or quarantining mismatches.
- **Implementation/backlog evidence:** Relay code already verifies Ed25519 operations and alias binding, and B097 exposes `identity_pk`; I002 explicitly defers `from.identity_pk` and `verified` from v1 until I008/trust work.
- **Disposition + authority:** Accepted in principle, but field timing is governed by I002/I008. `from.identity_pk` must denote the machine anchor; an optional agent-attestation field needs a later schema version.
- **Dependencies:** I008, I002 schema v2+, clear quarantine semantics.
- **Required tests/docs/live proof:** Valid signature versus forgery/mismatched alias; machine anchor versus optional attested agent signer; canonical JSON equality across send/monitor/poll; security/schema docs.
- **Closure state:** **PARTIAL / OPEN-BACKLOGGED**.

### C005 — Peer pinning and key-change handling

- **Source heading + lines:** Third Milestone, In scope §3, lines 2028-2044; AC3/AC5/tests/DoD, lines 2077, 2079, 2085, 2087, 2120, 2122.
- **Normalized requirement:** Persist peer trust against a cryptographic anchor; warn loudly and downgrade/quarantine on an unexpected key change; provide durable pin/allow/block management.
- **Implementation/backlog evidence:** I003 retains TOFU/tier policy but is deferred. I008 rejects TOFU specifically as the bootstrap for optional per-agent attestation; the relay already pins alias to the machine `identity_pk` on first signed registration.
- **Disposition + authority:** Retain TOFU only for peer trust in the machine anchor as described by I003/current relay behavior. Do not TOFU-pin an unauthenticated agent key; optional agent identity must be certified by the already trusted machine key. Suggested `peers pin|allow|block` names remain proposals, not committed CLI.
- **Dependencies:** I008, I003, rotation/revocation design, alias-release policy.
- **Required tests/docs/live proof:** Machine-key first contact, unexpected rotation warning/downgrade, valid machine-certified agent-key rotation, persisted allow/block, quarantine behavior, command/help/reference docs.
- **Closure state:** **OPEN-DEFERRED**.

### C006 — Trust tiers and priority/authority gating

- **Source heading + lines:** Third Milestone, In scope §4, lines 2046-2063; public-room boundary, line 2071; AC4/AC5/tests/DoD, lines 2078-2079, 2086-2088, 2121-2124.
- **Normalized requirement:** Bind `blocked|unknown|allowlisted|trusted` to the pinned machine anchor (and optional attested agent key); cap unknown peers at FYI, forbid their interrupt/urgent/blocking authority, rate-limit or downgrade unknown broadcasts/public-room traffic, and quarantine blocked peers.
- **Implementation/backlog evidence:** I003 contains essentially this policy and is pending/deferred. B098 approval isolation and B099 untrusted-data framing are done but are not substitutes for a tier engine.
- **Disposition + authority:** Accepted as future work, explicitly deferred under trusted-swarm-first. Trust is enforcement, not advisory. Full room RBAC and sophisticated quota tuning remain later work.
- **Dependencies:** I008 then I003; priority schema fields; broker/relay enforcement; local supervisor invariant from B098.
- **Required tests/docs/live proof:** Unknown urgent/blocking downgrade, no interrupt, trusted urgent honored, blocked quarantine, unknown send-all rate limit/FYI behavior, public-room behavior, and `test_remote_message_cannot_reach_approval_path` regression. Document tier/capability matrix.
- **Closure state:** **OPEN-DEFERRED**.

### C007 — M3 scope boundaries

- **Source heading + lines:** Third Milestone, Out of scope, lines 2065-2071.
- **Normalized requirement:** Keep receipts/`--wait`, deep push, harness unification, advanced abuse tuning, and full room RBAC out of the initial trust slice; only basic unknown-peer public-room restrictions belong with M3.
- **Implementation/backlog evidence:** I004 defers receipts; I007 defers harness unification; I003 scopes trust tiers; B089 makes polling viable today.
- **Disposition + authority:** Retained as decomposition guidance, with the same trusted-swarm-first deferrals.
- **Dependencies:** M5-like transport before I004; I003 before advanced trust-dependent features.
- **Required tests/docs/live proof:** Each later slice must preserve the B098 approval-path regression and document its own boundary.
- **Closure state:** **BOUNDARY**.

### C008 — M3 security documentation and milestone proof

- **Source heading + lines:** Third Milestone, Docs/Definition of done, lines 2090-2124.
- **Normalized requirement:** Security docs must connect identity, verification, pinning, tiers, and priority gating to injection, spoofing, steering, and interrupt DoS; include trust management and field/capability references; completion requires all identity/trust ACs plus approval isolation.
- **Implementation/backlog evidence:** B098/B099 docs and regressions are done; `docs/reference/identifiers.md` documents the machine anchor; I003/I008 implementation/docs remain pending.
- **Disposition + authority:** Retained, but docs must teach the I008 machine-anchor model, not the superseded per-agent relay-key model.
- **Dependencies:** C003-C006.
- **Required tests/docs/live proof:** AC-equivalent tests listed in C003-C006, fake-relay forgery cases, security model page, trust commands reference if/when commands exist, schema links, and real cross-host key-change proof.
- **Closure state:** **PARTIAL**.

### C009 — M4 unified adapter contract and ordering

- **Source heading + lines:** Fourth Milestone, Summary/Goal, lines 2141-2158; Why it follows M3, lines 2276-2280.
- **Normalized requirement:** After core schema/identity/trust semantics stabilize, make every supported harness a thin, conformance-tested adapter over one documented contract.
- **Implementation/backlog evidence:** I007 captures this north star verbatim and is deferred; current harnesses remain bespoke.
- **Disposition + authority:** Accepted as a north-star direction, not a current milestone commitment. I007 says build last after I002 and identity attestation.
- **Dependencies:** I002, I008, relevant I003 fields/semantics.
- **Required tests/docs/live proof:** Cross-harness contract suite and at least one live send/receive proof for each shipped adapter.
- **Closure state:** **OPEN-DEFERRED**.

### C010 — `c2c env --json` and identity/config precedence

- **Source heading + lines:** Fourth Milestone, In scope §1, lines 2162-2172; AC2/test/DoD, lines 2237, 2246, 2268.
- **Normalized requirement:** Provide one machine-readable resolved-config command covering explicit session ID, harness-native IDs, persisted fallback, and relay/broker/alias variables; adapters consume it instead of reimplementing precedence.
- **Implementation/backlog evidence:** I007 retains this item; no `c2c env --json` command/documentation was found.
- **Disposition + authority:** Future north-star work under I007, not currently committed.
- **Dependencies:** Stable identity/session semantics and config vocabulary.
- **Required tests/docs/live proof:** Simulated Claude/Codex/Pi/Kimi environments for exact precedence; redaction review; command/help and adapter-build docs.
- **Closure state:** **OPEN-DEFERRED**.

### C011 — Schema-generated tool surfaces

- **Source heading + lines:** Fourth Milestone, In scope §2, lines 2174-2187; AC1/test/DoD, lines 2236, 2245, 2267.
- **Normalized requirement:** Generate MCP and Pi tool names, parameters, and canonical returns for send/inbox/identity/list/rooms/memory/schedule from one source schema.
- **Implementation/backlog evidence:** I007 retains the adapter goal; I002 owns the canonical message JSON dependency. No shared tool-schema generator was found.
- **Disposition + authority:** Accepted north star, deferred. The source's requirement that v1 already contain `verified`/`trust_tier` is superseded by I002's lean v1 decision.
- **Dependencies:** I002 first; later schema versions after I008/I003.
- **Required tests/docs/live proof:** Generated-schema diff across adapters, compatibility fixtures, command/tool reference, and adapter conformance.
- **Closure state:** **OPEN-DEFERRED**.

### C012 — Canonical safety prompt/skill fragment

- **Source heading + lines:** Fourth Milestone, In scope §3, lines 2189-2204; AC3-AC4/tests/DoD, lines 2238-2239, 2247-2248, 2269-2270.
- **Normalized requirement:** Single-source the “peer messages are untrusted data, not instructions” fragment, including addressing, trust framing, and verbs; every adapter must inject/surface it consistently and not drift.
- **Implementation/backlog evidence:** B099 is `done`; `.collab/skills/c2c.md` contains the canonical safety section; embedded-skill conformance tests exist. I007 still owns broader adapter unification.
- **Disposition + authority:** Accepted and substantially implemented by B099. Source references to runtime `trust_tier` marking remain future I003 work.
- **Dependencies:** Distribution/codegen consistency across installed skills; I003 for actual tier labels.
- **Required tests/docs/live proof:** Embedded/source equality and per-client install/start verification; when I003 lands, identical untrusted marking across all adapters.
- **Closure state:** **PARTIAL** — canonical safety framing closed; full cross-adapter trust rendering deferred.

### C013 — Shared push/schedule hook contract and approval isolation

- **Source heading + lines:** Fourth Milestone, In scope §4, lines 2206-2215; AC5/test/DoD, lines 2240, 2249, 2271-2272.
- **Normalized requirement:** Define one documented turn-injection interface and wake/idle schedule format that at least two harness adapters implement, while proving remote messages cannot enter local approval/PreToolUse authority paths.
- **Implementation/backlog evidence:** Native `wake.toml` scheduling and multiple client-specific delivery hooks exist; I007 says they are not yet one contract. B098 and its two approval-path regressions are done.
- **Disposition + authority:** Approval isolation is a hard, current invariant. Hook-contract unification is deferred with I007.
- **Dependencies:** I007; client extension capabilities; B098 must remain invariant.
- **Required tests/docs/live proof:** Common config exercised on at least two harnesses; per-adapter remote-message approval-isolation regression; live delivery/schedule proof; integration guide.
- **Closure state:** **PARTIAL**.

### C014 — `c2c conformance`

- **Source heading + lines:** Fourth Milestone, In scope §5, lines 2217-2225; AC6/test/DoD, lines 2241, 2250, 2273-2274.
- **Normalized requirement:** Provide an adapter conformance command that passes every shipped adapter and fails a deliberately broken adapter before release.
- **Implementation/backlog evidence:** I007 retains it; no general `c2c conformance` command was found. Narrow embedded-skill tests are not the proposed full suite.
- **Disposition + authority:** Deferred north-star work.
- **Dependencies:** C010-C013 contract artifacts.
- **Required tests/docs/live proof:** Golden valid adapters, deliberately broken fixtures for each contract dimension, release gating, conformance-vector docs.
- **Closure state:** **OPEN-DEFERRED**.

### C015 — M4 scope boundaries

- **Source heading + lines:** Fourth Milestone, Out of scope, lines 2227-2232.
- **Normalized requirement:** Do not add receipts/waits, deep transport repair, new harnesses, or relay-protocol changes merely to unify existing adapters.
- **Implementation/backlog evidence:** I007 describes thin shims over current harness surfaces; I004 separately defers receipts/transport-dependent waits.
- **Disposition + authority:** Retained decomposition boundary.
- **Dependencies:** None beyond keeping I007 scoped.
- **Required tests/docs/live proof:** Scope review in any future I007 implementation plan.
- **Closure state:** **BOUNDARY**.

### C016 — M4 integration documentation and release gate

- **Source heading + lines:** Fourth Milestone, Docs/Definition of done, lines 2252-2274.
- **Normalized requirement:** Publish contract overview, per-harness setup, adapter guide, conformance vectors, tool schema, canonical message JSON reference, and update every harness page; do not call M4 done until AC1-AC6 pass.
- **Implementation/backlog evidence:** Existing client docs exist, but I007 is deferred and the unified contract pages/command do not exist.
- **Disposition + authority:** Future I007 deliverables, not current commitments.
- **Dependencies:** C010-C014 and I002.
- **Required tests/docs/live proof:** Full M4 conformance matrix plus docs-drift check and live smoke per adapter.
- **Closure state:** **OPEN-DEFERRED**.

### C017 — M5 transport selection and milestone goal

- **Source heading + lines:** Fifth Milestone, Summary/Goal, lines 2284-2303; sequencing, lines 2409-2415.
- **Normalized requirement:** Eventually replace the current polling compromise with a reliable low-latency receive substrate that supports independent subscribers, tracked delivery, and later receipts.
- **Implementation/backlog evidence:** B089 makes relay-aware polling canonical today; I004 states push/cursors do not exist and implementation is deferred. B087 repairs the existing connector.
- **Disposition + authority:** Treat push as a future direction, not a selected current commitment. Max's I004 explicitly says polling is canonical for now. Identity binding must use I008's machine anchor, not the source's per-agent relay identity.
- **Dependencies:** I002, I008 semantics, cursor prototype, relay transport decision.
- **Required tests/docs/live proof:** Comparative prod-relay prototype with p95 latency/load; explicit transport ADR before replacing polling.
- **Closure state:** **OPEN-DEFERRED**.

### C018 — Persistent `relay connect` bridge

- **Source heading + lines:** Fifth Milestone, In scope §1, lines 2306-2317; AC4/test/DoD, lines 2380, 2389, 2401.
- **Normalized requirement:** A persistent bridge must resolve real identity, handle PoW, sync local outbox and relay inbox, feed unified monitor, reconnect/back off after drops, and never report success on failure.
- **Implementation/backlog evidence:** B087 is done and records real node ID, PoW parsing, and non-zero caught failures; current docs describe persistent `relay connect`. B089 independently feeds monitor via non-destructive relay peek.
- **Disposition + authority:** Accepted. The original crash/honesty slice is closed; the full “proper push bridge”/mid-stream reliability claim needs current live proof and should not be inferred from B087 alone.
- **Dependencies:** Relay availability; connector supervision; future push/cursor work if bridge semantics change.
- **Required tests/docs/live proof:** B087 malformed/null PoW regression, reconnect/backoff/non-zero failure test, two-host persistent sync, outbox/inbox directionality, monitor integration, operator docs.
- **Closure state:** **PARTIAL**.

### C019 — Durable per-subscriber cursors and at-least-once semantics

- **Source heading + lines:** Fifth Milestone, In scope §2, lines 2319-2332; AC2-AC3/tests/DoD, lines 2378-2379, 2387-2388, 2402.
- **Normalized requirement:** Use durable independent subscriber cursors, consumer acks, non-draining reads, restart recovery, at-least-once delivery, and `message_id` deduplication so readers do not steal messages.
- **Implementation/backlog evidence:** B096 delivered only non-destructive relay `dm peek`; its backlog text mentioned cursors, but `done` evidence/changelog does not claim cursor/ack delivery. I004 says server-side cursors do not exist.
- **Disposition + authority:** Retained future dependency, explicitly not complete. At-least-once is a proposed/retained direction, pending architectural lock-in and prototype.
- **Dependencies:** Relay storage/protocol, subscriber identity keyed to machine anchor plus optional attested agent discriminator, I004.
- **Required tests/docs/live proof:** Two independent cursors, induced disconnect/reconnect, duplicate visibility/dedup, no loss, cursor persistence/recovery, concepts/reference docs.
- **Closure state:** **OPEN-DEFERRED**.

### C020 — Low-latency push with polling fallback

- **Source heading + lines:** Fifth Milestone, In scope §3, lines 2334-2341; AC1/AC6/tests, lines 2377, 2382, 2386, 2391.
- **Normalized requirement:** Prove either WSS/TLS subscription or HTTPS stream/long-poll can deliver cross-host DMs below 2s p95 without a poll loop, while keeping polling as an honest capability-reported fallback.
- **Implementation/backlog evidence:** Docs still state TLS WebSocket is unavailable and relay-aware polling is the reliable path; B089/B090 are done. I004 defers push.
- **Disposition + authority:** Polling fallback is current; push target is deferred and not selected.
- **Dependencies:** Transport prototype, relay capacity, C019 cursors.
- **Required tests/docs/live proof:** Prod-like and real-relay p95 latency/load, drop/reconnect, TLS, capability output matching observed transport, fallback docs.
- **Closure state:** **OPEN-DEFERRED**.

### C021 — Delivered-state tracking

- **Source heading + lines:** Fifth Milestone, In scope §4, lines 2343-2351; AC5/DoD, lines 2381, 2403.
- **Normalized requirement:** Advance remote delivery from `accepted` to `delivered` only when the recipient inbox actually receives the message.
- **Implementation/backlog evidence:** B088 added `delivery.state` output and honest `queued` reporting; I002 includes queued/accepted/delivered in lean schema v1. No evidence found that remote inbox arrival drives a durable delivered transition.
- **Disposition + authority:** Accepted schema concept under I002; full remote tracking deferred with I004/M5 substrate.
- **Dependencies:** C019 ack/delivery event path, I002 canonical schema.
- **Required tests/docs/live proof:** Sender observes accepted then delivered on actual inbox arrival, never on local enqueue; retry/reconnect behavior; send/history/schema docs.
- **Closure state:** **PARTIAL / OPEN-BACKLOGGED**.

### C022 — `c2c send --wait=accepted|delivered`

- **Source heading + lines:** Fifth Milestone, In scope §5, lines 2353-2365; AC5/test/DoD, lines 2381, 2390, 2404.
- **Normalized requirement:** Add bounded waits for accepted/delivered states with truthful final JSON and outcome-specific exit status.
- **Implementation/backlog evidence:** I004 retains `send --wait[=state] --timeout` but is deferred. B088 only added `--fail-if-queued`, not the requested waits.
- **Disposition + authority:** Explicitly deferred by Max/I004.
- **Dependencies:** C021 delivered event; C019 reliable tracking.
- **Required tests/docs/live proof:** Accepted and delivered success, timeout, connector failure, restart/retry, no indefinite hang, command/reference docs.
- **Closure state:** **OPEN-DEFERRED**.

### C023 — M5 scope boundaries

- **Source heading + lines:** Fifth Milestone, Out of scope, lines 2367-2373.
- **Normalized requirement:** Keep read receipts, trust changes, harness work, room tracking, and unrelated relay-auth changes outside the initial push/delivery slice.
- **Implementation/backlog evidence:** I004 separates read receipts; I003/I007 separately own trust/harness work.
- **Disposition + authority:** Retained decomposition boundary.
- **Dependencies:** None beyond maintaining slice separation.
- **Required tests/docs/live proof:** Future implementation plan should explicitly exclude room/read semantics until their dependencies land.
- **Closure state:** **BOUNDARY**.

### C024 — M5 docs, fake-relay proof, and nightly real-relay proof

- **Source heading + lines:** Fifth Milestone, Tests/Docs/Definition of done, lines 2384-2407.
- **Normalized requirement:** Document push as default only after it is real; explain cursors/at-least-once/delivered and send waits; pass AC1-AC6 on fake relay and run low-latency/reconnect proofs nightly on the real relay.
- **Implementation/backlog evidence:** I005 fake relay is pending/high/do-now; docs currently correctly present polling as fallback/current reality; no nightly M5 proof was found.
- **Disposition + authority:** Future gate. Do not update docs to call push the default before tests and live evidence pass.
- **Dependencies:** C018-C022; I005.
- **Required tests/docs/live proof:** Exactly the six named M5 tests, hermetic fake-relay CI, nightly real-relay AC1/AC3, delivery-model and command references.
- **Closure state:** **OPEN-BACKLOGGED** via I005 plus deferred transport work.

### C025 — M6 consume-ack to read semantics

- **Source heading + lines:** Sixth Milestone, Summary/Goal/In scope §1, lines 2419-2447.
- **Normalized requirement:** Optionally derive a signed `read` event from actual recipient consumption/cursor acknowledgement, distinct from inbox delivery, without exposing activity by default.
- **Implementation/backlog evidence:** I004 captures signed consume-ack receipts and is explicitly deferred because push/cursors do not exist.
- **Disposition + authority:** Privacy design retained; implementation deferred by Max.
- **Dependencies:** C019 cursor/ack, C021 delivered state, I008/I003 identity/trust.
- **Required tests/docs/live proof:** Consume-versus-deliver distinction, signed receipt generation, no receipt before consume, security/privacy review.
- **Closure state:** **OPEN-DEFERRED**.

### C026 — Read state and bounded `send --wait=read`

- **Source heading + lines:** Sixth Milestone, In scope §2, lines 2449-2463; AC1-AC2/tests, lines 2557-2558, 2565-2566, 2569.
- **Normalized requirement:** Advance `delivered -> read` only on qualifying consume; `send --wait=read --timeout=T` must return read, delivered-not-read, or timeout and never hang.
- **Implementation/backlog evidence:** I004 retains the full wait ladder and is deferred.
- **Disposition + authority:** Explicitly deferred by Max/I004.
- **Dependencies:** C025, C022 wait machinery.
- **Required tests/docs/live proof:** Both-opt-in round trip, decline/timeout, disconnect, no indefinite wait, truthful final JSON and exit codes.
- **Closure state:** **OPEN-DEFERRED**.

### C027 — Bilateral opt-in and recipient policy

- **Source heading + lines:** Sixth Milestone, In scope §3, lines 2465-2475.
- **Normalized requirement:** Sender requests a receipt per message; recipient policy independently permits it, default off and optionally per peer/tier; neither side can force disclosure.
- **Implementation/backlog evidence:** I004 preserves “opt-in both sides; default off.” No implementation found.
- **Disposition + authority:** Settled privacy requirement within deferred I004.
- **Dependencies:** I003 tiers for tier-scoped policy; configuration UX.
- **Required tests/docs/live proof:** Every sender/recipient policy combination, persistence, defaults on clean install, privacy docs and command help.
- **Closure state:** **OPEN-DEFERRED**.

### C028 — Honest meaning of `read`

- **Source heading + lines:** Sixth Milestone, In scope §4, lines 2477-2481; AC5/docs, lines 2561, 2574.
- **Normalized requirement:** Output and docs must define `read` as consumed by the recipient process, never understood, acknowledged by a human, or acted upon.
- **Implementation/backlog evidence:** I004 names consume-ack; no read UI exists.
- **Disposition + authority:** Retained, mandatory if I004 is implemented.
- **Dependencies:** C025-C026 semantics.
- **Required tests/docs/live proof:** Wording assertions in JSON/help/history and delivery-model docs; negative test that no action/approval implication is emitted.
- **Closure state:** **OPEN-DEFERRED**.

### C029 — Receipt privacy gating by trust

- **Source heading + lines:** Sixth Milestone, Privacy “Emit is opt-in”, lines 2483-2489; AC3/test, lines 2559, 2567, 2570.
- **Normalized requirement:** Receipt emission is default-off and policy-controlled; unknown/blocked peers never receive read receipts, even if requested, preventing presence probes.
- **Implementation/backlog evidence:** I004 captures this rule; I003 trust tiers are also deferred.
- **Disposition + authority:** Retained load-bearing security requirement, deferred with both dependencies.
- **Dependencies:** I003, I004, I008 anchor semantics.
- **Required tests/docs/live proof:** No receipt to unknown/blocked peers, adversarial presence-probe suite, policy-change cases, security/privacy docs.
- **Closure state:** **OPEN-DEFERRED**.

### C030 — Decline must be indistinguishable from pending/offline

- **Source heading + lines:** Sixth Milestone, Summary and Privacy “Declining…”, lines 2428-2432, 2491-2498; AC2/test, lines 2558, 2566, 2569-2570.
- **Normalized requirement:** A recipient hiding reads must reveal no distinguishable decline state; sender sees only delivered plus generic unavailable/pending behavior, and waits time out or return delivered without a privacy oracle.
- **Implementation/backlog evidence:** I004 explicitly preserves this as the load-bearing privacy rule.
- **Disposition + authority:** Settled design requirement, implementation deferred.
- **Dependencies:** C026-C029; careful timing/error normalization.
- **Required tests/docs/live proof:** Side-by-side timing/status comparison for declined, not-yet-read, and offline; never-hang test; red-team presence probe; security docs.
- **Closure state:** **OPEN-DEFERRED**.

### C031 — Minimal receipt payload

- **Source heading + lines:** Sixth Milestone, Privacy “Minimal receipt payload”, lines 2500-2508; AC4, line 2560.
- **Normalized requirement:** Receipt exposes only `message_id`, `read_ts`, and verified reader identity—no content or unrelated activity.
- **Implementation/backlog evidence:** I004 says signed consume-ack but does not yet define an implemented schema; I008 changes identity interpretation.
- **Disposition + authority:** Retained with correction: verified reader authority roots at the machine key, optionally augmented by a machine-attested agent key.
- **Dependencies:** I002 versioning, I008, receipt signing format.
- **Required tests/docs/live proof:** Exact-field allowlist, signature verification, schema compatibility, privacy review/reference.
- **Closure state:** **OPEN-DEFERRED**.

### C032 — Receipt UX, history visibility, and bounded outcomes

- **Source heading + lines:** Sixth Milestone, UX considerations, lines 2510-2521.
- **Normalized requirement:** Keep receipts advanced/default-off; surface state in history/send JSON; avoid unsolicited monitor spam; define read/delivered-not-read/timeout exits; fold declines into unavailable/pending; never wait indefinitely.
- **Implementation/backlog evidence:** I004 owns future waits/receipts; none found implemented.
- **Disposition + authority:** Retained future UX contract.
- **Dependencies:** C026-C030, history schema, monitor event policy.
- **Required tests/docs/live proof:** Exit matrix, history/send JSON snapshots, monitor-no-spam assertion, timeout bounds, user guide.
- **Closure state:** **OPEN-DEFERRED**.

### C033 — Signed, idempotent, versioned, ephemeral receipt event

- **Source heading + lines:** Sixth Milestone, Protocol considerations, lines 2523-2546; AC4/test, lines 2560, 2568.
- **Normalized requirement:** On qualifying consume, emit at most one signed `type:"receipt"` event per `message_id`; make it additive/versioned, ephemeral, and garbage-collect/dead-letter unclaimed receipts.
- **Implementation/backlog evidence:** I004 retains signed consume-ack; I002 supplies future schema-version discipline. No receipt event implementation found.
- **Disposition + authority:** Retained deferred protocol design, subject to I008 identity correction.
- **Dependencies:** C019, I002, I008, relay receipt storage/GC.
- **Required tests/docs/live proof:** Signature/forgery, idempotency, retry/reconnect, GC/DLQ, version negotiation, protocol reference.
- **Closure state:** **OPEN-DEFERRED**.

### C034 — M6 scope boundaries

- **Source heading + lines:** Sixth Milestone, Out of scope, lines 2548-2553.
- **Normalized requirement:** Exclude typing/presence, per-message encryption, room read receipts, and read-behavior analytics from DM receipt work.
- **Implementation/backlog evidence:** I004 is DM/read-receipt scoped and does not include these features.
- **Disposition + authority:** Retained privacy/scope boundary.
- **Dependencies:** None.
- **Required tests/docs/live proof:** Future I004 review must ensure no incidental presence/analytics fields or room fan-out.
- **Closure state:** **BOUNDARY**.

### C035 — M6 documentation and complete proof set

- **Source heading + lines:** Sixth Milestone, Tests/Docs/Why follows M5, lines 2563-2587.
- **Normalized requirement:** Before shipping, prove both-opt-in roundtrip, indistinguishable decline, no untrusted receipts, signed/idempotent receipts, and bounded waits; document consumed-not-understood, controls, leakage, tier gating, and schema.
- **Implementation/backlog evidence:** I004 retains the design but is deferred; required substrate is absent.
- **Disposition + authority:** Future release gate for I004.
- **Dependencies:** C019-C033, I003/I008.
- **Required tests/docs/live proof:** The five named tests plus security presence-probe regression, privacy page, how-to, delivery-model page, command/event reference.
- **Closure state:** **OPEN-DEFERRED**.

### C036 — Architectural decision 1: identity granularity

- **Source heading + lines:** Top Unresolved Architectural Decisions, Blocking §1, lines 2602-2620.
- **Normalized requirement:** Explicitly choose the relay trust-anchor granularity before building pinning/trust.
- **Implementation/backlog evidence:** I008 records Max's choice; current identity file/docs are machine-wide.
- **Disposition + authority:** **Resolved against the source's recommendation:** machine key is the trust anchor; optional machine-attested agent keys refine identity. Registration/load prototyping for relay-registered per-agent keys is no longer required. Promote I008 to ADR.
- **Dependencies:** ADR, I008 implementation if/when prioritized.
- **Required tests/docs/live proof:** See C003; verify one-connection-per-machine remains true.
- **Closure state:** **DECISION-SETTLED / ADR-OPEN**.

### C037 — Architectural decision 2: canonical receive transport

- **Source heading + lines:** Top Unresolved Architectural Decisions, Blocking §2, lines 2622-2639.
- **Normalized requirement:** Explicitly choose the current blessed receive path and prototype future push before replacing it.
- **Implementation/backlog evidence:** B089 made relay-aware non-draining polling work; docs call polling reliable today; I004 says polling is canonical for now and push is deferred.
- **Disposition + authority:** Near-term decision is settled: polling is canonical. Long-term push-versus-stream mechanism remains unselected and must be prototype-driven.
- **Dependencies:** C019/C020 prototypes.
- **Required tests/docs/live proof:** Prod HTTPS streaming/WSS prototype, p95/load at N subscribers, explicit ADR before a default flip.
- **Closure state:** **PARTIAL** — present choice settled, future replacement open/deferred.

### C038 — Architectural decision 3: bus, never RPC

- **Source heading + lines:** Top Unresolved Architectural Decisions, Blocking §3, lines 2641-2657.
- **Normalized requirement:** Messages are information only; no peer message directly causes an action or grants/satisfies approval; recipient/local operator remains the authority.
- **Implementation/backlog evidence:** B098 is done; source comments and two `test_remote_message_cannot_reach_approval_path` regressions enforce the invariant; repository AGENTS.md treats it as canonical.
- **Disposition + authority:** Settled hard invariant. Any future message-to-action feature is disallowed absent a new operator-approved architecture decision and security review.
- **Dependencies:** None; constrains every feature.
- **Required tests/docs/live proof:** Keep approval-path regressions; enumerate automation pressure cases in a durable ADR/security model; per-adapter proof under I007.
- **Closure state:** **CLOSED** for implementation invariant; formal standalone ADR wording remains advisable.

### C039 — Architectural decision 4: delivery guarantee

- **Source heading + lines:** Top Unresolved Architectural Decisions, Blocking §4, lines 2659-2677.
- **Normalized requirement:** Before cursor delivery ships, select a guarantee; proposed direction is at-least-once with `message_id` dedup, not lossy at-most-once or complex exactly-once.
- **Implementation/backlog evidence:** I004 depends on future server-side cursors; B096 only added peek. No shipped cursor guarantee found.
- **Disposition + authority:** Retained proposed direction but not fully locked in by an ADR; implementation deferred.
- **Dependencies:** Cursor/ack prototype and duplicate-rate measurement.
- **Required tests/docs/live proof:** Induced disconnects, duplicate-rate data, dedup correctness, persistence/recovery, delivery-model ADR/docs.
- **Closure state:** **OPEN-DEFERRED**.

### C040 — Architectural decision 5: relay deployment/federation model

- **Source heading + lines:** Top Unresolved Architectural Decisions, JIT §5, lines 2681-2693.
- **Normalized requirement:** Explicitly choose public+PoW, private/tokened/self-hosted, or federation trade-offs when needed; prototype `relay serve`, document public-relay trust, and abuse-test PoW.
- **Implementation/backlog evidence:** Public relay, self-hosting docs, token/auth modes, PoW, and relay-mesh design work exist, but no authority in the audited evidence closes the overall model choice.
- **Disposition + authority:** Keep as just-in-time architecture work; do not infer a federation commitment from roadmap language.
- **Dependencies:** Product deployment requirements, abuse/load evidence, privacy model.
- **Required tests/docs/live proof:** Self-host smoke, public-relay threat model, PoW spam/load test, explicit ADR when topology is selected.
- **Closure state:** **OPEN-UNCLASSIFIED**.

### C041 — Architectural decision 6: trust bootstrap at scale

- **Source heading + lines:** Top Unresolved Architectural Decisions, JIT §6, lines 2695-2709.
- **Normalized requirement:** Keep non-transitive trust; explicitly choose machine-anchor trust bootstrap/rotation and any optional directory, while making key-change warnings actionable.
- **Implementation/backlog evidence:** I003 retains TOFU for pinned machine keys; I008 rejects TOFU for optional agent attestation and chooses a machine-signed cert; I006 leaves relay discovery/directory deferred.
- **Disposition + authority:** Split by layer: relay/peer machine-key pinning may use TOFU; agent-key attestation must verify from message one via the trusted machine anchor; org directory remains optional/unselected.
- **Dependencies:** I008, I003, I006, revocation/rotation UX.
- **Required tests/docs/live proof:** Rotation/revocation prototype, actionable-warning user test, no transitive trust, directory decision if discovery is prioritized.
- **Closure state:** **PARTIAL / OPEN-DEFERRED**.

### C042 — Architectural decision 7: schema evolution

- **Source heading + lines:** Top Unresolved Architectural Decisions, JIT §7, lines 2711-2723.
- **Normalized requirement:** Establish compatibility/version policy before adapter generation; carry `schema_version` from v1 and support non-breaking evolution/negotiation.
- **Implementation/backlog evidence:** I002 explicitly selects a lean versioned v1 and reserves later identity/trust fields for v2; implementation is pending.
- **Disposition + authority:** Direction selected by I002; full compatibility policy/negotiation remains open.
- **Dependencies:** I002 before I007; later I008/I003 fields.
- **Required tests/docs/live proof:** v1/v2 adapter negotiation prototype, additive/unknown-field compatibility, schema reference and policy.
- **Closure state:** **OPEN-BACKLOGGED**.

### C043 — Architectural decision 8: c2c versus harness responsibility for prompt injection

- **Source heading + lines:** Top Unresolved Architectural Decisions, JIT §8, lines 2725-2740.
- **Normalized requirement:** Threat-model and document which controls c2c guarantees (provenance/framing/gating/quarantine) versus what the harness/agent must enforce; red-team an untrusted peer steering a recipient.
- **Implementation/backlog evidence:** B098/B099 establish approval isolation and framing; I003 defers stronger trust gating. No complete boundary ADR/threat-model artifact was found.
- **Disposition + authority:** Partially answered by hard current invariants, but the broader capability/quarantine boundary is unclassified.
- **Dependencies:** I003, I007 adapter semantics, security review.
- **Required tests/docs/live proof:** Threat-model workshop artifact, cross-adapter red team, structural-control evaluation, explicit responsibility matrix.
- **Closure state:** **OPEN-UNCLASSIFIED**.

### C044 — Lower-urgency decision: alias lifecycle must not transfer trust

- **Source heading + lines:** Top Unresolved Architectural Decisions, Alias lifecycle, lines 2742-2746.
- **Normalized requirement:** Releasing and re-registering an alias must never let a new holder inherit the previous holder's trust.
- **Implementation/backlog evidence:** `docs/reference/identifiers.md` documents alias release and machine-key pinning, but no audited backlog item explicitly owns trust reset across release.
- **Disposition + authority:** Valid security invariant; mechanism must follow I008/I003 anchor model. Not explicitly classified by Max.
- **Dependencies:** Alias release implementation, I003 trust store, rotation/revocation model.
- **Required tests/docs/live proof:** Release/re-register under different machine key, old trust removal, warning/history semantics, security docs.
- **Closure state:** **OPEN-UNCLASSIFIED**.

### C045 — Lower-urgency decision: local broker versus relay authority

- **Source heading + lines:** Top Unresolved Architectural Decisions, Local broker vs relay authority, lines 2748-2750.
- **Normalized requirement:** Explicitly define the source of truth and reconciliation rules for cross-machine inbox/offline state.
- **Implementation/backlog evidence:** Current relay connector, local outbox/DLQ, relay peek/poll, and docs describe pieces, but no single authority/reconciliation decision was found.
- **Disposition + authority:** Keep open; do not infer an answer from current implementation accidents.
- **Dependencies:** C019 delivery guarantee/cursors and relay storage model.
- **Required tests/docs/live proof:** Offline/reconnect/replay conflict matrix, relay/local failure injection, reconciliation ADR and delivery-model docs.
- **Closure state:** **OPEN-UNCLASSIFIED**.

### C046 — Architectural-decision sequencing

- **Source heading + lines:** Top Unresolved Architectural Decisions, Meta sequencing, lines 2752-2765.
- **Normalized requirement:** Decide identity and bus safety cheaply first; prototype receive transport and delivery guarantee before locking them; make all other decisions explicit at their owning milestone.
- **Implementation/backlog evidence:** Identity is selected in I008; bus invariant shipped in B098; current polling choice is documented; cursor guarantee remains deferred.
- **Disposition + authority:** Retain with updated status: identity direction and bus are settled, but I008 still needs ADR; transport replacement/delivery guarantee need prototypes.
- **Dependencies:** C036-C045.
- **Required tests/docs/live proof:** Decision ledger/ADRs linked from backlog before implementing irreversible protocol slices.
- **Closure state:** **PARTIAL**.

### C047 — Top action 1: fix `relay connect` and ban silent success

- **Source heading + lines:** Executive Summary, action 1, lines 2783-2787.
- **Normalized requirement:** Parse normal PoW responses, use real node identity, and return non-zero for caught connector failures.
- **Implementation/backlog evidence:** B087 `done`; changelog and connector tests record the fix.
- **Disposition + authority:** Accepted and implemented. The broad phrase “no command ever exits 0 on a caught error” should remain a general regression principle, not be treated as proof for every command from B087 alone.
- **Dependencies:** None.
- **Required tests/docs/live proof:** B087 response-shape suite; real-relay connector smoke; audit other caught-error paths separately.
- **Closure state:** **CLOSED** for B087 scope.

### C048 — Top action 2: honest send state

- **Source heading + lines:** Executive Summary, action 2, lines 2789-2791.
- **Normalized requirement:** Never claim remote delivery from a local enqueue; report queued/accepted/delivered honestly and warn when no connector is live.
- **Implementation/backlog evidence:** B088 `done`; `delivery.state`, `queued ->`, warning, and `--fail-if-queued` tests/docs exist.
- **Disposition + authority:** Accepted and implemented for current send semantics. Actual remote accepted-to-delivered transition remains C021.
- **Dependencies:** I002 for canonical schema; C021 for true delivery tracking.
- **Required tests/docs/live proof:** Existing B088 local/remote/JSON/exit tests; cross-host accepted/delivered proof later.
- **Closure state:** **PARTIAL** — honesty closed; full tracking open.

### C049 — Top action 3: one supported cross-host receive path

- **Source heading + lines:** Executive Summary, action 3, lines 2793-2795.
- **Normalized requirement:** Provide first-class relay-aware receive without hand-rolled polling; use polling now and defer push.
- **Implementation/backlog evidence:** B089 `done`; `c2c monitor` non-destructively peeks relay inbox; B090 fixes the HTTPS fallback hint.
- **Disposition + authority:** Accepted and implemented with polling, matching Max/I004's current canonical transport.
- **Dependencies:** Relay config/identity.
- **Required tests/docs/live proof:** B089 non-drain/dedup tests, two-host monitor smoke, command/quickstart docs.
- **Closure state:** **CLOSED** for supported polling receive.

### C050 — Top action 4: untrusted-data framing and local-only approval

- **Source heading + lines:** Executive Summary, action 4, lines 2797-2799.
- **Normalized requirement:** Every adapter frames peer content as untrusted data; no remote peer can reach or satisfy approval/PreToolUse authority.
- **Implementation/backlog evidence:** B098/B099 are `done`; canonical skill text and approval regressions exist.
- **Disposition + authority:** Hard current invariant, accepted and implemented.
- **Dependencies:** Adapter distribution must remain in sync.
- **Required tests/docs/live proof:** Both approval regressions, embedded-skill conformance, per-client install/start smoke.
- **Closure state:** **CLOSED**, with ongoing regression obligation.

### C051 — Top action 5: identity granularity

- **Source heading + lines:** Executive Summary, action 5, lines 2801-2803.
- **Normalized requirement:** Resolve the shared-key observation before trust work and represent the honest machine/agent trust boundary.
- **Implementation/backlog evidence:** I008 and identity docs.
- **Disposition + authority:** **Source instruction “make keys per-agent” is SUPERSEDED.** Max chose machine-key trust anchor plus optional machine-attested agent keys.
- **Dependencies:** ADR; optional I008 implementation.
- **Required tests/docs/live proof:** C003/C036 proof set.
- **Closure state:** **SUPERSEDED** as written; replacement **DECISION-SETTLED / ADR-OPEN**.

### C052 — Top action 6: write and enforce bus, never RPC

- **Source heading + lines:** Executive Summary, action 6, lines 2805-2807.
- **Normalized requirement:** Messages inform; recipients decide; no message directly causes action.
- **Implementation/backlog evidence:** B098 `done`; code comments, AGENTS.md, and regression tests make this a current invariant.
- **Disposition + authority:** Accepted and implemented.
- **Dependencies:** None; constrains future features.
- **Required tests/docs/live proof:** Maintain B098 tests and architecture/security documentation.
- **Closure state:** **CLOSED**.

### C053 — Top action 7: canonical versioned message JSON

- **Source heading + lines:** Executive Summary, action 7, lines 2809-2811.
- **Normalized requirement:** Define one versioned JSON contract for send/monitor/poll and later adapter generation.
- **Implementation/backlog evidence:** I002 pending/high.
- **Disposition + authority:** Accepted but narrowed: lean v1 contains current fields plus delivery state; trust/verified/priority wait for later versions.
- **Dependencies:** I002; I008/I003 for later fields; I007 consumes it.
- **Required tests/docs/live proof:** Shared schema validation/goldens, version compatibility, schema reference.
- **Closure state:** **OPEN-BACKLOGGED**.

### C054 — Top action 8: gate authority by trust tier

- **Source heading + lines:** Executive Summary, action 8, lines 2813-2815.
- **Normalized requirement:** Pin trust to the machine anchor, warn on change, and prevent unknown peers from urgent/blocking/interrupt authority.
- **Implementation/backlog evidence:** I003 pending/deferred; I008 dependency; B098/B099 provide interim defenses.
- **Disposition + authority:** Accepted future safety work, explicitly deferred. Per-agent pinning must use I008 attestation, not independent TOFU.
- **Dependencies:** I008 then I003.
- **Required tests/docs/live proof:** C005-C006 proof set.
- **Closure state:** **OPEN-DEFERRED**.

### C055 — Top action 9: self-describing relay diagnosis

- **Source heading + lines:** Executive Summary, action 9, lines 2817-2819.
- **Normalized requirement:** Relay-aware doctor/capabilities must report reality and give copy-pasteable fixes.
- **Implementation/backlog evidence:** B093 `done`; doctor relay checks, stable IDs, fix commands, non-zero failures, and docs exist.
- **Disposition + authority:** Accepted and implemented for B093 scope.
- **Dependencies:** Checks must track future transports/features.
- **Required tests/docs/live proof:** Doctor fixture matrix, JSON stability, actual fix-command smoke, docs.
- **Closure state:** **CLOSED**, with drift-maintenance obligation.

### C056 — Top action 10: quickstart plus fake-relay regressions

- **Source heading + lines:** Executive Summary, action 10, lines 2821-2823.
- **Normalized requirement:** Document the public relay/local-vs-relay golden path and build a hermetic adverse-response fake relay; turn each observed bug into a named regression, with hermetic CI and nightly real-relay coverage.
- **Implementation/backlog evidence:** B091/B100 are `done`; cross-machine quickstart exists. I005 is pending/high/do-now; targeted B087/B088/B089/B098 tests exist, but the comprehensive fake-relay asset/nightly split is not closed.
- **Disposition + authority:** Documentation half accepted/closed; test-infrastructure half accepted and backlog-open.
- **Dependencies:** I005; release/CI ownership for nightly real relay.
- **Required tests/docs/live proof:** I005 adverse fixtures (null/malformed PoW, 401/429/5xx, slow/timeout, truncated JSON, schema mismatch), regression-per-bug, hermetic CI, nightly live suite.
- **Closure state:** **PARTIAL / OPEN-BACKLOGGED**.

### C057 — Executive “first three” and next blockers

- **Source heading + lines:** Executive Summary, “If only three things happen first”, lines 2825-2836.
- **Normalized requirement:** Prioritize honest bridge failure, honest send plus usable receive, and data-not-instructions/approval lockdown; then settle identity granularity and bus safety before more roadmap work.
- **Implementation/backlog evidence:** B087-B090 and B098-B099 are done. Bus safety is settled. Identity is settled differently by I008, with ADR/optional implementation deferred.
- **Disposition + authority:** The immediate three are closed. Of the two follow-up blockers, bus is closed and identity's source answer is superseded by Max's machine-anchor decision.
- **Dependencies:** I008 ADR for durable closure; I002 is the next active dependency hub identified elsewhere.
- **Required tests/docs/live proof:** Maintain B087-B090/B098-B099 regressions; promote I008 to ADR with replacement tests.
- **Closure state:** **PARTIAL** — operational priorities closed; identity ADR still open.

## Open and unclassified roll-up

### Explicitly open/backlogged or deferred

- I002/canonical message schema: C001, C004, C011, C021, C042, C053.
- I003/trust tiers and pinning: C005-C006, C029, C041, C054.
- I004/push-dependent delivery/read receipts: C017, C019-C035, C037, C039.
- I005/fake relay: C024, C056.
- I007/harness contract: C009-C016.
- I008/optional machine-attested agent identity and ADR: C003-C005, C017, C025, C031, C033, C036, C041, C051, C057.

### Open-unclassified (no authoritative owner found)

- C040: overall relay deployment/federation model.
- C043: complete c2c-versus-harness prompt-injection responsibility boundary.
- C044: explicit trust reset across alias release/re-registration.
- C045: local-broker-versus-relay inbox authority and reconciliation.

These four should not be silently promoted to current commitments. They need coordinator/Max classification or a backlog/ADR owner.

## Heading-coverage self-check

All headings whose start lines fall within 1986-2836 are covered:

- Third Milestone (1994): Summary/Goal C002; In scope C003-C006; Out of scope C007; AC/tests/docs/DoD/sequencing C003-C008.
- Fourth Milestone (2141): Summary/Goal C009; In scope C010-C014; Out of scope C015; AC/tests/docs/DoD/sequencing C009-C016.
- Fifth Milestone (2284): Summary/Goal C017; In scope C018-C022; Out of scope C023; AC/tests/docs/DoD/sequencing C017-C024.
- Sixth Milestone (2419): Summary/Goal C025; In scope C025-C028; Privacy C029-C031; UX C032; Protocol C033; Out of scope C034; AC/tests/docs/sequencing C025-C035.
- Top Unresolved Architectural Decisions (2591): blocking decisions C036-C039; just-in-time decisions C040-C043; lower-urgency items C044-C045; sequencing C046.
- Executive Summary: Top 10 Actions (2769): all ten actions enumerated one-for-one as C047-C056; “If only three…” covered by C057.
- The unheaded M2 tail at lines 1986-1990 is covered by C001.

Mechanical checks:

- Stable IDs are contiguous: C001-C057.
- Every row contains all required fields: source heading/lines, normalized requirement, implementation/backlog evidence, disposition/authority, dependencies, proof, and closure state.
- No source roadmap proposal is treated as authoritative merely because it appears under a milestone/action heading.
- Every occurrence in this range of the per-agent-key premise is reconciled to Max/I008's machine-key-anchor decision.
