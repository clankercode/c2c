# Broker.log coverage audit

- Auditor: cairn (observability auditor)
- Date: 2026-04-29
- Scope: emission coverage of `<broker_root>/broker.log` and the
  sibling stream `c2c monitor --json`, vs documented schemas.
- Read-only audit.

## TL;DR

Two distinct event streams; both have gaps.

1. **`c2c monitor --json` (NDJSON, derived from filesystem watches)**
   docs: `docs/monitor-json-schema.md`. **One documented gap**:
   `room.invite` listed under "Planned Event Types" but no emit
   site exists. (`send_room_invite` mutates `meta.invited_members`
   but no inotify path watches room metadata files; only
   `members.json` triggers `room.join`/`room.leave`.) This is the
   gap the room-invite audit already flagged.

2. **`broker.log` (audit JSONL, written by MCP broker)**
   docs: `docs/commands.md` + `tail_log` tool description in
   `c2c_mcp.ml:3725` + `cli-house-style.md` Pattern 8.
   **No formal schema page exists** — the tool description is the
   de-facto contract. 5 event tags + `tool` RPC entries are
   documented; emission is **complete** for everything called out
   but several lifecycle/safety events that belong on this stream
   are silently absent.

Total documented entry shapes: **6** (1 RPC + 5 events).
Total observed emit sites: **6** (clean).
**Top 5 unaddressed gaps below** are events that *should* be on
broker.log but currently aren't (no schema entry, no emitter).

---

## Schema event inventory

### `c2c monitor --json` (filesystem-watch stream)

Source of truth: `docs/monitor-json-schema.md`. Emission lives in
`ocaml/cli/c2c.ml` around lines 3000–3220.

| event_type        | Status              | Emit site                         |
|-------------------|---------------------|-----------------------------------|
| `monitor.ready`   | EMITTED-CLEAN       | `c2c.ml:3003`                     |
| `message`         | EMITTED-CLEAN       | `c2c.ml:3054, 3129`               |
| `drain`           | EMITTED-CLEAN       | `c2c.ml:3113` (gated `--drains`)  |
| `sweep`           | EMITTED-CLEAN       | `c2c.ml:3081` (gated `--sweeps`)  |
| `peer.alive`      | EMITTED-CLEAN       | `c2c.ml:3150`                     |
| `peer.dead`       | EMITTED-CLEAN       | `c2c.ml:3163`                     |
| `room.join`       | EMITTED-CLEAN       | `c2c.ml:3193`                     |
| `room.leave`      | EMITTED-CLEAN       | `c2c.ml:3206`                     |
| `room.invite`     | **MISSING (planned)** | none — schema declares it under "Planned Event Types" with no emitter |

Note: `monitor.ready` is emitted by the JSON path but not
documented in the schema page. Minor doc-drift.

### `broker.log` (audit JSONL)

Source of truth: `c2c_mcp.ml:3725` (`tail_log` tool description).
Discriminator: exactly one of `tool` (RPC) or `event` (lifecycle).

| Discriminator                       | Status        | Emit site                           |
|-------------------------------------|---------------|-------------------------------------|
| `tool: <name>` (every RPC)          | EMITTED-CLEAN | `c2c_mcp.ml:6226` (`log_rpc`), called once per dispatch at `c2c_mcp.ml:6387` |
| `event: send_memory_handoff`        | EMITTED-CLEAN | `c2c_mcp.ml:3399` → called at 3532, 3536 |
| `event: peer_pass_reject`           | EMITTED-CLEAN | `c2c_mcp.ml:3430` → called at 4827  |
| `event: peer_pass_pin_rotate`       | EMITTED-CLEAN | `c2c_mcp.ml:3463`; wired via `Peer_review.set_pin_rotate_logger` at 3496 |
| `event: nudge_enqueue`              | EMITTED-CLEAN | `relay_nudge.ml:100` → called at 171, 176 |
| `event: nudge_tick`                 | EMITTED-CLEAN | `relay_nudge.ml:125` → called at 225 |

All explicitly-documented broker.log shapes have at least one emit
site, and every emit site is total (try/with swallows IO failure
so audit failure can't break the RPC path). The stream is clean
**for what it covers**.

### Adjacent streams (NOT broker.log)

For audit completeness — these emit `event:` JSONL but to other
files, not `broker.log`:

- `dead-letter.jsonl` (`c2c_mcp.ml:2128`) — receipt-impossible DM
  records. Discrete shape, no overlap with broker.log.
- `statefile-debug.jsonl` (`c2c.ml:8901`, `c2c_inbox_hook.ml:131`) —
  `state.snapshot` / `named.checkpoint`. Per-instance harness debug.
- relay HTTP structured log (`relay_ratelimit.ml:94`) — uses `Logs`
  rather than broker.log; pair/handshake events.

---

## Top 5 gaps

### 1. `room.invite` — schema declares, no emitter (HIGH)

**Schema:** `docs/monitor-json-schema.md` "Planned Event Types".
**Reality:** `Broker.send_room_invite` (`c2c_mcp.ml:2853`) mutates
`meta.invited_members` in the room-meta JSON file. The monitor
filesystem watcher only inspects `*.inbox.json`, `registry.json`,
and `members.json` — room metadata changes are invisible.
**Severity:** HIGH — documented surface that doesn't exist;
operator-facing tooling assumes it works.
**Slice estimate:** S/M. Either (a) add a `meta.json` branch to
the live-mode watcher in `c2c.ml:3140-3217` paralleling the
`members.json` branch, or (b) drop the "Planned" entry until
implementation lands. (a) is the right fix; the meta-file already
exists and has a stable name.

### 2. Dead-letter writes — no broker.log breadcrumb (HIGH)

**Schema:** none. **Reality:** when a cross-host send is rejected
(`relay.ml:3185` `cross_host_not_implemented`) or a session has no
inbox, `Broker.append_dead_letter` writes to `dead-letter.jsonl`
but no parallel `event: dead_letter` lands on broker.log. Operators
running `c2c tail-log` to debug "where did my message go?" see no
trace. The recent #379 fix changed *behavior* (cross-host now
dead-letters) but didn't add a discoverability hook.
**Severity:** HIGH — directly contradicts the dogfooding rule that
"silent failures get logged so the next agent doesn't hit the same
pothole" (CLAUDE.md). `tail-log` is documented as the audit surface.
**Slice estimate:** S. Add `log_dead_letter ~broker_root ~from_alias
~to_alias ~reason` next to the existing emitters in `c2c_mcp.ml`,
call from `Broker.append_dead_letter` (or its callers — broker
already knows the reason).

