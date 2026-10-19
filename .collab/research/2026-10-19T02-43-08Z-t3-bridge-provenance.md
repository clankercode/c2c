# t3-bridge provenance and source-thread findings

- Investigated read-only on 2026-10-19 UTC.
- Scope: /home/xertrov/src/t3-bridge, c2c master at the current checkout, and T3 Code implementation worktree /home/xertrov/src/refs/t3code/.worktrees/c2c-tools.
- No source code or existing documentation was changed; this note is the only new file.

## What t3-bridge actually does

t3-bridge is an external T3 MCP client/CLI. Its README describes it as a zero-dependency client for project/thread discovery, launch, messaging, settling, and completion wakes; it does not embed a T3 server or add a provider adapter ([README.md:7-8](/home/xertrov/src/t3-bridge/README.md:7), [README.md:31-43](/home/xertrov/src/t3-bridge/README.md:31)).

Its HTTP MCP client:

- reads a configured token from the bridge config;
- sends authenticated JSON-RPC POSTs to <T3_URL>/mcp;
- initializes MCP once, stores the returned mcp-session-id, and sends that session id on later requests;
- calls arbitrary named MCP tools through tools/call.

Evidence: [src/mcp-client.mjs:47-70](/home/xertrov/src/t3-bridge/src/mcp-client.mjs:47), [src/mcp-client.mjs:77-112](/home/xertrov/src/t3-bridge/src/mcp-client.mjs:77).

