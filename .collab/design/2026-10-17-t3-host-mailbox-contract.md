# T3 host mailbox implementation contract

Owner: P6.M1. Research: `../../research/2026-10-16-t3-code-c2c-support.md`.

## Ownership

T3 owns provider processes, durable thread identity, mailbox acceptance, scheduling,
and model delivery. c2c owns registration, routing and broker files. There is no
second app-server, prompt-based message bridge, or transport access to approvals.
Support starts with Codex. Other adapters report unsupported DATA delivery.

The stable identity is a domain-separated SHA-256 of environment ID and T3 thread
ID, never a provider/native thread or title. A deterministic `host-<digest>` session
and full lowercase hexadecimal SHA-256 default alias are used; no raw external ID enters paths.
T3 keeps per-thread enable and wake/mute state, and current broker binding. The
provider process environment must not carry any particular thread's c2c identity.

## c2c transport

Provide one `c2c host` command group with JSON-only stdout, version 1 responses:

```
c2c host bind --environment-id E --thread-id T --workspace W --owner-id O [--alias A] [--broker-root B] [--owner-pid P] [--expected-broker-root B]
c2c host peek --environment-id E --thread-id T --broker-root B --generation G [--limit N]
c2c host send --environment-id E --thread-id T --broker-root B --generation G --to A --content BODY
c2c host ack --environment-id E --thread-id T --broker-root B --generation G --message-id M [--message-id M2]
c2c host unbind --environment-id E --thread-id T --broker-root B --generation G
```

Bind returns `{schema_version:1,binding:{environment_id,thread_id,session_id,alias,
workspace,broker_root,inbox_path,generation}}`. Owner ID is an opaque T3-server incarnation identifier (T3 generates a UUID);
repeat bind by the same owner is idempotent. T3 passes its long-lived server PID
with `--owner-pid`; the broker verifies/stores the process start time. If omitted,
the CLI uses its direct parent, never the short-lived CLI PID. Bindings additionally
return `owner_pid` and `owner_pid_start_time`. A changed owner/PID generation/workspace
renews the opaque generation. Every later command validates it before touching data. Reject
foreign registration conflicts. Unbind removes only its own registration, retaining
the inbox and binding identity for later reactivation. Test fixtures may use an
explicit broker root. Same-origin git worktrees normally resolve to the same broker.
A durable transition records the exact prior and next ownership before publishing
the binding or registry. Strict file and directory fsync barriers enforce
journal → binding → registry → journal removal ordering. A subsequent bind recovers interrupted publication using
only those exact owned rows (or absence); conflicting rows fail closed. Other host
operations reject a pending transition until bind reconciles it.

For rebind, pass the saved `binding.broker_root` as `--expected-broker-root`.
The resolved target and expected root are compared as canonical paths before
any registry mutation. A different target returns `workspace_broker_changed`,
preserving the prior binding, registration and queued mail. Same-origin worktree
moves are supported; cross-broker migration is unsupported in v1. Resume from
the prior workspace to accept its mail, or create a new logical thread for the
new repository. Do not force the old root with `--broker-root` to conceal a
workspace mismatch. Fresh binds omit the expected-root precondition.

Peek returns `{schema_version:1,binding:...,dnd:boolean,dnd_until:number|null,messages:[...],has_more:boolean}`.
`--limit` defaults to 64 and accepts 1..64. The serialized `messages` array is also
bounded to 4 MiB (including JSON escaping, commas and brackets); `has_more` reports
rows not included in that page. `dnd_until` is the active registration's timed DND
deadline in Unix seconds, or null for off, expired, or indefinite DND. T3 schedules
one deadline reconciliation because time expiry generates no registry file event;
explicit DND changes still use the registry watch. Consumers durably accept then ack a page before
peeking again; no cursor or destructive read is needed.

Each message contains `message_id,from_alias,to_alias,content,ts,ephemeral,deferrable,source`.
`ts` is numeric Unix seconds. The v1 message array is a union:

- Full message: `content:string`, at most 65536 UTF-8 bytes.
- Omitted message: the same envelope, `content:null`,
  `content_omitted_reason:"oversized"`, and `content_bytes` giving the original
  UTF-8 byte count. Never truncate the body. Even a giant body produces a small
  metadata record so following normal messages can make progress. T3 durably
  stores this receipt as unsupported/held before selected ack; omitted content
  is never injected into a provider. c2c retains full body archival semantics.

Source is `local`, `remote`, or `unknown`, established at broker write and preserved
through all read/rewrite/relay paths, not inferred from body, alias punctuation or
message-ID presence. Legacy rows are unknown and cannot trigger automatic wake.
Assign missing legacy IDs under the inbox lock before returning them.

