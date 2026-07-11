# Complete `friction-points-cn.md` source-to-evidence inventory

This is the reviewed-input index for T0 of the friction-closure run. The complete matrix is intentionally split into three stable-ID parts so each source range can be audited and reviewed independently without duplicating 2,836 lines into a second giant table.

## Coverage

| Part | Source lines | Stable rows | Artifact | Author commit | Integrated commit |
|---|---:|---:|---|---|---|
| A | 1-966 | A001-A099 (99) | `.collab/research/friction-cn-inventory-part-a.md` | `95dcc9da` | `95dcc9da` |
| B | 967-1985 | B001-B250 (250) | `.collab/research/friction-cn-inventory-part-b.md` | `689c8f1a` | `d6427f96` |
| C | 1986-2836 | C001-C057 (57) | `.collab/research/friction-cn-inventory-part-c.md` | `3e0def33` | `e3adac98` |

Total: **406 stable normative/decision/observation rows**. All top-level and nested headings are covered by the per-part heading self-checks. No source range is omitted or overlaps another part.

Every row records:

- source heading and line(s);
- normalized requirement or decision;
- implementation/backlog evidence;
- disposition and authority;
- dependencies;
- required tests/docs/live proof;
- closure state.

## Authority rules used

1. Later explicit operator/Max decisions outrank the earlier report proposal.
2. Current implementation plus completed backlog evidence outranks historical failure observations, but a `done` marker alone is not proof.
3. Pending non-deferred backlog work remains actionable.
4. Explicitly deferred ideas remain visible with their dependencies and rationale; they are not silently called complete.
5. Recommendations with no authoritative disposition remain open until reconciliation creates a task or records an operator decision.

The most important supersession is identity granularity: the report's early mandatory per-agent relay-key recommendation is superseded by I008. The controlling decision keeps the machine Ed25519 key as the relay trust anchor and permits a future optional per-agent key only when attested in-band by that machine key.

## Status snapshot before reconciliation

- Part A: 44 closed, 33 partial, 7 open, 11 deferred, 2 superseded, 2 observations.
- Part B: 62 closed, 65 partial, 96 open, 27 deferred.
- Part C: 57 decision/milestone rows using the more precise states `CLOSED`, `PARTIAL`, `OPEN-BACKLOGGED`, `OPEN-DEFERRED`, `DECISION-SETTLED / ADR-OPEN`, `SUPERSEDED`, `OPEN-UNCLASSIFIED`, and `BOUNDARY`.

These counts are an inventory result, not an implementation plan. Repeated milestone ACs/tests/docs were deliberately kept distinct in Part B, so the high open-row count must be deduplicated into bounded slices during TR.

## Unowned/open items discovered outside the original B087-B101/I002-I008 triage

Part A directly identifies:

- A039: monitor healthy-idle heartbeat event;
- A059: shareable address cards / peer token import;
- A073: correlate signed inbound messages with resulting privileged-action audit records;
- A083: real relay self-marker/roundtrip doctor probe;
- A086-A087: redacted `c2c debug bundle` plus its privacy contract.

Part C directly identifies unresolved decisions:

- C040: public/private/federated relay deployment model;
- C043: precise c2c-versus-harness prompt-injection responsibility boundary;
- C044: alias-release trust-reset semantics;
- C045: local-broker-versus-relay authority and reconciliation.

Part B adds many open AC/test/doc rows, but its main dependency hubs are I002 (canonical JSON) and I005 (fake relay plus adverse-response and named-regression oracle). TR must collapse repeated AC/test/doc expressions into minimal tracer-bullet slices without losing any row-to-test traceability.

## Required reconciliation gates

Before implementation dispatch, TR must:

1. resolve B089 versus I002: unified monitoring exists, canonical versioned send/monitor/poll JSON does not;
2. resolve B096 versus I004: non-destructive peek exists, while durable server-side cursors, delivery tracking, waits, and read receipts remain deferred;
3. group all partial/open rows under owned slices or explicit operator dispositions;
4. preserve I003/I004/I006/I007/I008 deferrals unless the operator changes them;
5. convert every unowned item above into a task, a dependency-bound defer, a supersession, or a recorded product decision;
6. retain row IDs as acceptance-criteria traceability through implementation and final verification.

## Structural self-check

- A IDs are contiguous A001-A099 and its heading self-check covers every heading starting in lines 1-966.
- B IDs are contiguous B001-B250, every row has the required eight columns, and its heading self-check covers every heading in lines 967-1985.
- C IDs are contiguous C001-C057, every entry has all seven required evidence fields, and its heading self-check covers the M2 tail, M3-M6, eight blocking/JIT decisions, two lower-urgency decisions, and the top-ten/first-three summaries.
- The three contributor worktrees were based on prerequisite-bearing local-master SHA `c8d5e7c93070058907fa5f342c23c45f63772b2e`.
- No implementation, push, deploy, relay mutation, or product-decision mutation occurred during T0.
