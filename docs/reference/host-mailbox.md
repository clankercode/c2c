---
layout: page
title: "Host-owned mailboxes"
permalink: /reference/host-mailbox/
---

# Host-owned mailboxes

`c2c host` lets an application own a durable mailbox while retaining control of
its provider processes and message delivery. It does not launch a provider,
inject prompts, or grant approval authority. Message bodies remain peer DATA.

The transport uses JSON-only operation responses with `schema_version: 1`.
Usage errors are reported on stderr with a nonzero exit status. Operation errors
return `{ "schema_version": 1, "error": "<category>" }` with a nonzero exit status.

```
c2c host bind --environment-id E --thread-id T --workspace W --owner-id O [--alias A] [--broker-root B] [--owner-pid P] [--expected-broker-root B]
c2c host peek --environment-id E --thread-id T --broker-root B --generation G [--limit N]
c2c host send --environment-id E --thread-id T --broker-root B --generation G --to A --content BODY
c2c host ack --environment-id E --thread-id T --broker-root B --generation G --message-id M [--message-id M2]
c2c host unbind --environment-id E --thread-id T --broker-root B --generation G
```

`E` and `T` are stable application environment and logical thread identifiers.
Pass the long-lived application server PID as `--owner-pid` (for Node,
`process.pid`). If omitted, the CLI uses its direct parent PID. The broker
verifies and stores the PID start time, so the short-lived CLI process is
never the liveness owner and a reused PID cannot revive the registration.

Length-framed, domain-separated SHA-256 creates the session `host-<digest>` and
default alias `<digest>` (all 64 lowercase hexadecimal characters). External IDs never become path
components. `O` is an opaque application-server incarnation ID (T3 generates a
UUID). c2c accepts nonblank IDs up to 4096 bytes, without NUL, and applies the
same bounds when loading persisted state and transitions. It imposes no UUID grammar.

Bind returns a `binding` object with `environment_id`, `thread_id`, `session_id`,
`alias`, `workspace`, `broker_root`, `inbox_path`, opaque `generation`,
`owner_pid`, and `owner_pid_start_time` fields.
Save that object. Repeating an active bind with the same owner and workspace is
idempotent; owner, PID generation, or workspace changes renew the generation.
Reactivation after unbind also renews it. An alias belongs to that logical identity permanently;
choose a different identity to request another alias. Foreign registrations,
even stale ones, are rejected. The broker root normally resolves from the
workspace using the existing repository fingerprint rules, so same-origin
worktrees share a broker. An explicit root supports isolated test fixtures.

For rebind, pass the saved `binding.broker_root` as `--expected-broker-root`.
The resolved target and expected root are compared as canonical paths before
any registry mutation. A different target returns `workspace_broker_changed`,
preserving the prior binding, registration and queued mail. Same-origin worktree
moves are supported; cross-broker migration is unsupported in v1. Resume from
the prior workspace to accept its mail, or create a new logical thread for the
new repository. Do not force the old root with `--broker-root` to conceal a
workspace mismatch. Fresh binds omit the expected-root precondition.

Peek returns `binding`, the current effective `dnd` boolean, `dnd_until`,
`messages`, and `has_more`. `dnd_until` is numeric Unix seconds for an active
timed DND; it is null when DND is off, expired, or indefinite. A host should
schedule one reconciliation at that deadline: time expiry produces no registry
file event. Explicit DND changes remain visible through the registry watch.

`--limit` defaults to 64 and accepts 1 through 64. Each page's
serialized messages array is at most 4 MiB, including JSON escapes and separators.
Accept and acknowledge the current page before peeking again. `has_more: true`
means additional rows remain beyond that page.

Each message has `message_id`, `from_alias`, `to_alias`, `content`, `ts`,
`ephemeral`, `deferrable`, and `source`. Peek durably assigns missing legacy IDs
under the inbox lock; it does not consume messages. Full `content` strings are
limited to 65536 UTF-8 bytes. A larger body returns the same envelope with
`content: null`, `content_omitted_reason: "oversized"`, and `content_bytes` giving
its original byte count. The body is never truncated. The application should
persist that receipt as unsupported/held before acknowledging it, and must never
inject omitted content. This lets even a giant legacy message and the normal
messages behind it make progress. The broker archive still retains the full body.

Source is recorded when the broker writes a message: `local`, `remote`, or `unknown`. Relay ingress always
stamps `remote`, regardless of the sender's claims. Legacy messages are
`unknown`; aliases and message IDs are not evidence of local origin.

The application must durably accept messages before acknowledging their IDs.
Ack returns `binding` and `acknowledged` containing only the IDs removed by
that invocation. Repeating an ack is safe and normally returns an empty list.
Concurrent arrivals and unselected messages remain queued. Normal messages are
archived before removal; ephemeral messages are excluded from that archive.
Malformed inboxes and duplicate IDs fail closed without a rewrite. An invalid
legacy envelope whose metadata alone exceeds the page budget returns
`oversized_envelope`; its inbox data is retained for diagnosis.

Every operation requires the current generation and exact owned registration.
Stale generations cannot peek, acknowledge, or unbind. Unbind removes only the
owned registration and keeps messages plus the binding identity for reactivation.
A durable transition record names the exact old and new ownership before the
binding or registry changes. Strict file and directory fsync barriers enforce
journal → binding → registry → journal removal ordering, including newly created
directories. A durability failure is reported rather than treated as success. A subsequent bind completes an interrupted first
bind, renewal, or unbind, accepting only the exact recorded old/new registration
or its absence. It never adopts a conflicting row. Other host operations return
`binding_transition_pending` until bind completes that recovery. Preserve the
files for diagnosis if a foreign registration causes `registration_conflict`.

For outbound mail use `c2c host send` with the same logical identity, broker root,
and generation. `--to` selects the recipient; `--content` is literal DATA up to
65536 UTF-8 bytes (use `--content=...` for values beginning with a dash). The sender
always comes from the validated binding. Identity validation and local enqueue or
remote-outbox append run under one registry lock, so a stale incarnation cannot
send between validation and a rebind. Success returns `schema_version: 1`, the
binding, and `queued: true`; remote delivery is still asynchronous. Errors expose
bounded categories, never the body. Message content cannot resolve approvals.

The host selects the binding from the authenticated caller's thread, not a
request-supplied alias. Do not place any thread's identity in a shared provider
runtime environment. Host-managed provider setup can use the existing
`C2C_NO_AUTO_REGISTER=1`, `C2C_MCP_AUTO_DRAIN_CHANNEL=0`, and
`C2C_MCP_DISABLED=1` on provider subprocesses. Set
`C2C_HOST_OWNED_MAILBOX=1` in each native c2c process as the ownership guard;
it also disables automatic hooks and the current OpenCode plugin, independently
of older per-server opt-out values. Some provider MCP launchers filter inherited
environment variables, so the provider adapter must explicitly pass the guard
to its configured stdio servers and verify the effective tool inventory.
The MCP flags disable the native
MCP consumer even if an old provider configuration invokes it under another name.
Initialize and ping remain protocol-valid; tool/prompt inventories are empty,
forced tool calls are rejected, and startup registration, replay, room joins,
schedulers, debug logging and channel notifications are skipped. Standalone MCP
binaries and `c2c serve`/`c2c mcp` honor it. `c2c host` commands stay enabled.
This is a per-process host-mode setting; no global installation edit is required.