Ack returns `{schema_version:1,binding:...,acknowledged:[...]}` and removes only selected rows under the existing
inbox lock. Duplicate ack is safe. Preserve concurrent arrivals and unmatched rows;
reuse broker archive semantics, including ephemeral exclusion. T3 must durably
accept content before ack. Do not introduce a parallel broker implementation.

Outbound uses `c2c host send` with the same identity/root/generation fence. The
recipient and literal body are the only message fields supplied by the caller;
the stored binding supplies the sender. Validate ownership and enqueue under the
same registry lock, reusing the broker's unlocked send core. Body interpretation
must not touch approvals. Host send bodies are at most65536 UTF-8 bytes. Success
returns `{schema_version:1,binding:...,queued:true}`; errors contain only bounded
categories. The caller's T3 identity, not an untrusted request alias, selects this
binding. Raw `c2c send` is not a fenced host transport.

## T3 domain implementation

Use Effect services and SQLite, following existing server conventions. Store bindings
and accepted messages in a migration after 62. Uniqueness is `(thread_id,message_id)`;
store source broker with the record. Bounded states distinguish accepted, delivery
in progress, delivered, held/uncertain, and unsupported. Failure logs contain only
bounded categories, not bodies/credentials. An injection in progress after a process
crash is held pending reconciliation; never blindly repeat ambiguous side effects.

The bridge owns typed subprocess calls to the c2c transport, event-driven fs watches,
bounded batching and retries. Subscribe before reconciliation; use scoped fibers and
existing server activation. SQL tests use real local test DBs, process tests fake only
the external process boundary. No live T3 database, runtime or auth file mutations.

Opt-in is explicit. A server configuration flag enables host-managed c2c mode;
disabled mode preserves the current native-provider setup. In enabled mode every
T3-owned provider process is uniformly stripped of inherited c2c identity variables,
gets `C2C_NO_AUTO_REGISTER=1`, `C2C_MCP_AUTO_DRAIN_CHANNEL=0`, and
`C2C_MCP_DISABLED=1`. The last flag keeps native MCP protocol-valid (initialize/ping)
but advertises no tools, refuses direct tools/call, and skips bootstrap, replay,
room joins, schedulers and channel delivery. It applies to any inherited c2c MCP
server name/configuration; CLI host operations remain enabled. Per-thread bindings and mute/disable are then T3-owned. Enabling
mode requires normal server/provider restart; do not rewrite active process state.

Expose configure/status/send through caller-bound T3 tools or a small existing CLI
surface. No new web/mobile UI is required for the first slice. A disabled/unsupported
status is truthful and actionable. Shutdown/disable releases owned watches; pending
mail remains durable. Worktree/resume remaps provider identity but not logical alias.

## Provider and scheduler

Add an explicit peer-DATA discriminator and optional injection capability at the
existing provider interface. Codex uses T3's app-server client, developer-role DATA
envelopes, and no `turn/steer`. The body is escaped and cannot select a goal command,
tool, approval response, role or recipient. Only the host constructs provenance.

Active-turn mail can be injected without scheduling another turn. Idle eligible
mail goes through T3's event/outbox/run machinery, and the Codex start path injects
DATA then starts an empty-input continuation with normal runtime policy. Preserve
the DATA after compaction without converting it to user-role `additionalContext`.

Validate under the thread serialization both at acceptance-for-dispatch and effect
execution: exact current binding/generation, enabled provider, no archive/delete,
no DND/mute/snooze, no approval/input wait and no explicit stop hold. Stop records an
explicit durable mailbox pause/epoch; only operator resume/configure clears it.
Generic message dispatch currently clears snooze/settled state: peer delivery must
not use those effects. Remote/unknown source can be accepted and exposed passively,
but only verified local, non-deferrable mail may start a turn. Existing user work and
drafts are never interrupted. Idempotency covers dispatcher receipts; do not claim
exactly-once provider visibility when the acknowledgment is ambiguous.

## Lanes and validation

- c2c lane: broker message source/ID preservation and `host` commands/tests/docs.
- T3 storage lane: new c2c services and migration only.
- T3 provider lane: provider interface/Codex DATA implementation and focused tests.
- T3 integration lane, after the preceding lanes merge: contracts, scheduler,
  lifecycle, activation, MCP/configuration and user docs. Shared files are serial.

Workers may not change another lane's files without coordination. All changes stay
in worktrees, use existing style, avoid broad refactors, and undergo independent
review/fix. The c2c backlog is the sole task tracker; no second T3 tracker is created.
Tests follow the repository's focused gates; buildbox execution is coordinated so
test syncs cannot overwrite another lane. Live tests use an isolated T3 home/server
and captured PIDs, never the installed T3 session. Final proof includes active and
idle DATA, same-workspace isolation, stop/snooze/approval holds, restart ambiguity,
flags, malformed bodies, disabled mode and unsupported-provider behavior.
