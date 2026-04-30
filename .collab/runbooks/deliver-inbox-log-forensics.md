# deliver-inbox.log Forensics Runbook

> How to use the structured daemon audit log introduced in #562 to trace
> deliver-inbox events when investigating delivery failures, PTY races,
> or session delivery anomalies.

## TL;DR

```
<broker_root>/deliver-inbox.log   ← daemon audit (this slice)
<broker_root>/broker.log          ← broker audit
<broker_root>/<session_id>.inbox  ← live inbox (drained messages)
<broker_root>/<session_id>.archive ← message history
```

Cross-correlate via: `ts`, `session_id`, and `drained_by_pid` (daemon PID from `start_daemon`).

---

## Log location

```
<broker_root>/deliver-inbox.log
```

Broker root resolution (`C2c_repo_fp.resolve_broker_root`):
```
C2C_MCP_BROKER_ROOT env var    (explicit override)
→ $XDG_STATE_HOME/c2c/repos/<fp>/broker  (if set)
→ $HOME/.c2c/repos/<fp>/broker            (canonical default)
```

Fingerprint `<fp>` is SHA-256 of `remote.origin.url` (12 hex chars), or `"default"`.

---

## Format

JSONL — one JSON object per line. Parse with:

```bash
# Pretty-print all events
jq . <broker_root>/deliver-inbox.log

# Filter by event type
jq -c 'select(.event=="deliver_inbox_drain")' <broker_root>/deliver-inbox.log

# Filter by session_id
jq -c 'select(.session_id=="abc123")' <broker_root>/deliver-inbox.log

# Time window (Unix epoch)
jq -c 'select(.ts > 1748500000 and .ts < 1748503600)' <broker_root>/deliver-inbox.log
```

**Permissions**: 0o600 (same as `broker.log` — contains session message content).

**Emitters are best-effort**: write failures are silently swallowed. If the log is missing, an inferred event may not be recorded.

---

## Event catalog

### `deliver_inbox_drain`

Emitted after `poll_once_generic` drains messages from a non-kimi inbox. Written in the daemon loop and in single-shot mode.

| Field | Type | Description |
|-------|------|-------------|
| `ts` | float | Unix epoch, sub-second |
| `event` | string | Always `"deliver_inbox_drain"` |
| `session_id` | string | Target session whose inbox was drained |
| `client` | string | Client type: `"claude"`, `"codex"`, `"opencode"`, `"kimi"`, etc. |
| `count` | int | Number of messages drained |
| `drained_by` | string | Always `"deliver-inbox"` (daemon convention) |
| `drained_by_pid` | int | PID of the deliver-inbox daemon process. `0` = single-shot invocation (no daemon). Use to distinguish daemon-loop drains from one-off CLI drains. |

### `deliver_inbox_kimi`

Emitted after `poll_once_kimi` completes for kimi sessions.

| Field | Type | Description |
|-------|------|-------------|
| `ts` | float | Unix epoch, sub-second |
| `event` | string | Always `"deliver_inbox_kimi"` |
| `session_id` | string | kimi session ID (also used as alias) |
| `alias` | string | Same as session_id for kimi managed sessions |
| `count` | int | Number of notifications written to kimi's store |
| `ok` | bool | `true` = kimi notifier succeeded. `false` = error. (count may still be 0 if no new mail.) |

### `deliver_inbox_no_session`

Reserved for future use — emitted when `poll_once_generic` is called for an unknown session_id.

| Field | Type | Description |
|-------|------|-------------|
| `ts` | float | Unix epoch, sub-second |
| `event` | string | Always `"deliver_inbox_no_session"` |
| `session_id` | string | The unknown session_id that was requested |
| `error` | string | Error description |

---

## Cross-correlating with broker.log

`broker.log` records inbox drain events via `dm_enqueue` (when the broker enqueues an inbound DM for a session):

```json
{"ts":1748501234.567,"event":"dm_enqueue","from_alias":"alice","to_alias":"bob","msg_ts":1748501234.001}
```

