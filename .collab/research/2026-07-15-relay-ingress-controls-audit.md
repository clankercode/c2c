# Relay and local ingress controls audit (B197)

Date: 2026-07-15

## Boundary and invariant

Relay responses and remote message rows are untrusted. Local-broker senders are
more attributable but their message bodies are still data, never authority.
No admission or trust setting may make message content satisfy an approval,
write a verdict, or trigger an action outside the narrow local Codex auto-turn
gate documented by B098/T007. This is the `bus, never RPC` invariant.

The relay inbound policy is intentionally local. Alias admission, row-size, and
rate decisions are not disclosed to or delegated to the relay.

## Shipped control map

| Scope | Control | Status |
| --- | --- | --- |
| Message | Required string envelope fields; serialized-row size cap | B196 |
| Sender/user | Per-sender size and sliding-window rate | B196 |
| Sender/user | Default allow/deny plus per-sender admission override | B197 |
| Agent/recipient | Bind row to polled alias; disable relay ingress; per-agent row-size and aggregate rate | B197 |
| Machine | Aggregate sliding-window rate across local sessions | B196 |
| State | Process lock, atomic persisted windows, fail-closed invalid config/state | B196/B197 |
| Audit | Rejection count and reason in connector state/error, no body logging | B196/B197 |

Precedence is deliberately simple: schema, binding to the polled local alias,
sender admission, recipient enable, the stricter sender/recipient size, sender
rate, recipient rate, then machine rate. Only accepted rows consume a rate slot.
Aliases are case-insensitive.

## Remaining controls, in priority order

### 1. Bounded transport and loss-safe batch polling

The connector currently buffers and parses the complete HTTP response before
row controls run. Adding only a client body cap would bound memory, but `/poll_inbox`
currently drains the remote queue before the client validates the response; an
oversized response would therefore lose the whole batch. The coherent change is
a bounded poll protocol: server-side message/byte limit, stable cursor or batch
identifier, and explicit acknowledgement after local persistence. The connector
can then enforce a streaming response cap without converting overload into loss.

Acceptance criteria for that slice:

- a configured/default maximum applies before an unbounded allocation;
- the relay returns no more than both a row count and serialized byte budget;
- unacknowledged rows remain available, with idempotent message IDs;
- malformed/oversize batches fail closed without draining sibling rows;
- tests cover missing/false `Content-Length`, chunked bodies, retries, and crash
  between local append and acknowledgement.

### 2. Queue and disk backpressure

Rates limit delivery velocity but not storage accumulated while an agent is
offline. Add per-recipient and per-machine queued-byte/row ceilings at the relay,
plus local inbox/archive byte ceilings. Overflow must have an explicit policy
(reject sender, expire oldest, or quarantine) and observable counters. Do not
silently truncate a JSONL file or let one recipient exhaust the host filesystem.

### 3. Cryptographic trust tiers

B197 admission keys are aliases. Relay request authentication prevents casual
alias impersonation at the service boundary, but local policy cannot yet express
"this pinned machine key", "this user identity", or "any agent on this host".
Introduce stable cryptographic principals and groups before calling a setting a
trust tier. Alias patterns alone are convenience filters, not identity proof.
Pin rotation needs a local audit event and fail-closed mismatch behavior.

### 4. Durable observability without attacker amplification

Persist monotonic counters by reason and scope, plus last-rejection timestamps,
without storing bodies or unbounded sender-cardinality labels. Rate-limit alerts
and coalesce repeated events. Operators need to distinguish sender denial,
recipient disable, each rate ceiling, malformed rows, and transport rejection.

### 5. Local-source resource ceilings

Local mail must retain its distinct trust label and the B098/T007 auto-turn gate,
but it also needs independent message-size, queue-byte, queue-row, and wake-rate
ceilings. Do not reuse relay sender admission implicitly: an operator may trust a
local peer's identity while still bounding its resources, and remote aliases must
never acquire local-source privileges through policy text.

### 6. Policy/state file hardening

Cap policy and rate-state file sizes before parsing, cap configured override
cardinality, fsync the state temp file and parent directory where durability is
required, and expose a policy validation/inspection command. These files are
local-operator surfaces, but corruption must remain bounded and diagnosable.
