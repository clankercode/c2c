# Outbox + Retry Surface Audit

**Date**: 2026-04-29
**Author**: cairn (subagent of coordinator1)
**Scope**: c2c relay outbox lifecycle — TTL, retries, dead-letter, capacity bounds, restart durability.
**Method**: read-only static audit of OCaml relay + connector.

---

## TL;DR — Top Severity Gaps

| # | Gap | Severity | One-liner |
|---|-----|----------|-----------|
| 1 | **No TTL on local outbox entries** | **HIGH** | A message to a permanently-gone alias retries forever every interval; never dead-letters locally. |
| 2 | **No max-retry counter** | **HIGH** | `outbox_entry` has no `attempts` field; transient and permanent errors are indistinguishable. |
| 3 | **No capacity bound on `remote-outbox.jsonl`** | **MEDIUM** | Append-only file, unbounded; a stuck recipient + chatty sender = unbounded disk growth. |
| 4 | **Server-side dead_letter is in-memory `Queue`** | **HIGH** | `InMemoryRelay.dead_letter : Yojson.Safe.t Queue.t` — relay restart drops every dead letter (forensics lost). |
| 5 | **Whole-file rewrite on every sync** | **MEDIUM** | `write_outbox` rewrites the entire jsonl after each sync; concurrent `append_outbox_entry` from MCP can be clobbered (TOCTOU). |
| 6 | **Connection-error == unknown-alias from connector's POV** | **HIGH** | Both come back as `ok:false`; connector retries unknown_alias forever instead of dead-lettering. |

**Top severity finding**: **Gap #1 + Gap #6 combined** — a typo in
`to_alias` (e.g. `coordinator-1` vs `coordinator1`) produces an
outbox entry that retries every `interval` seconds **forever**, with
no local visibility, no escalation, and no eventual purge. The relay
*does* dead-letter it server-side on each attempt (Gap #4 — and only
in RAM), but that's a write-only sink the sender never sees.

---

## Architecture (lifecycle)

### Enqueue path

```
mcp__c2c__send → c2c_mcp.handle_send
  → if to_alias contains '@'   (cross-host)
    → C2c_relay_connector.append_outbox_entry broker_root ~from ~to ~content
      → opens broker_root/remote-outbox.jsonl with O_APPEND
      → writes single JSON line: {from_alias, to_alias, content, [message_id]}
```

`append_outbox_entry` is **append-only** (`open_out_gen
[Open_text; Open_append; Open_creat]`), at
`ocaml/c2c_relay_connector.ml:319-334`.

### Sync path (drain)

`C2c_relay_connector.sync` (`relay_connector.ml:628-706`):

1. `read_outbox` — parses entire jsonl into a `outbox_entry list`.
2. For each entry: blocking `Relay_client.send` → relay's `POST /send`.
   - On `ok:true` → drop entry, increment `outbox_forwarded`.
   - On `ok:false` → entry kept in `remaining`, `outbox_failed +=1`.
3. `write_outbox t.broker_root (List.rev remaining_outbox)` —
   **rewrites the entire file** with the surviving entries.
   If empty: removes file via `Sys.remove`.

Loop is driven by `run`: blocking `Unix.sleepf t.interval; loop ()` —
default `interval` is set in `c2c sync-relay` CLI; typical = 30s.

### Dead-letter (server side)

The relay (`InMemoryRelay.send`, `relay.ml:874-909`) writes a
dead-letter record on:
- `unknown_alias` — recipient never registered;
- `recipient_dead` — recipient registered but lease expired.

```ocaml
dead_letter : Yojson.Safe.t Queue.t;     (* in-memory queue *)
```

`add_dead_letter`, `dead_letter` (read), and an admin endpoint
`/dead_letter` are exposed. **No capacity bound, no persistence to
disk** — `Queue.create ()` at `relay.ml:565`.

`SqliteRelay` has a `dead_letter` table in DDL (`relay.ml:238-246`);
need to confirm but quick scan of `SqliteRelay.send` in lines
1779-1800 shows it does NOT insert into the table for unknown_alias /
recipient_dead — schema present, write path missing. (Worth a deeper
follow-up; out of time-budget for this audit.)