To correlate with `deliver_inbox_drain`:

1. **Match on `ts`**: `dm_enqueue` fires when the broker enqueues; `deliver_inbox_drain` fires when the daemon drains. The daemon should drain within one poll interval (default 1s for daemon loop).

2. **Match on `session_id`**: both logs contain the target session.

3. **Match on `drained_by_pid`**: if the daemon is running, `drained_by_pid` is the daemon's PID. `dm_enqueue` does not carry PID — use the timestamp window to narrow.

**Daemon PID discovery** (when investigating):
```bash
# PID of running daemon for a given session
cat <session_state_dir>/<session_id>.pid

# Or from the daemon's pidfile (set via --pidfile flag)
# Default pidfile: .c2c-deliver-state/<session_id>.pid in the working directory
```

---

## Worked example: tracing a missing DM

Scenario: agent `bob` did not receive a DM from `alice` sent at ~`1748501234`.

1. **Find the enqueue** in `broker.log`:
   ```bash
   jq -c 'select(.event=="dm_enqueue" and .to_alias=="bob" and .ts > 1748501200 and .ts < 1748501300)' <broker_root>/broker.log
   ```
   → `{"ts":1748501234.567,"event":"dm_enqueue","from_alias":"alice","to_alias":"bob","resolved_session_id":"bob-session-id","inbox_path":"/.../bob.inbox.json"}`
   Note: `dm_enqueue` uses `ts` (enqueue wall-clock time), NOT `msg_ts`. The `ts` field is also present in `deliver_inbox_drain`, so both sides of the correlation use the same clock field.

2. **Check if daemon drained** in `deliver-inbox.log`:
   ```bash
   jq -c 'select(.event=="deliver_inbox_drain" and .session_id=="<bob-session-id>" and .ts > 1748501234 and .ts < 1748501240)' <broker_root>/deliver-inbox.log
   ```
   - **Found**: daemon drained `count=N`. Check `ts` — did it drain after the `ts` in `dm_enqueue`?
     - If yes: daemon picked it up. Was PTY injection attempted? Check `c2c_start.ml` PTY path and `c2c_wire_bridge.ml`.
     - If no drain event after `msg_ts`: daemon missed it. Was the daemon alive? Check if `drained_by_pid=0` (single-shot) or daemon was dead.
   - **Not found**: daemon never saw it. Was bob's session registered? Check `broker.log` for `session_register` events around that time.

3. **Check kimi path** if bob is a kimi session:
   ```bash
   jq -c 'select(.event=="deliver_inbox_kimi" and .session_id=="<bob-session-id>" and .ts > 1748501234 and .ts < 1748501240)' <broker_root>/deliver-inbox.log
   ```
   Look at `ok` field — if `false`, kimi notifier errored.

---

## Rotation

No automatic rotation is implemented. `#61` covers rotation design. For now, the log grows indefinitely — monitor file size in production.

To manually rotate:
```bash
cp <broker_root>/deliver-inbox.log <broker_root>/deliver-inbox.log.$(date +%Y%m%d-%H%M%S)
> <broker_root>/deliver-inbox.log
chmod 600 <broker_root>/deliver-inbox.log
```
(Do not truncate with `echo` — that races with open file handles.)

---

## Relationship to #488 forensic dive

The #562 daemon log was introduced because the #488 investigation had no daemon-side forensic trail when PTY misdelivery was suspected. The broker was innocent (`broker.log` showed no anomaly), but the daemon's PTY injection attempt left no trace.

With `deliver_inbox_drain` now in place, the next #488-style incident records:
- `drained_by_pid` = daemon PID at time of drain
- `count` = messages drained (non-zero means daemon saw mail)
- `client` = which client type the daemon was targeting

Combined with `broker.log`'s `dm_enqueue`, an investigator can now reconstruct the full path: broker enqueued → daemon drained → PTY injection attempted (or not) → delivered (or dead-lettered).
