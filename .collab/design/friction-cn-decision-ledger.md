# ADR0 — friction-cn decision ledger

Date: 2026-07-10
Status: authoritative ledger; **this document changes zero protocol, code, or
runtime behavior**. It records decisions, deferrals, and open gates so no
future slice defaults into an architectural choice by accident.
Scope: inventory rows C036-C046 of the friction-cn program (the "Top
Unresolved Architectural Decisions" section of the source report
`friction-points-cn.md`, untracked at the main-tree root; rows defined per the
T0 inventory at `.collab/research/friction-cn-inventory-part-c.md` on branch
`friction-cn-inventory-c`), plus
the decision-gated rows from the reconciliation plan's authority table.

Parent plan: [friction-cn reconciliation](../research/friction-cn-reconciliation.md)
(§ "Authority-backed deferrals and decisions" is the source table this ledger
normalizes). Audit provenance: [T1-T3 audit review](../research/friction-cn-audits-review.md).

## How to read this ledger

Three states, three obligations:

- **Settled** — decided by a named authority on a named date. Future work
  conforms to it; changing it requires the same or higher authority.
- **Deferred with authority** — explicitly postponed by a named authority.
  Do not implement, "prepare", or partially ship it; each entry names the
  reactivation gate that must be satisfied first.
- **Open gate** — genuinely undecided. **Current behavior is not evidence of
  a decision.** No agent may infer the answer from what the code happens to
  do today; the named artifact from the named owner class must exist first.

Owner classes: **operator** (Max — product, security, and
expensive-to-reverse architecture), **coordinator** (sequencing, severity,
slice dispatch, merge/push gates), **any-agent-with-review** (may draft
evidence/prototypes behind a gate, never the decision itself).

## 1. Settled decisions

| # | Decision | Rows | Authority + date | Artifact | Implementation status |
|---|---|---|---|---|---|
| D1 | Identity granularity: the **machine identity key is the trust anchor** (one connection per machine), with an OPTIONAL per-agent attestation layer via machine-signed in-band cert (mechanism b). Mandatory per-agent relay keys are **rejected/superseded**. | C036 (feeds C041, C051) | Max, 2026-07-07 (grilling Q2) | [`.backlog/ideas/I008-identity-model-machine-key-as.todo`](../../.backlog/ideas/I008-identity-model-machine-key-as.todo) | Decision settled; **implementation deferred** (see I008 in §2). Promotion of the decision text to a formal `.collab/design/` ADR is still owed and is part of the I008 reactivation gate. |
| D2 | Bus, never RPC — **strict B098 contract**: approval resolution is host-local via the verdict file / local CLI only; no broker-inbox or relay-delivered message — including a configured-supervisor DM with the exact token — may resolve an approval; the legacy inbox-DM verdict path is removed, not provenance-patched. | C038 (feeds C043, C050, C052) | Coordinator selection 2026-07-10, backed by operator's direct request + critical backlog B098; recorded in the decision note | [`friction-cn-b098-decision.md`](../research/friction-cn-b098-decision.md); backlog [`.backlog/bugs/B098-safety-guarantee-no-remote-pee.todo`](../../.backlog/bugs/B098-safety-guarantee-no-remote-pee.todo) (status: done) | **Implemented by slice H1** — branch `friction-h1-strict-approval`, tip `68124bdc` (4 commits on shared base `c8d5e7c9`). Note: H1 is not yet merged into this ledger's branch line, so CLAUDE.md/AGENTS text on pre-H1 lines still shows the stale supervisor carve-out; the strict wording on the H1 tip is canonical. |
| D3 | Canonical receive transport **today is polling**. Push (WSS/streaming), server cursors, and receipts are not the supported path and must not be built piecemeal. | C037 (bounds C017-C035) | Max, 2026-07-07 ("polling is canonical for now", I004 defer) | [`.backlog/ideas/I004-deferred-delivery-read-receipt.todo`](../../.backlog/ideas/I004-deferred-delivery-read-receipt.todo) | Current behavior. This is a *for-now* canonicalization, not a forever choice: re-deciding transport is the I004 reactivation gate in §2 plus open gates G5/G6 in §3. |
| D4 | Message schema: **one lean versioned v1** (only fields emitted today + `delivery.state`), `schema_version` from day one so v2 is non-breaking; trust/priority/verified fields reserved for I003/I008, not shipped early. | C042 (feeds C053) | Max, 2026-07-07 (trusted-swarm-first; I002 body) | [`.backlog/ideas/I002-canonical-versioned-message-js.todo`](../../.backlog/ideas/I002-canonical-versioned-message-js.todo) | In flight as reconciliation slices J1-J5; J5 is the closure gate. |
| D5 | **Trusted-swarm-first** operating posture: the swarm runs among trusted peers; trust tiers, TOFU pinning, and priority gating are not built until the operator opens the system to untrusted peers. This meta-decision is the authority behind the I003/I007/I008 deferrals. | C041 posture (bounds C005-C006, C029, C054) | Max + colleagues, 2026-07-07 | [`.backlog/ideas/I003-deferred-trust-tiers-tofu-pinn.todo`](../../.backlog/ideas/I003-deferred-trust-tiers-tofu-pinn.todo) | Active posture. Interim injection defense is B098 (strict, D2) + B099 untrusted-data framing (H2 slices), not a tier system. |
| D6 | **Split stale I006**: the original "unknown peers cannot be discovered" premise is superseded by opt-in authenticated `c2c list --relay`. The remainder is split — bare-alias uniqueness/ambiguity stays deferred; address cards/tokens sit behind I008/I003; directory/federation/abuse policy needs a product ADR (gate G1/G8). | C040-C041 fringe (A057-A059; B065) | Coordinator reconciliation, 2026-07-10, on T3 audit evidence | [reconciliation § split stale I006](../research/friction-cn-reconciliation.md); [`.backlog/ideas/I006-deferred-relay-peer-discovery.todo`](../../.backlog/ideas/I006-deferred-relay-peer-discovery.todo) | Split recorded; no discovery surface work is authorized outside the gates named. |

