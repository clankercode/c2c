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
c2c host bind --environment-id E --thread-id T --workspace W --owner-id O [--alias A] [--broker-root B] [--owner-pid P]
c2c host peek --environment-id E --thread-id T --broker-root B --generation G
c2c host ack --environment-id E --thread-id T --broker-root B --generation G --message-id M [--message-id M2]
c2c host unbind --environment-id E --thread-id T --broker-root B --generation G
```

`E` and `T` are stable application environment and logical thread identifiers.
Pass the long-lived application server PID as `--owner-pid` (for Node,
`process.pid`). If omitted, the CLI uses its direct parent PID. The broker
verifies and stores the PID start time, so the short-lived CLI process is
never the liveness owner and a reused PID cannot revive the registration.

Length-framed, domain-separated SHA-256 creates the session `host-<digest>` and
default alias `t3-<first-24-digest-characters>`. External IDs never become path
components. `O` identifies the current application server incarnation.

Bind returns a `binding` object with `environment_id`, `thread_id`, `session_id`,
`alias`, `workspace`, `broker_root`, `inbox_path`, opaque `generation`,
`owner_pid`, and `owner_pid_start_time` fields.
Save that object. Repeating an active bind with the same owner and workspace is
idempotent; owner, PID generation, or workspace changes renew the generation. Reactivation after
unbind also renews it. An alias belongs to that logical identity permanently;
choose a different identity to request another alias. Foreign registrations,
even stale ones, are rejected. The broker root normally resolves from the
workspace using the existing repository fingerprint rules, so same-origin
worktrees share a broker. An explicit root supports isolated test fixtures.

Peek returns `binding`, the current effective `dnd` boolean, and `messages`.
Each message has `message_id`, `from_alias`, `to_alias`, `content`, `ts`,
`ephemeral`, `deferrable`, and `source`. Peek durably assigns missing legacy IDs
under the inbox lock; it does not consume messages. Source is recorded when the
broker writes a message: `local`, `remote`, or `unknown`. Relay ingress always
stamps `remote`, regardless of the sender's claims. Legacy messages are
`unknown`; aliases and message IDs are not evidence of local origin.

The application must durably accept messages before acknowledging their IDs.
Ack returns `binding` and `acknowledged` containing only the IDs removed by
that invocation. Repeating an ack is safe and normally returns an empty list.
Concurrent arrivals and unselected messages remain queued. Normal messages are
archived before removal; ephemeral messages are excluded from that archive.
Malformed inboxes and duplicate IDs fail closed without a rewrite.

Every operation requires the current generation and exact owned registration.
Stale generations cannot peek, acknowledge, or unbind. Unbind removes only the
owned registration and keeps messages plus the binding identity for reactivation.
Binding and registry writes are separately atomic; interrupted publication can
leave a generation mismatch, which fails closed rather than adopting a foreign
registration. Preserve the files for diagnosis when `registration_conflict` is
reported unexpectedly.

For outbound mail use the existing `c2c send` with this binding's explicit broker
root, sender alias, and subprocess-only `C2C_MCP_SESSION_ID`. The host must select
the binding from the authenticated caller's thread, not a request-supplied alias.
Do not place any thread's identity in a shared provider runtime environment.
Host-managed provider setup can use the existing `C2C_NO_AUTO_REGISTER=1` and
`C2C_MCP_AUTO_DRAIN_CHANNEL=0`; the host remains the sole mailbox consumer.
