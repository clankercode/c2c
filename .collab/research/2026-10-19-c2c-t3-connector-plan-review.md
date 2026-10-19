# Review: c2c-owned external T3 connector plan

Date: 2026-10-19. Review only; no source, plan, backlog, credentials, or live
services changed. No tests, sends, restarts, or remote probes run.

Reviewed plan:
`.collab/design/2026-10-19-c2c-t3-external-connector.md`.
Scope: user-approved native OCaml connector against an unmodified T3 server,
inbound only, generic agent attribution, auto steer/start, root aliases,
service installation/repair, read+operate OAuth, and owned relay registration.

The design is viable, but the following items should be resolved before the
implementation tickets become their acceptance contract.

## P1 — The specified reply footer cannot use the service's alias

Plan lines 164-178 require the receiving provider to run:

```text
c2c send --from '<this-thread-alias>' --cross-repo '<peer-reply-address>' "<FULL MSG>"
```

The plan also correctly keeps the service registration separate from native
provider identities (lines 156-162). Those requirements conflict with the
current CLI. `validate_from_override` requires the caller's session ID to own
the alias; when the alias belongs to another session, or no caller session
exists, it exits with `refusing to send as ... registered to a different
session than yours`. A registered alias by itself is insufficient.

Evidence:

- `ocaml/cli/c2c_cli_helpers.ml:845-873`: exact session ownership check and
  rejection. A missing caller session takes the same rejection path.
- `ocaml/cli/c2c_cli_helpers.ml:888-899`: every explicit `--from` invokes that
  check before returning a sender identity.
- `ocaml/cli/c2c_send_cmd.ml:238-245`: send resolves this identity before any
  broker enqueue or cross-broker routing.

Remediation: choose an executable reply identity contract. The least invasive
option is to omit `--from` and let a normal c2c sender identity produce the
reply, documenting that it may differ from the incoming thread alias. If
replies must use the thread alias, specify a new narrow c2c-side delegated-send
operation with explicit authorization; do not instruct agents to borrow the
service session ID or enable blanket `C2C_COORDINATOR=1` impersonation. Test
the exact generated footer under a native provider's unrelated session and
with no inherited c2c session. Include cross-host return routing in both cases.

## P2 — A successfully completed discovery scan is not a consistent snapshot

Plan lines 84-87 and 228-233 guard against failed or incomplete enumeration,
but do not handle a complete scan that silently skipped a live row. T3's
thread pages use a numeric offset over a newly read list sorted by mutable
`updatedAt`. An active thread can move from a later page into an already-read
page between requests. The scan still terminates successfully, potentially
with the same total count, and retirement can unbind that active thread and
stop its relay renewal. Project pagination is also expressly live.

Evidence (T3 source root is
`/home/xertrov/src/refs/t3code/.worktrees/c2c-tools`):

- `apps/server/src/orchestration-v2/ThreadManagementService.ts:740-750`:
  sorts each thread list by descending `updatedAt`, then ID.
- `apps/server/src/mcp/OrchestratorMcpService.ts:2366-2405`: independently
  loads/filter/slices the list for every request; `nextCursor` is an offset.
- `apps/server/src/mcp/toolkits/project/tools.ts:45-56`: project pages use a
  current snapshot and explicitly may shift between calls.

Remediation: treat enumeration as positive discovery, not conclusive negative
evidence. Before retiring a previously bound but absent thread, perform a
bounded point read and require affirmative archived/settled/deleted evidence
(or a definitive not-found result). A failed point read retains the route
with degraded health. Add a fixture where the last thread moves to the first
page between page requests, and a corresponding project-list shift case.
Neither may retire a live registration.

## P2 — Retry classification must account for pre-receipt lifecycle checks

Plan lines 195-212 correctly persist the payload/request ID and handle a new
credential namespace, but the same-credential replay case also needs explicit
uncertainty handling. `t3_thread_send` performs current authorization and
lifecycle checks before reaching the durable command receipt. An explicit
steer/restart can succeed, lose its response, and then fail with no steerable
run when retried after completion. Likewise, an accepted auto send retried
after archival or a runtime-mode change can fail before deduplication. That
failure does not prove the original message was rejected.

Evidence (same T3 source root):

- `apps/server/src/mcp/OrchestratorMcpService.ts:2505-2533`: current runtime
  and interaction ceilings are checked before the send.
- `apps/server/src/orchestration-v2/ThreadManagementService.ts:756-780`:
  archival and explicit steer/restart eligibility are checked before dispatch.
- `apps/server/src/orchestration-v2/Orchestrator.ts:11310-11355`: receipt
  replay happens only inside the later dispatch call.
- `apps/server/src/auth/McpOAuth.ts:547`: the credential session provides
  the request namespace, separate from the MCP transport session.

Remediation: once submission is ambiguous, later permission/archival/
no-steerable errors must not convert it into a definitive initial rejection.
Reconcile by durable message identity through supported reads when possible;
otherwise keep it `uncertain` for explicit operator resolution. Preserve this
rule across ordinary reconnects as well as re-pairing. Add accepted-but-lost-
response fixtures followed by run completion, archival, and mode elevation;
never mint a new request ID or report these as proven nondeliveries.

