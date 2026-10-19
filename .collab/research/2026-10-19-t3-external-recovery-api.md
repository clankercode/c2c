# Model-availability recovery through unmodified T3

Date: 2026-10-19. Read-only source investigation by delegated researcher,
incorporated by the coordinator. No source changes, live sends, builds, tests,
credentials read or services restarted. Paths below are relative to
`/home/xertrov/src/refs/t3code/.worktrees/c2c-tools`; these findings describe
readable source, not a verified running version on either buildbox.

## Available evidence

- `packages/contracts/src/orchestratorMcp.ts:293-337`: thread listing exposes
  lineage, provider instance/model, status, latest run, runtime mode,
  settled/snoozed state and update time.
- `orchestratorMcp.ts:340-423` and
  `apps/server/src/mcp/OrchestratorMcpService.ts:2408-2501`: activity reads
  expose active run, pending-request count, archival/settled/snooze state,
  recent runs and paginated activity. Error rows have run/source-thread IDs,
  visibility, stable item IDs and status.
- `OrchestratorMcpService.ts:817-819,837-874`: error text is only
  `failure.message`. Structured code/class, retry metadata and node/root-node
  IDs are omitted. The external worker cannot directly use the internal
  `latestRootProviderFailure` or a structured-code matcher.
- `OrchestratorMcpService.ts:1843-1888`: capabilities map provider instances
  to `driverKind`. Identify Codex from this mapping, not a model-name guess.
- `apps/server/src/orchestration-v2/ProjectionStore.ts:5116-5169`: bounded
  reads (100 activity items/page, 50 recent runs, 50,000 characters/item).
  The default messages view omits errors; use `view:"activity"`.
- `packages/shared/src/orchestrationV2ThreadError.ts:49-75` versus
  `ThreadManagementService.ts:465-468`: latest executed run is not simply
  maximum ordinal. Queued/unstarted-cancelled runs and completion ordering
  matter. Hold when the bounded external history cannot establish currency.
- `packages/provider-core/src/server/failure.ts:208-252`: a retrying error can
  become failed without advancing its item ID/position. Revisit known items;
  an append-only cursor misses recovery candidates.

## Implementable conservative policy

Monitor enrolled open Codex roots initially after discovery, then nominally
every 60 seconds. Require a current failed execution and complete relevant
local error evidence; exclude active/queued/interrupted/cancelled work,
pending requests, archived/settled/snoozed roots and connector pauses/DND.
Use narrowly matched error-message text, not ordinary messages or tool output.
Exclude quota, auth, account/model access, configuration, context and workspace
failures. Structured codes such as `flexUnavailable` are unavailable here.

Because node IDs are absent, require every failed error of the candidate run
to match the availability policy and reject mixed/ambiguous evidence. Confirm
the root-error invariant against each supported T3 version:
`RunExecutionService.ts:743-763` emits root terminal errors;
`ProviderEventIngestor.ts:680-708` can emit native errors;
`packages/shared/src/orchestrationV2Timeline.ts:75-110` does not hide them by node.
A native-child-only failure in a healthy root must not recover the root.
Truncation, incomplete evidence and unsupported shapes cause visible holds.
An always-disabled monitor does not satisfy the feature's acceptance criteria.

Persist one intent per environment/thread/failed run with error-set evidence,
immutable `Continue` payload, `queue` mode, request identity and credential
generation. Revalidate evidence and holds immediately before submitting.
Share the existing serial worker/rate cap with ordinary delivery. One accepted
intent per failed run; a subsequent failed recovery run is a new candidate on
a later sweep. Reconcile uncertainty by exact identity, never by matching the
common text `Continue`.

## Queue mode and Stop: important limits

- `ThreadManagementService.ts:767-783`: external `queue` becomes
  `queue_after_active`; `auto` can steer. Queue therefore avoids accidentally
  steering a run that starts during preflight.
- `Orchestrator.ts:532-538,5259-5281,5731-5742,5952-5960`: only a blocking run
  or missing-worktree failure selects the queue branch. Held queued work is
  not blocking. On an idle failed root, a new queue-mode Continue can start
  immediately while existing held entries remain untouched.
- `Orchestrator.ts:5389-5395,1287-1300,11194-11235`: a send that actually queues
  inherits a held flag; draining respects it; explicit `queue.resume` clears it.
  This does not stop the separate immediate-start case above.
- `Orchestrator.ts:9888-9899,9075-9114`: Stop marks even an already-failed latest
  executed run with a `run_interrupt_request` activity item. Its status can
  remain failed. Exclude this marker and any observed queued work, and repeat
  the check before submission.
- `Orchestrator.ts:4976-5018`: normal sends clear settlement and snooze before
  choosing queue/start behavior. External send has no atomic failure/hold
  precondition (`orchestratorMcp.ts:425-440`). A Stop, settlement, snooze,
  user run or model change racing after preflight cannot be eliminated here.

This is a useful external monitor with observable guards, not full parity with
the old internal lock/guard. T001 must verify these observable invariants and
document the residual race on x-p35/x-tuf before enabling the policy.

## Credentials and replay

- `OrchestratorMcpService.ts:577-640` and `auth/McpOAuth.ts:534-552`: stable
  command/message IDs use OAuth client-session namespace plus operation and
  request ID. A transport reconnect retains this; re-pairing changes it.
- `OrchestratorMcpService.ts:2503-2537`, `ThreadManagementService.ts:754-799`:
  authorization/archive/mode checks precede receipts. After an ambiguous send,
  a later rejection does not prove the earlier send was not accepted.
- `auth/McpOAuth.ts:461-519`, `auth/EnvironmentAuth.ts:78-79,1285-1296`:
  authorization-code exchange, no refresh grant; current credentials last
  30 days. Reconnect transport automatically but require explicit re-pairing
  on revoked/expired credentials. Never escalate scope during repair.

## Required verification

Use disposable fixtures on x-p35/x-tuf: root/child/mixed failures, pending
provider retry, stopped-failed marker, held queue, in-place updates, large
history, false-positive text, concurrent user start, and transport/re-pair
uncertainty. Verify a queue-mode Continue starts an eligible idle thread and
does not steer an already-started run. Mock clock tests must prove 60-second
cadence, shared one-second spacing, fairness and restart dedupe. Do not claim
a real model outage was tested when only fixture-generated errors were used.