## 2. Deferred with authority

Each row: what is deferred, who deferred it, and the reactivation gate. A
deferral is not a backlog nudge — starting this work without the gate
satisfied is an authority violation.

| Defer | What exactly is deferred | Authority | Reactivation gate |
|---|---|---|---|
| I003 — trust enforcement | Trust tiers (blocked/unknown/allowlisted/trusted), TOFU pinning, key-change warnings, priority/interrupt gating by trust. | Max, 2026-07-07 (trusted-swarm-first, D5) | I008 attestation semantics implemented first, **then explicit operator activation** when opening to untrusted peers. Not agent- or coordinator-activatable. |
| I004 — push transport, cursors, receipts, waits | Durable server cursors, independent consumer progress, at-least-once delivery, delivery/consume acks, read receipts, `c2c send --wait[=state]`. Privacy rule already designed (declining to emit `read` indistinguishable from not-yet-read; opt-in both sides). | Max, 2026-07-07 ("Max confirmed defer impl"; polling canonical, D3) | ALL of: J5 (I002 schema closure); the C045 local-broker-vs-relay authority ADR (gate G5); the C039 delivery-guarantee ADR + prototype (gate G6); I008/I003 identity+policy prerequisites. **Do not reopen under the B096 label** — B096's delivered subset is non-destructive peek only, and the H0 peek-ownership fix is security work, *not* part of this deferral. |
| I007 — harness adapter unification | One contract, N thin shims: `c2c env --json`, schema-generated tools, shared safety fragment, one hook contract, conformance self-check. | Max, 2026-07-07 (north-star defer: "build last … else rework") | I002 landed (J5) **and** I008 attestation implemented. The H2a-H2c safety-fragment activation closes B099 only and is explicitly *not* the start of I007. |
| I008 — identity attestation implementation | Per-agent attestation keys, machine-signed certs in the envelope, recipient verification, per-alias key storage. The *decision* is settled (D1); only the build is deferred. | Max, 2026-07-07 (trusted-swarm-first) | Formal ADR promoted from the I008 idea text + **operator authority to activate**. Back-compat requirement stands: unsigned messages keep working. |
| I006 remainder — bare-alias ambiguity | Uniqueness/ambiguity semantics for bare aliases across machines; address cards/introduction tokens. | Coordinator split, 2026-07-10 (D6), preserving Max's 2026-07-07 "whatever for now" | Cards/tokens: behind I008/I003. Directory/federation: behind gate G1 + abuse policy G8. |

## 3. Open decision gates

No entry below may be answered by observing current behavior. Each names the
question, why inference is forbidden, the artifact that must exist, and who
decides. Any agent may *draft* gate evidence (prototypes, threat models,
smoke receipts) behind a gate; only the named owner closes it.