## Confirmed and residual limits

- `auto` is the right single default request: it steers a steerable run or
  requests a new start (`ThreadManagementService.ts:778-783`). Avoiding a
  two-request fallback is correct.
- External MCP sends set `createdBy:"agent"`, `creationSource:"mcp"`
  (`OrchestratorMcpService.ts:2531-2532`), and the client presentation uses
  generic agent attribution without `senderThreadId`
  (`packages/client-runtime/src/userMessage.ts:43-50`).
- Root eligibility is necessarily a recent observation without an atomic
  conditional-send API. A root may settle after the last read; ordinary
  dispatch clears settled/snoozed metadata
  (`Orchestrator.ts:4976-5017`). Recheck before dispatch and document that
  residual race rather than promising an absolute no-revival guarantee.
- The plan already treats full-access denial, token rotation, missing relay
  unregister, raw-consumer fencing, and size/capacity bounds as explicit work.
  Those remain important implementation/live-test gates, not findings of an
  already implemented defect.

Source freshness: c2c HEAD was
`e655cd267de34c277d655a288ec2013ff3cc8fc9`. Its graph index was dated
2026-10-14 and marked broker/relay files changed; source files were read
directly for all cited behavior. The T3 source worktree's `.git` pointer was
invalid, so no source SHA could be established there; these references verify
the readable local source, not the binaries running on x-p35/x-tuf.

## Re-review resolution — PASS at the planning stage

Re-reviewed 2026-10-19 after the coordinator revised the plan and P9 task
criteria. No remaining material inconsistency was found in the revised
contracts. The three findings above are resolved as follows:

1. **Reply identity — resolved.** Plan lines 169-183 now generate a plain
   `c2c send` command, explicitly use the provider's own identity, prohibit
   borrowing the receiving service identity, and require safe on-demand
   sender initialization to be verified in the actual provider environment.
   P9.M1.E1.T005 repeats this contract and requires the generated recipe to
   work both with a native provider session and with no inherited c2c
   identity. Native sender initialization is an implementation/test gate,
   not an unsupported assertion that today's CLI handles every provider.

2. **Mutable discovery pages — resolved.** Plan lines 245-249 treat lists
   only as positive discovery and require same-environment point evidence
   before retirement, preserving state on read/auth failures.
   P9.M1.E1.T004 carries the same acceptance criterion.

3. **Pre-receipt replay errors — resolved.** Plan lines 219-223 explicitly
   preserve ambiguity after same-credential permission/archive/steerability
   failures; P9.M1.E1.T005 likewise forbids treating those errors as proof of
   nondelivery. Original payload/request identity remains durable, and
   uncertain entries are held instead of assigned a new request ID.

The plan also correctly records the non-atomic settle/send race at lines
250-252. It retains native OCaml ownership, zero T3 source changes, generic
agent attribution, manual c2c replies, `auto` default steering/start behavior,
read+operate-only credentials, conservative repair, and exact relay ownership.

Residual gates remain those already named in the plan: live T3 API/version
compatibility, provider-side native sender initialization, relay ownership and
retirement behavior, capacity defaults, and fixture/two-host proof. This PASS
does not certify implementation or running binaries. This re-review changed
only this research note; no tests, live sends, restarts, or remote probes ran.

## Recovery and buildbox-install refinement — PASS

An independent read-only review on 2026-10-19 checked the additional recovery
policy, buildbox gate and all eleven P9 tasks. No runtime tests or operations
were performed. The reviewer initially identified one additional gap:
`just bi` rebuilds before copying, so comparing installed files only against
mutable build output could miss divergence from the tested artifacts.

Resolved by planned `C2C_VALIDATION_RECEIPT` support in M1 T007: compare the
preserved successful source/dependency/eight-artifact manifest inside the
install lock, after rebuild and before copying. Mismatches refuse the install;
post-install verification uses that same original manifest. This is planned
guard functionality, not already-shipped behavior.

Final verdict: PASS at the planning stage. The reviewer verified:

- Current-run, local error evidence, narrow text matching, whole-run ambiguity
  holds and rereading in-place error updates.
- Explicit Stop-marker/queued-work guards and honest external race limits.
  Queue-mode recovery avoids steering but does not guarantee internal Stop
  parity or prevent racing settlement/snooze changes.
- One durable recovery per failed run, initial/60-second checks, shared
  serialized one-per-second submissions, persistent spacing and uncertainty.
- T007 depends on T005, T006 and recovery T009; the validation -> installation
  -> live proof milestone uses explicit leaf dependencies.
- Installation checks the tested source and artifacts before any copy.

Coordinator validation: `bl sync`, `bl check --strict`, task dependency
read-back, all eleven headers against their indices, and whitespace checks.
Implementation, buildbox test success, installation and live proof remain
pending. These checks do not claim the monitor is running.
