# T3 Code and c2c: feasibility, existing behavior, and integration boundary

Investigated 2026-10-16. Status: research, not an implemented integration.

## Verdict

**Yes: T3 Code can support c2c. Basic c2c use already works in its Codex provider on this machine. Full, durable, provider-independent support needs a T3-side integration and provider DATA-delivery capability; an ordinary thread-send wrapper is insufficient.**

Three different things must not be conflated:

1. **c2c inside a provider running under T3:** CLI identity, sending, and active-turn hook reception can work now. Verified here for Codex, including normal and ephemeral messages.
2. **T3 external orchestration:** T3 already exposes authenticated discovery, reading, sending, and thread lifecycle operations. These can start idle agents, but ordinary sends are user-role inputs.
3. **T3-owned c2c transport:** a stable T3-thread identity, durable inbound mailbox, safe DATA injection, and eligible idle wake across supported adapters. This is feasible but not present in the inspected public interface.

The practical next implementation should start with **T3-owned Codex DATA ingress**, using the app-server connection T3 already owns, then add adapters only after proving their delivery contracts. Do not implement `c2c message -> t3_thread_send(message)` as full c2c support.

## Evidence and versions

- c2c checkout and installed binary: `a0b52e4bb98363b3f53810030915887addb1f9af`, version `0.18.2`, built 2026-10-15.
- Installed T3 AppImage: `/home/xertrov/Applications/T3-Code.AppImage`; live server PID at inspection: 25369, loopback port 3773. Package version/buildVersion: `0.1.0`; the meaningful provenance is commit **`81493efb71e8e8244f95d3e9f71d8369654ab151`**. This is [public upstream](https://github.com/pingdotgg/t3code/commit/81493efb71e8e8244f95d3e9f71d8369654ab151), not an inferred private fork.
- Independently inspected upstream main: `cfafb4bb54d244e4612f5681aad3832ea64cb0fb`. Links below pin the installed commit where locally verified, or explicitly pin this newer upstream snapshot.
- Extracted installed application regions: `/tmp/t3-c2c-installed/regions`; mapping back to bundled line numbers: `manifest.json`. These are compiled source regions, **not** a buildable source checkout. Exact upstream source copies used for comparison: `/tmp/t3-c2c-installed/upstream`.
- Code graph: `t3-installed-81493ef`, freshly indexed from 861 installed application regions. Evidence paths were coverage-checked; no recorded issues for the principal orchestration/adapter files. c2c's older index reported changed metadata for ingress/adoption files, so current source was read directly as well.
- Public-source research was independently delegated. No T3 settings, application binaries, credentials, production service, or repository implementation were changed. Temporary test registrations were removed. Research artifacts are the intended persistent changes.

## What works today, with limits

### Codex under this T3 installation

The current session is registered as `codex-poplar-waffle-m0fg`. `c2c whoami --json` reports native session `01a144c7-0113-7541-a32e-9d13712e5fe0`. T3's durable thread is instead `d0ef50fd-dc5d-4b7f-9b85-2baaf4484ab3`.

Normal and ephemeral test DMs from a temporary local peer arrived automatically after tool calls. The native Codex JSONL transcript contains both as **`role: developer`**, with `<c2c ... source="broker">` and an explicit no-authority reminder. This is positive evidence for **active-turn hooks**, not an idle-wake test. The CLI's `delivery.state: delivered` only establishes broker acceptance; model visibility was checked separately.

An earlier ephemeral probe reached the native research subagent under the parent's alias, rather than appearing in the parent's transcript. The researcher confirmed the exact marker. This is an observed routing-isolation failure: the explorer has a different native thread ID and is unregistered in c2c, yet received the parent-addressed envelope. Which component routed the hook output there remains unresolved. The separately created **T3-owned** child had its own native identity. See the [probe finding](../findings/2026-10-16T12-57-00Z-codex-poplar-t3-hook-probe.md).

The existing setup uses the normal Codex config home's c2c hooks. `c2c install codex` is the existing configuration path for that provider; it is **not** a `c2c install t3` capability. A fresh machine still needs the provider's c2c setup and a usable binary on PATH. T3 has provider-specific config homes/launch arguments/environment; these are not a universal per-thread plugin configuration. [Provider settings](https://github.com/pingdotgg/t3code/blob/cfafb4bb54d244e4612f5681aad3832ea64cb0fb/packages/contracts/src/settings.ts#L552).

### Why the new vanilla-Codex adoption feature is not a T3 integration

T3 launches and owns a **stdio Codex app-server**, observed both in the process tree and [adapter implementation](https://github.com/pingdotgg/t3code/blob/81493efb71e8e8244f95d3e9f71d8369654ab151/apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.ts). c2c's `codex adopt` requires the exact native thread to be loaded in its shared daemon and rejects an embedded app-server thread that cannot be attached safely. See `ocaml/cli/c2c_codex_adopt.ml`, `discover_exact_thread`, and `c2c codex adopt --help`.

Do not start a second app-server for the same thread, intercept T3's private pipes, or independently call `turn/start` behind T3's scheduler. That would leave T3's run state, approvals, and provider lifecycle out of sync. T3 already owns the right connection; the integration belongs behind that boundary. No adoption or daemon mutation was attempted during this research.

### Provider coverage

Only Codex CLI/active hook reception was exercised live. Claude, Pi, OpenCode, Kimi, Muse, Grok, ACP providers, and Cursor under T3 remain **unverified** here. Their standalone c2c support does not prove their embedded T3 runtime loads the same plugins, exposes the same hooks, or preserves identity. Native Monitor/plugin fallbacks may help individual providers, but must be measured in T3 before claiming support.

## External T3 APIs: useful, but insufficient for inbound c2c DATA

### Authenticated MCP

T3 exposes `/mcp` to external clients. Its documented onboarding is Settings -> Connections -> Copy MCP URL, then OAuth approval. Discovery, thread reads, and explicitly authorized control are already available. [Outside-agent setup](https://github.com/pingdotgg/t3code/blob/cfafb4bb54d244e4612f5681aad3832ea64cb0fb/docs/user/outside-agents.md).

`t3_thread_send` has real scheduling semantics: `auto` starts idle threads, steers active turns, or queues when not yet steerable; explicit `queue`, `steer`, and `restart` also exist. Stable `clientRequestId` values derive idempotent message/command IDs. However, its [implementation](https://github.com/pingdotgg/t3code/blob/81493efb71e8e8244f95d3e9f71d8369654ab151/apps/server/src/mcp/OrchestratorMcpService.ts#L2595) passes ordinary text through `ThreadManagementService.sendToThread`, with `createdBy: "agent"` and `creationSource: "mcp"`.

That is **author provenance, not model-role isolation**. T3 explicitly documents these as [user-role messages](https://github.com/pingdotgg/t3code/blob/cfafb4bb54d244e4612f5681aad3832ea64cb0fb/docs/orchestration-v2/orchestrator-mcp-server.md#L371). The installed [service](https://github.com/pingdotgg/t3code/blob/81493efb71e8e8244f95d3e9f71d8369654ab151/apps/server/src/orchestration-v2/ThreadManagementService.ts#L794) checks for a durable `user_message` item. Codex's `toCodexInput` turns the text into regular turn input; `startTurn` uses `turn/start`, and `steerTurn` uses `turn/steer`. Claude's normal start constructs `makeClaudeUserMessageWithAttachments` and offers it to the SDK query. A textual “this is data” prefix alone does not meet c2c's explicit non-user-role contract.

### The apparent WebSocket notification loophole is closed

The public `message.dispatch` schema includes optional `notification`, but the [WebSocket handler](https://github.com/pingdotgg/t3code/blob/81493efb71e8e8244f95d3e9f71d8369654ab151/apps/server/src/ws.ts#L1861) rewrites provenance to `createdBy: "user"`. The [orchestrator](https://github.com/pingdotgg/t3code/blob/81493efb71e8e8244f95d3e9f71d8369654ab151/apps/server/src/orchestration-v2/Orchestrator.ts#L4787) rejects notifications unless they are agent-created, server/provider-originated queued messages.

Further, an internal notification is not automatically a different provider role. [notificationTurnItem](https://github.com/pingdotgg/t3code/blob/81493efb71e8e8244f95d3e9f71d8369654ab151/packages/provider-core/src/server/notification.ts#L212) changes timeline presentation. Codex's ordinary input conversion does not branch on c2c or notification metadata. Reusing only the notification UI would still be insufficient.

### Webhooks and scheduled tasks

Webhooks have tokenized endpoints, optional signatures, templates, and durable scheduling. Bound-thread delivery calls `sendToThread` with `mode: "queue"`; it does not create a DATA-ingress capability. [Webhook dispatch](https://github.com/pingdotgg/t3code/blob/cfafb4bb54d244e4612f5681aad3832ea64cb0fb/apps/server/src/scheduledTasks/ScheduledTaskService.ts#L733).

An explicitly operator-created periodic instruction to check c2c is a possible polling workaround, not arrival-driven messaging. No schedule or webhook was created here. A c2c peer must not gain access to T3's ordinary approval-response API through a bridge.

### Authentication distinctions

- External OAuth MCP-client grants are `/mcp`-only, default to read-only, and have a 30-day lifetime. They cannot be reused as ordinary HTTP/WS credentials.
- Ordinary environment credentials use explicit scopes, including `orchestration:operate`; that still does not grant server notification provenance.
- Provider MCP credentials are bound to environment/thread/provider identity and revoked with the runtime. The implementation uses a sliding 24-hour liveness window, refreshed by activity; do not repeat the overview's stronger absolute-lifetime wording.

[Environment auth](https://github.com/pingdotgg/t3code/blob/cfafb4bb54d244e4612f5681aad3832ea64cb0fb/apps/server/src/auth/EnvironmentAuth.ts#L73), [RPC authorization](https://github.com/pingdotgg/t3code/blob/cfafb4bb54d244e4612f5681aad3832ea64cb0fb/apps/server/src/auth/RpcAuthorization.ts#L40), [MCP credential implementation](https://github.com/pingdotgg/t3code/blob/cfafb4bb54d244e4612f5681aad3832ea64cb0fb/apps/server/src/mcp/McpSessionRegistry.ts#L67).

The inspected surface has no dedicated inbox-delivery-only permission. A purpose-built bridge should get one, rather than an environment-wide token capable of unrelated thread control.

## Recommended implementation

The following names describe **proposed** interfaces; they are not existing commands or APIs.

### T3 owns identity and scheduling

Treat T3 as the **host** of an agent and Codex/Claude/etc. as its provider, rather than treating the whole T3 application process as one c2c peer. A future launcher integration must attach individual threads; merely starting the desktop app cannot establish per-agent identity or delivery.

Use `(T3 environment ID, durable T3 thread ID)` as the logical endpoint. Record the current project/workspace, c2c broker/session binding, provider instance, native thread, and binding generation separately. Titles and provider-session UUIDs must not be keys. The live parent and child already demonstrate distinct native and T3 identities.

At thread enable/create/resume, T3 registers or refreshes its c2c endpoint. A provider switch, crash, idle unload, branch/worktree handoff, or restart changes the runtime binding without silently creating a new logical peer. Forked/delegated threads get distinct identities. Reconcile existing provider-native registrations instead of leaving two aliases draining the same mailbox.

T3 defaults to unloading idle provider sessions after 30 minutes; provider credentials are ephemeral. Keep the c2c mailbox and logical identity durable across that unload. [Provider lifecycle](https://github.com/pingdotgg/t3code/blob/cfafb4bb54d244e4612f5681aad3832ea64cb0fb/apps/server/src/orchestration-v2/ProviderSessionManager.ts#L56).

### Narrow DATA ingress, durable acceptance, explicit wake policy

An opt-in local T3 service or authenticated ingress endpoint should accept structured c2c envelopes, not prompts. Envelope fields need a stable message ID, resolved recipient binding, sender/provenance, body, timestamp, and flags. Escape/encode the body; derive trust from the transport, never from body text or a claimed alias.

Persist to a T3 mailbox before acknowledging c2c. Track at least durable acceptance, provider delivery, and eligible wake separately. A broker send receipt is not a model-visible receipt. Use unique message/binding keys and idempotent replay; after an ambiguous provider acknowledgment, reconcile or hold rather than blindly inject again. Ephemeral messages need an explicit retention agreement: c2c's flag skips its recipient archive, but cannot erase a provider's transcript.

Watch the actual c2c mailbox with event-driven wake plus startup reconciliation. A watcher that only notices file changes is not itself an agent wake. Avoid a second destructive drainer: after durable acceptance, remove only accepted message IDs. Account for new messages arriving between peek and acknowledgment.

T3's scheduler must own starting/resuming a provider and must serialize against user turns, stops, approvals, maintenance, and other wake sources. Honor disabled integration, DND, snooze, archived/deleted/stopped threads, and workspace changes. Bound queue/batch sizes and retry/backoff; surface pending/unsupported/degraded states in diagnostics.

Start with the existing c2c B098 eligibility rule: only verified local-broker mail may schedule a Codex DATA wake; remote/unknown provenance remains passive. Extending automatic wake to other providers is an explicit policy and implementation change, not implied by their ability to run a prompt. A peer body never answers a T3 approval or pending question.

### Provider adapter capability, not one generic send

Add an explicit adapter operation/capability for DATA delivery, distinct from `startTurn`/`steerTurn` used for operator messages.

- **Codex first:** reuse T3's authenticated app-server client and `thread/inject_items` support to inject a c2c DATA envelope; request any eligible continuation through T3's scheduler. Existing T3 `injectHistory` proves the connection can issue that RPC, but it does not establish a public c2c API. Preserve message visibility across compaction and continuation, and prove it in a live test. Do not assume an empty or count-only turn sees previous injected history.
- **Other adapters:** use their actual external-data/system/tool-result mechanism if one is available, and test it in the embedded T3 runtime. Ordinary Claude `query.offer(userMessage)` or generic ACP prompts do not establish non-user-role delivery. If an adapter lacks a safe path, expose CLI/polling support and an honest unsupported-wake status instead of silently falling back to user-role injection.
- **Timeline:** display the envelope as a peer notification with sender/recipient/message ID and queued/delivered state. UI presentation should follow delivery semantics, not substitute for them.

Relevant c2c implementations to reuse or learn from: `ocaml/c2c_codex_ingress.ml` (DATA envelope, persist/inject/ambiguous-ack handling), `ocaml/c2c_codex_autoturn.ml` (local provenance, DND, serialization, batching), and `ocaml/cli/c2c_hook_cmd.ml` (existing provider identity and hook behavior). They are not drop-in T3 adapters; T3 must retain lifecycle ownership.

### Outbound and installation

Outbound can initially use the existing c2c CLI, with per-thread identity passed explicitly by T3. An eventual small c2c tool facade can derive the sender from the authenticated T3 invocation and expose send/list/read/rooms without allowing sender spoofing. Never put one fixed `C2C_MCP_SESSION_ID` in a provider-instance environment shared by several T3 threads.

An eventual `c2c install t3` should enable the integration through a real T3-supported surface, perform capability checks, and report which providers support active delivery/idle wake. Such a command does not exist in this inspected c2c build. There is no demonstrated general-purpose T3 plugin loader to install it into today; a T3 core change or a future supported extension API is needed. [Extension proposal](https://github.com/pingdotgg/t3code/discussions/6837), [custom ACP MCP discussion](https://github.com/pingdotgg/t3code/discussions/13117). The closed [SDK RFC](https://github.com/pingdotgg/t3code/issues/6419) points to a fork's stack and is not evidence of shipped upstream plugin support.

## Decisive comparison

Context: full support means correct per-thread identity, arrival-driven idle wake, and no promotion of peer DATA to operator input.

| Candidate | All requirements | Identity/lifecycle | Arrival-driven wake | DATA isolation |
|---|---|---|---|---|
| Existing provider CLI/hooks | Fail | Native identity works here; T3 lifetime not integrated | Fail for idle hooks | Pass in observed Codex active delivery |
| c2c -> `t3_thread_send` | Fail | Binding can be built | API supports it | Fail: user-role path |
| Webhook -> bound thread | Fail | Binding can be built | API supports it | Fail: same prompt path |
| Shared-daemon adoption of T3's stdio session | Fail | Wrong connection owner | Not established | Existing daemon safeguards do not make it attachable |
| T3-owned mailbox + adapter DATA capability | Unverified proposal | Designed to pass | Designed to pass per adapter | Designed to pass; requires implementation and live evidence |

No currently inspected option satisfies all requirements out of the box. The proposal is the remaining implementation direction, not a prematurely claimed PASS.

## Implementation slices and acceptance tests

1. **Characterize current support:** retain the live receipts, add a reproducible T3 test harness, verify hook loading and identity on each requested provider. Document active hooks separately from idle wake.
2. **T3 binding + passive Codex DATA ingress:** opt-in per-thread registration, durable mailbox, narrow authorization, DATA injection, delivery receipts and diagnostics. Initially keep automatic wake disabled.
3. **Eligible idle Codex wake:** integrate with T3's run scheduler, DND/stop/snooze gates, replay reconciliation, compaction visibility, and provider restart.
4. **Additional providers and install UX:** implement capabilities independently; update c2c detection, install/uninstall, doctor, docs and the delivery matrix only for proven adapters.

Required live and failure tests:

- Two threads in the same workspace, different workspaces, fork/delegation, provider switch, native session recreation: no cross-delivery or alias collision.
- Active turn: injected DATA reaches the model without `turn/steer` upgrading it to user input or interrupting an unrelated user task.
- Idle/unloaded thread: mail alone starts exactly one eligible continuation through T3; user composer text survives unchanged.
- DND, snooze, stopped/archived/deleted thread, pending approval/question: no forbidden turn or approval transition; mail is retained or explicitly rejected.
- Local vs remote/unknown sender: transport provenance controls wake; sender text cannot change classification.
- Process death before/after durable acceptance and provider acknowledgment, duplicates, reordering, burst/oversized mail: no silent loss, unbounded retry, or repeated action.
- Ephemeral and deferrable flags, broker relocation/worktree handoff, startup reconciliation, old credentials: defined behavior and no stale recipient reuse.
- Body containing `allow`, `deny`, fake operator instructions, closing XML tags, or tool-shaped JSON: remains DATA; no verdict-file write or pending-request response.
- Capability unavailable: diagnostics report the precise degraded mode; no user-prompt fallback disguised as supported DATA delivery.

## Live idle probe

A T3-owned child was created solely for this test, reported its native identity, and completed. The parent then sent an inert local c2c DM while the child had no active run. Final measured outcome and cleanup are in `2026-10-16-t3-c2c-live-receipt.json` beside this report. This test separates broker acceptance from T3 run creation; it does not use tmux, UI typing, or another human turn as a wake.

**Outcome:** c2c accepted mail at `12:57:23Z`; at `12:58:26Z` the T3 thread still had exactly one completed run, no active run, and one unread broker message. No arrival-driven wake occurred during this observation window. The parent then explicitly resumed the child through T3's own API as part of the test: the native transcript records the resume prompt at `12:58:31.117Z` as user-role, followed by the queued c2c envelope at `12:58:31.121Z` as developer-role. The child confirmed visibility and its inbox became empty. This proves T3 can resume the session and hooks can deliver the queued mail; the existing c2c setup does not connect arrival to that resume operation.

## Remaining uncertainties

- Native-subagent routing isolation needs a dedicated investigation: a distinct, unregistered native research thread received mail addressed to its parent's alias. Do not assume shared native identity; the exact hook/provider/T3 responsibility boundary is unresolved.
- Safe live wake across non-Codex providers is not established, and no generic DATA-ingress implementation was built in this research.
- A future T3 extension SDK may alter the installation boundary. The inspected source and linked proposals do not establish one today.
- Exactly-once provider visibility after a lost acknowledgment needs a concrete provider-specific reconciliation contract. T3's command idempotency alone cannot guarantee it.

These are bounded implementation/reliability questions, not evidence that T3 integration is impossible.