| Gate | Rows | Question | Why not inferable from today | Required artifact | Decision owner |
|---|---|---|---|---|---|
| G1 — relay topology | C040 | Public+PoW relay vs private/tokened vs federation/self-host: what is the supported deployment model? | The single public relay at `relay.c2c.im` is a deployment accident of this swarm's history, **not a product decision**. NO agent may treat "there is one public relay" as the answer. | Product ADR, informed by `relay serve` self-host smoke evidence + PoW abuse-test results (F5d schedule can carry the evidence) | Operator |
| G2 — prompt-injection responsibility matrix | C043 | Where does c2c's anti-injection job end (provenance, framing, capability gating) and the harness/agent's begin? | H1 (strict approval) and H2 (hostile-safe rendering) are concrete *inputs*, not a boundary decision; the rest of the boundary was never decided. | Commissioned security design / red-team artifact (red-team the untrusted-peer-steering pattern explicitly) | Operator (security authority) |
| G3 — message→action audit design | A073; C043 | What audit trail exists when a message *informs* an action (action IDs, attribution)? | Depends on the H1 contract (now settled, D2) **and** on G2's responsibility matrix — cannot be designed before G2 closes. | Security design doc with action-ID scheme, gated behind G2 | Operator accepts; coordinator sequences |
| G4 — alias-release trust reset | C044 | How is trust invalidated when an alias is released (`alias_release_at`) and re-registered by someone else? | The invariant is agreed *valid* but its mechanism folds into I003/I008; nothing today implements or refutes it. | Operator-approved ADR + a named regression-test owner | Operator |
| G5 — local broker vs relay authority | C045 | Which side is source-of-truth for inbox state cross-machine (offline behavior, reconciliation)? | Current split (local broker files + relay outbox) is an accretion, **not an authority model — do not infer one from it**. This ADR explicitly **blocks all I004 cursor/reconciliation semantics**. | Explicit architecture ADR | Operator |
| G6 — delivery guarantee | C039 | At-least-once + `message_id` dedup vs alternatives; decided together with cursor design. | Nothing today delivers cross-host reliably enough to constitute a choice; expensive to reverse once shipped. | ADR + small prototype against the real relay (cursor+ack under induced disconnects, duplicate-rate measurement) | Operator, with coordinator-owned prototype evidence |
| G7 — monitor heartbeat events | A031 (heartbeat half), A039; B025/B110 | Should the monitor stream emit protocol-level heartbeat/keepalive events? | Product decision **after** J1 versions the event stream; must not be smuggled into lean I002 v1. | Product decision note post-J1 | Operator (product); coordinator sequences |
| G8 — abuse/rate policy | A071-A072; B059-B061/B114; C006, C040-C041 | Full identity-bound quotas + public-room behavior beyond today's partial PoW/rate controls. | Existing controls are partial mitigations, not a policy. | Product threat model, co-designed with I003 activation | Operator |
| G9 — real self-marker doctor probe | A083; B101; C056 | Should `c2c doctor` send a real self-marker message through the relay to prove the loop? | Candidate only; privacy/cost properties of the marker are undesigned. | Design note proving privacy/cost-safe marker + explicit doctor-surface ownership; candidate after F5a/H4 | Coordinator may accept a host-local-only marker; escalate to operator if any marker data leaves the host |
| G10 — redacted debug bundle | A077, A086-A087; B065 | Ship a `c2c debug-bundle` style redacted diagnostics export? | Source-only proposal from the friction report; never accepted. | Redaction/secret-scan contract **before** any sharing UX; operator acceptance | Operator |
| G11 — website positioning / Diátaxis IA | B130-B172 (less the D1-slice golden-path subset) | Adopt the report's site-restructure and positioning proposals? | Source-only product proposal; the current site is not wrong merely for differing. | Product-owner acceptance/rejection or selection of bounded page slices | Operator (product owner) |

## 4. Sequencing (C046)

The report's meta-sequencing, reconciled against what is now settled:

1. **Identity granularity — DECIDED** (D1, 2026-07-07). Remaining: ADR
   promotion + deferred build (I008).
2. **Bus-not-RPC — DECIDED strict** (D2, 2026-07-10; H1 implemented).
3. **Receive transport — polling canonical for now** (D3); a future push
   re-decision requires the I004 gate set (J5 + G5 + G6 + I008/I003).
4. **Delivery guarantee — OPEN** (G6); decide with cursor design, prototype
   before lock-in, never default into it by shipping.

Everything else decides just-in-time **but explicitly**: the standing rule of
this ledger is that absence of a decision is never permission, and current
behavior is never a decision record. If you are about to build something
touching a §3 row, stop and check whether the named artifact exists; if it
does not, the work is blocked regardless of how obvious the answer looks.

## 5. Row coverage (C036-C046)

| Row | Disposition here |
|---|---|
| C036 identity granularity | Settled D1; build deferred under I008 (§2). |
| C037 receive transport | Settled-for-now D3; re-decision via I004 gates. |
| C038 bus-never-RPC | Settled strict D2; implemented (H1 tip `68124bdc`). |
| C039 delivery guarantee | Open gate G6, inside the I004 defer. |
| C040 relay topology | Open gate G1 — explicit product ADR; no inference from the current single public relay. |
| C041 trust bootstrap | Posture settled D5 (trusted-swarm-first); enforcement deferred I003; abuse policy open G8. |
| C042 schema evolution | Settled D4; J1-J5 in flight. |
| C043 injection responsibility | Open gates G2 (matrix) + G3 (action audit). |
| C044 alias-release trust reset | Open gate G4, folded with I003/I008. |
| C045 broker vs relay authority | Open gate G5 — explicit ADR; blocks I004; no inference from current accidents. |
| C046 sequencing | §4; this ledger is the C046 artifact. |