---

## Detailed Findings

### TTL

- **Local outbox entry**: no `enqueued_at` / `expires_at`; just
  `{from_alias, to_alias, content, message_id?}` (`relay_connector.ml:265-270`).
- **Heartbeat lease**: 300s default (`ttl` arg on `register`). When
  recipient lease expires, relay returns `recipient_dead` and dead-
  letters server-side; sender's outbox entry retries indefinitely.
- **Server nonce TTLs**: register=600s, request=120s — these are
  signature replay windows, unrelated to message lifecycle.
- **Server message TTL**: messages in `inboxes` have a `ts` column
  but **no expiry sweep** — `gc` only prunes leases + orphan inboxes
  whose session has no live lease.

**Verdict**: zero TTL anywhere on the outbox / inbox message
*content* lifecycle.

### Retries

- **Cadence**: every `t.interval` seconds (CLI default ~30s).
- **Counter**: none. No `attempts` field on `outbox_entry`. Cannot
  back off, cannot escalate, cannot dead-letter locally on Nth fail.
- **Classification**: `json_bool_member ~key:"ok"` is the ONLY signal.
  Any falsy `ok` → keep retrying. Connector cannot distinguish:
    - HTTP 5xx (transient, should retry)
    - HTTP 4xx unknown_alias (permanent — should DLQ locally)
    - connection_error (transient)
  — they all funnel through the same `ok:false` path.
- **Backoff**: none. Linear retry at `interval`.

### Dead-letter on permanent unreachable

- **Local (sender broker)**: not implemented. Outbox entry stays
  forever unless an operator manually edits `remote-outbox.jsonl`.
- **Server (relay)**: writes `dead_letter` Queue entry on every
  attempt (so duplicates accumulate per retry × interval — a typo
  alias produces 1 DL entry per ~30s, ~2880/day).
- **Server visibility**: admin `/dead_letter` GET returns the queue;
  there is no auto-export-to-sender, no notification, no rate limit.

### Capacity bounds

| Surface | Bound? |
|---|---|
| `remote-outbox.jsonl` | **None.** Append-only, full rewrite on sync. |
| In-memory dead_letter queue | **None.** `Queue.create ()`. |
| `inboxes` (server) | **None.** Pruned only when lease expires, full message body kept until then. |
| `seen_ids` dedup window | `?dedup_window=10000` ctor arg (`relay.ml:427`) — bounded. |

The dedup window is the **only** bounded queue in the message path.
Everything else grows linearly with traffic.

### Restart durability

| Surface | Survives sender broker restart? | Survives relay restart? |
|---|---|---|
| `remote-outbox.jsonl` | **Yes** — file on disk. | n/a |
| Server `inboxes` (InMemoryRelay) | n/a | **No** — Hashtbl. |
| Server `inboxes` (SqliteRelay) | n/a | **Yes** — DDL present, `INSERT INTO inboxes` confirmed at line 1804. |
| Server `dead_letter` (InMemoryRelay) | n/a | **No.** |
| Server `dead_letter` (SqliteRelay) | n/a | **DDL only — no write path found in send().** Likely-broken; needs confirm. |
| `pseudo_registrations.json`, `mobile_bindings.json` | **Yes** — atomic tmp+rename (`relay_connector.ml:173-179, 238-244`). | n/a |

**Sender-side durability is the strong point** — the local outbox is
crash-safe append-only. **Server-side durability is the weak point**
when the relay is the InMemoryRelay variant; the Sqlite variant is
better but the dead_letter write path looks under-implemented.

### Concurrency / TOCTOU

`sync` does:
1. `read_outbox` (full read)
2. Forward each
3. `write_outbox remaining` (full rewrite — `open_out path` truncates)

Between (1) and (3), another process (`c2c_mcp` handling a new
`mcp__c2c__send`) can `append_outbox_entry`. The new entry is at the
tail of the file at write time; (3)'s `open_out` truncates and
rewrites only what step (1) saw. **The new entry is lost.** No file
locking (`fcntl.flock`) is taken. This is a real race when
relay-connector and broker run concurrently (the normal case).