### 3. Registration / deregistration / sweep — no broker.log lines (MEDIUM)

**Schema:** none. **Reality:** `Broker.register` (`c2c_mcp.ml:1519`),
implicit deregistration via `Broker.sweep` (2230), and explicit
unregister flows mutate `registry.json` but log nothing to
broker.log. `peer.alive`/`peer.dead` show up on the **monitor**
stream but operators reviewing broker.log post-hoc cannot see who
joined/left or when sweep ran. The `tool: register`/`tool: sweep`
RPC entries cover the API call but not the *state change*
(register can be a no-op rebind; sweep emits one entry but says
nothing about which aliases were reaped).
**Severity:** MEDIUM — degrades post-mortem fidelity; "did coord1
deregister at 14:02 or 14:42?" is currently answerable only by
correlating monitor traces, which most agents don't keep.
**Slice estimate:** M. Add `event: register`, `event: deregister`,
`event: sweep` (with reaped-alias list) — three siblings of the
existing emitters. Mind log volume on busy swarms; consider
batching the sweep entry into one record per tick.

### 4. RPC error reasons elided from `tool` lines (MEDIUM)

**Schema:** `tool: <name>, ok: bool`. **Reality:** `log_rpc`
(`c2c_mcp.ml:6226`) deliberately omits content/reason fields to
avoid leaking message bodies. But for **non-content** failure
classes (invalid args, alias-not-registered, room-not-member), the
reason is safe to log and would massively speed up debugging. Today
a `tool: send, ok: false` line tells you *that* it failed but not
*why*.
**Severity:** MEDIUM — tail-log is advertised as a debugging
surface; current shape demands stderr correlation.
**Slice estimate:** S. Add an optional `error_class: <enum>` field
populated from a small, fixed taxonomy (no free-form strings, no
content). Match `dead_letter`'s `reason` field convention.

### 5. Room create / delete / visibility-change — no broker.log lines (LOW-MEDIUM)

**Schema:** none. **Reality:** `Broker.create_room`
(`c2c_mcp.ml:2888`), `Broker.delete_room` (2822), and
`set_room_visibility` (2865) mutate room state but emit nothing on
broker.log beyond the generic `tool: <name>` line. The monitor
stream catches join/leave but room *creation* and *visibility
transitions* are invisible. Combined with gap #1 (`room.invite`),
a third of the room lifecycle is unobservable.
**Severity:** LOW-MEDIUM — rooms are the social-layer substrate per
the group goal; observability there matters for the long arc.
**Slice estimate:** S. Three siblings of the existing emitters,
shape: `event: room.{create,delete,visibility}, room_id, by_alias,
[old_visibility,] new_visibility | members_at_delete`.

---

## Open questions

1. **Single-source schema page for broker.log.** Today the contract
   lives in three places (the `tail_log` tool description, the
   `docs/commands.md` paragraph, and `cli-house-style.md` Pattern 8).
   Consumer code has to grep. Worth promoting to
   `docs/broker-log-schema.md` paralleling `monitor-json-schema.md`?
   (Decision belongs to docs hygiene, not this audit, but the
   absence is what made gaps #2–#5 invisible.)

2. **Should monitor-stream `room.invite` and broker.log
   `room.invite` be the same event?** They serve different
   consumers (operator TUI vs forensic audit) but both want the
   same payload. Could share a render but probably need separate
   emitters because filesystem watcher and broker code paths don't
   meet.

3. **Volume budget for register/sweep events.** A 50-agent swarm
   with sweep cadence + restarts could push broker.log past
   `tail_log`'s 500-line cap for a single dense minute. Cap or
   rate-limit those classes, or accept the noise and lean harder on
   `tail_log`'s `limit` argument? Probably the latter — broker.log
   is append-only and `tail_log` already paginates.

4. **Does the relay-side log (`relay_ratelimit.ml`) belong on the
   audit list?** It's a different process and a different file but
   the conceptual purpose (post-hoc forensics on broker behavior)
   overlaps. Out of scope here; flag for a follow-up audit on
   relay-side observability.

---

## References

- Schema: `docs/monitor-json-schema.md`
- Tool description (de-facto broker.log schema):
  `ocaml/c2c_mcp.ml:3725`
- Monitor emit sites: `ocaml/cli/c2c.ml:2980-3220`
- Broker.log emit sites:
  - `ocaml/c2c_mcp.ml:3399, 3430, 3463, 6226`
  - `ocaml/relay_nudge.ml:100, 125`
- House style: `.collab/runbooks/cli-house-style.md` Pattern 8
- Related issues: #284 (room-invite, planned), #327
  (send_memory_handoff), #335 (broker.log discriminated union),
  #379 (cross-host dead-letter)