The default endpoint is a configured URL (default http://127.0.0.1:3773), not runtime discovery from T3 state: [src/config.mjs:1-7](/home/xertrov/src/t3-bridge/src/config.mjs:1), [src/config.mjs:36-55](/home/xertrov/src/t3-bridge/src/config.mjs:36). The bridge stores its own token, config, launch records, and durable wake outbox under ~/.config/t3-bridge and ~/.local/state/t3-bridge: [README.md:55-78](/home/xertrov/src/t3-bridge/README.md:55), [src/config.mjs:12-41](/home/xertrov/src/t3-bridge/src/config.mjs:12).

## How send provenance works

The bridge send wrapper calls the generic T3 t3_thread_send operation. It passes:

- target threadId;
- message text with a generated reply reminder appended;
- an idempotent clientRequestId derived as SHA-256 of threadId + NUL + text.

Evidence: [src/t3/thread.mjs:6-21](/home/xertrov/src/t3-bridge/src/t3/thread.mjs:6).

The optional caller argument is used by the bridge to choose the auto/full-access T3 token and to generate the reminder text. It is not passed as a senderThreadId or other native T3 message-origin field: [src/caller.mjs:1-4](/home/xertrov/src/t3-bridge/src/caller.mjs:1), [src/caller.mjs:32-43](/home/xertrov/src/t3-bridge/src/caller.mjs:32), [src/t3/thread.mjs:9-15](/home/xertrov/src/t3-bridge/src/t3/thread.mjs:9).

T3's external MCP service supplies native source-thread provenance only when the MCP caller is itself a T3 thread. OrchestratorMcpService.sendToThread loads the caller/target scope and passes senderThreadId: parent.thread.id when a parent caller exists, while setting createdBy: "agent" and creationSource: "mcp": [apps/server/src/mcp/OrchestratorMcpService.ts:2503-2533](/home/xertrov/src/refs/t3code/.worktrees/c2c-tools/apps/server/src/mcp/OrchestratorMcpService.ts:2503).

The T3 command and conversation contracts permit optional senderThreadId; the orchestrator copies it into persisted conversation messages and user turn items, with role: "user": [packages/contracts/src/orchestrationV2.ts:1089-1103](/home/xertrov/src/refs/t3code/.worktrees/c2c-tools/packages/contracts/src/orchestrationV2.ts:1089), [packages/contracts/src/orchestrationV2.ts:2092-2103](/home/xertrov/src/refs/t3code/.worktrees/c2c-tools/packages/contracts/src/orchestrationV2.ts:2092), [apps/server/src/orchestration-v2/Orchestrator.ts:5444-5458](/home/xertrov/src/refs/t3code/.worktrees/c2c-tools/apps/server/src/orchestration-v2/Orchestrator.ts:5444).

The web timeline carries this field into its ChatMessage model and renders a clickable “Sent by another agent” control that opens senderThreadId: [apps/web/src/types.ts:92-106](/home/xertrov/src/refs/t3code/.worktrees/c2c-tools/apps/web/src/types.ts:92), [apps/web/src/session-logic.ts:642-671](/home/xertrov/src/refs/t3code/.worktrees/c2c-tools/apps/web/src/session-logic.ts:642), [apps/web/src/components/chat/MessagesTimeline.tsx:2215-2219](/home/xertrov/src/refs/t3code/.worktrees/c2c-tools/apps/web/src/components/chat/MessagesTimeline.tsx:2215), [apps/web/src/components/chat/MessagesTimeline.tsx:2392-2412](/home/xertrov/src/refs/t3code/.worktrees/c2c-tools/apps/web/src/components/chat/MessagesTimeline.tsx:2392).

Therefore, an external t3-bridge send THREAD ... call has no native caller thread to derive. It can authenticate as a T3 outside agent and send a normal message, but it does not produce the same native clickable source-thread attribution unless the T3 side is extended with a trusted source-thread capability or the call originates inside another T3 thread.

## Where t3-bridge carries thread context

The bridge preserves thread IDs in its own control plane:

- Launches record thread_id, caller, wake target, tag, workspace, project, provider, model, and timestamps in a lock-protected atomic JSON file: [src/t3/launch.mjs:15-71](/home/xertrov/src/t3-bridge/src/t3/launch.mjs:15), [src/launch-state.mjs:21-43](/home/xertrov/src/t3-bridge/src/launch-state.mjs:21), [src/launch-state.mjs:47-98](/home/xertrov/src/t3-bridge/src/launch-state.mjs:47).
- It resolves an omitted thread from explicit input, T3_THREAD_ID, or the most specific active launch record matching the current worktree/cwd; ambiguity fails closed: [src/thread-context.mjs:10-37](/home/xertrov/src/t3-bridge/src/thread-context.mjs:10).
- Completion wakes have a structured payload containing source: "t3", thread_id, target, caller, timestamp, workspace/branch context, and a settle_hint: [src/routing.mjs:40-64](/home/xertrov/src/t3-bridge/src/routing.mjs:40), [src/wake.mjs:40-58](/home/xertrov/src/t3-bridge/src/wake.mjs:40).
- A local bridge target makes the thread origin visible in presentation text as t3 thread <id> -> <target>, while retaining structured thread_id in the payload: [src/routing.mjs:83-107](/home/xertrov/src/t3-bridge/src/routing.mjs:83).
- The wake outbox persists full event payloads and deduplicates by event ID; credentials are resolved only during delivery: [README.md:38-53](/home/xertrov/src/t3-bridge/README.md:38), [docs/t3code-bridge-skill.md:20-24](/home/xertrov/src/t3-bridge/docs/t3code-bridge-skill.md:20).

This is the useful inspiration: carry a structured source-thread reference next to the message for routing, deduplication, and presentation. It is not the same as T3's trusted senderThreadId, because the bridge's thread_id is an event/control-plane field and is not inserted into the target thread's native conversation record.

## Comparison with c2c

c2c's current message model has:

- from_alias and to_alias;
- untrusted content;
- stable optional message_id;
- transport source = Local | Remote | Unknown;
- delivery flags such as deferrable and ephemeral.

Evidence: [ocaml/c2c_mcp_helpers.ml:105-115](/home/xertrov/src/c2c/ocaml/c2c_mcp_helpers.ml:105), [ocaml/c2c_mcp.mli:180-205](/home/xertrov/src/c2c/ocaml/c2c_mcp.mli:180). The versioned JSON schema defines source as transport origin and reserves in_reply_to as a message-id threading pointer; it has no source-thread identity field: [docs/reference/message-schema-v1.md:43-60](/home/xertrov/src/c2c/docs/reference/message-schema-v1.md:43), [docs/reference/message-schema-v1.md:62-78](/home/xertrov/src/c2c/docs/reference/message-schema-v1.md:62).

c2c's reply_via is a reply-hint/presentation value used when formatting the untrusted envelope; it is not a verified thread identity: [ocaml/c2c_mcp_helpers.ml:867-900](/home/xertrov/src/c2c/ocaml/c2c_mcp_helpers.ml:867). Current c2c documentation also explicitly warns that aliases/message IDs are not evidence of local origin: [docs/reference/host-mailbox.md:74-86](/home/xertrov/src/c2c/docs/reference/host-mailbox.md:74).

The c2c host binding's thread_id identifies the receiving application mailbox, not a message sender's T3 conversation: [docs/reference/host-mailbox.md:25-45](/home/xertrov/src/c2c/docs/reference/host-mailbox.md:25). A T3-bound host therefore cannot obtain native T3 “sent by thread X” behavior from that field alone.

## Recommended design implications

1. For c2c-native clients, a future versioned optional origin object could carry advisory metadata such as source_thread_id, source_thread_title, source_environment, and a T3 deep-link. This should be treated as peer DATA/presentation metadata, never as authorization or proof of origin. A v2 field is preferable to silently adding a v1 required field because v1 deliberately treats unknown keys as forward-compatible.
2. The bridge-style shape is useful: preserve the source-thread reference in structured message/event metadata, keep it available to UI renderers, and use a deterministic message/request ID for retries and deduplication. Do not put only a pretty-printed “from thread …” string in the body.
3. c2c cannot make T3's native timeline show the trusted clickable attribution by itself. Calling external t3_thread_send through t3-bridge creates normal user-message semantics; it has no authenticated caller thread from which T3 can derive senderThreadId. Supplying a caller-chosen senderThreadId would be spoofable.
4. Exact native T3 attribution requires a T3-side trusted ingress/adapter, or a send that originates from a real T3 caller thread. That adapter would need to authenticate the c2c binding, map it to an allowed source thread, and set senderThreadId server-side.
5. If the requirement is only for c2c peers or local bridge/webhook consumers to see “from T3 thread …”, c2c can support a presentation-level origin reference without changing T3. It must label it advisory/unverified unless the connector has an authenticated authority for the mapping.
6. t3-bridge itself is not a drop-in solution for transparent c2c DATA: its send wrapper calls generic t3_thread_send, which may start, steer, or queue a normal T3 user message. It is appropriate for explicit operator automation and completion wakes, not for bypassing T3's c2c mailbox/DATA policy.

## Uncertainty / blockers

- This review did not run a live T3 server or inspect browser behavior interactively; conclusions are from source and bundled MCP schemas.
- The c2c repository has no current source-thread provenance field, so exact cross-client source-thread UI parity needs a protocol and consumer design before implementation.
- The T3 senderThreadId field is available in the current inspected worktree, but compatibility with a future unmodified T3 release must be verified against that release's contract.