Ironically, the registry path (`c2c_registry.py` historically — now
OCaml broker-root files) DO use atomic tmp+rename; the outbox does
not.

### Cross-host alias context (#379)

`split_alias_host`, `host_acceptable` (`relay.ml:407-421`) check
the host part of `alias@host`. Cross-host (relay routing to another
relay) is **not implemented** — handle_send dead-letters with reason
`cross_host_not_implemented` (per recent commits 4450cf56 / 492c052b).
That dead-letter happens at the local broker, not relay outbox. So
`alias@otherhost` does NOT enter `remote-outbox.jsonl`; only
`alias@<self_host>` (which collapses to local) does.

**Implication**: outbox is currently used for "self-host remote
alias" deliveries — i.e. messages crossing repos sharing one relay,
not messages crossing relays. The retry/TTL gaps still matter (the
recipient session can be down for hours), but the blast radius is
smaller than a generic federation outbox.

---

## Concrete Repro Scenarios

### S1. Permanent typo

```
c2c send coordinator-1@relay "msg"   # dash typo
# outbox: 1 entry written
# every interval: connector POSTs /send → ok:false unknown_alias
# server: 1 DL entry per attempt, in-memory, lost on restart
# local: entry stays in remote-outbox.jsonl until manual cleanup
```

Days later: the sender restarts → outbox entry re-read → still
retrying → relay accumulates DL bloat (RAM) until relay restart.

### S2. Recipient down for a week

Identical retry pattern, except eventually the recipient comes back
and successfully receives. **Acceptable** for the design intent
("persists by design while recipient is down"). This is what the
outbox is *for*.

### S3. Race — outbox eats new send

```
T=0   sync starts; reads 3 entries
T=0.1 mcp send appends entry #4 to outbox (open_append)
T=0.2 sync POSTs entries 1-3, all ok
T=0.3 sync write_outbox []  → truncates file → entry #4 GONE
```

User sees "ok queued" from MCP; message silently lost.

---

## Suggested Fixes (priority order)

1. **Add `attempts` + `enqueued_at`** to `outbox_entry`. Locally
   dead-letter (move to `remote-outbox-dead.jsonl`) after N retries
   OR after T hours. Surface in `c2c doctor`.
2. **Distinguish error classes** in `Relay_client.send` response —
   propagate `error_code` (unknown_alias / connection_error) so the
   connector can DLQ permanent errors immediately.
3. **flock the outbox file** during `read_outbox + write_outbox` to
   close the truncate-loses-append race.
4. **Persist server dead_letter** — wire `SqliteRelay.send` to
   `INSERT INTO dead_letter` (DDL exists at line 238). InMemoryRelay
   stays as-is (test fixture).
5. **Bound the in-memory DL Queue** — drop oldest beyond N, or
   coalesce by `(from, to, reason)` so a typo doesn't spam.
6. **Surface outbox depth** — add `c2c doctor outbox` showing entry
   count + oldest age + per-target counts. Today there is no
   visibility unless an operator `cat`s the jsonl.

---

## File map (load-bearing paths)

- `/home/xertrov/src/c2c/ocaml/c2c_relay_connector.ml` — outbox read/write/append/sync
- `/home/xertrov/src/c2c/ocaml/relay.ml` — server send → dead_letter Queue (InMemoryRelay) + SqliteRelay
- `/home/xertrov/src/c2c/ocaml/c2c_mcp.ml:1882-1897` — enqueue path from MCP send
- `/home/xertrov/src/c2c/ocaml/cli/c2c.ml:6206,6265` — only doctor surfacing of "remote_outbox" (string match in dead-letter listing, not the outbox itself)

---

*Status*: read-only audit complete. No code changes proposed in this
artifact — fixes belong in slice tickets. Coord1: Gap #1+#6 is the
candidate for the next slice; Gap #3 (race) is a latent silent-data-
loss bug worth a dedicated ticket.
