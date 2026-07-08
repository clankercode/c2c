---
layout: page
title: monitor --json Event Schema
permalink: /monitor-json-schema/
---

# `c2c monitor --json` Event Schema

`c2c monitor --json` emits newline-delimited JSON (NDJSON) — one JSON object per line — suitable for piping into a GUI, log aggregator, or structured logger.

## Usage

```bash
c2c monitor --json                         # default: your alias, archive, full body, relay-aware
c2c monitor --all --json                   # all swarm traffic, NDJSON
c2c monitor --all --json --drains --sweeps # include drain + sweep events
c2c monitor --json --from coder1           # only messages from coder1
c2c monitor --json --include-self          # include your own echo/broadcast traffic
c2c monitor --json --drain                 # make monitor the live-inbox consumer
c2c monitor --json --no-relay              # local broker only
c2c monitor --json --relay-node-id machine-42
c2c monitor --json --relay-node-id host-1 --relay-session-id <sid>
```

Defaults: `--archive` and `--full-body` are now implicit. Use `--live` for the legacy live-inbox-only path, and `--snippet` for the legacy 80-character preview.

`--drain` and `--drains` are different flags: `--drain` makes the monitor consume the live inbox, while `--drains` only shows drain events when an inbox touch/delete path yields no new messages.

---

## Event Types

All events share an `event_type` discriminant field and a `monitor_ts` Unix timestamp (float seconds, 3dp).

### `monitor.ready`

Emitted once at startup in `--json` mode after the monitor has established its watch set (or after the startup wait times out). Consumers can wait for this event instead of sleeping before producing test traffic.

```json
{
  "event_type": "monitor.ready",
  "monitor_ts": "1745241234.500",
  "alias": "coordinator1",
  "session_id": "01HXEXAMPLESESSION",
  "alias_source": "session 01HXEXAMPLESESSION registration",
  "inbox_watch": true,
  "relay_watch": "peek cli-coordinator1/cli-coordinator1 every 5.0s"
}
```

Fields:

- `alias`: resolved local alias, or `null` if monitor could not resolve one.
- `session_id`: resolved local session id, or `null` if none was found.
- `alias_source`: human-readable source used to resolve `alias`. Current labels include `--alias flag`, `C2C_MCP_AUTO_REGISTER_ALIAS`, `session <sid> registration`, `default-alias file (fallback — may be another agent's)`, `C2C_MCP_SESSION_ID (fallback)`, `single alive registration (fallback)`, and `unresolved`.
- `inbox_watch`: `true` when the default archive-mode monitor also watches this session's live inbox. That live-inbox watch lets a bare CLI session see incoming messages by peeking unless `--drain` is set.
- `relay_watch`: human-readable relay watcher status, such as `peek <node_id>/<session_id> every 5.0s`, `peek <node_id>/<session_id> every 5.0s (unsigned)`, `off (--no-relay / --relay-interval 0)`, `off (--live mode: relay watcher requires the default archive mode for dedup)`, or `off (no relay URL configured (c2c relay setup / C2C_RELAY_URL))`.

### `message`

A new message was written to a broker inbox/live-inbox watch, appended to the archive, or peeked from the relay inbox.

```json
{
  "event_type":   "message",
  "monitor_ts":   "1745241234.567",
  "source":       "local",
  "from_alias":   "coder1",
  "to_alias":     "coordinator1",
  "content":      "build green, ready to merge",
  "ts":           "2026-04-21T14:02:00Z"
}
```

Relay-sourced messages use the same shape with `source: "relay"`:

```json
{
  "event_type":   "message",
  "monitor_ts":   "1745241239.012",
  "source":       "relay",
  "from_alias":   "remote-coder",
  "to_alias":     "coordinator1",
  "content":      "cross-host DM surfaced by relay peek",
  "ts":           "2026-07-08T09:12:00Z"
}
```

Room messages carry additional fields:

```json
{
  "event_type":   "message",
  "monitor_ts":   "1745241234.567",
  "source":       "local",
  "from_alias":   "coder1",
  "to_alias":     "swarm-lounge",
  "content":      "joining the room",
  "ts":           "2026-04-21T14:02:00Z",
  "room_id":      "swarm-lounge",
  "event":        "room_message"
}
```

`source` is `local` for local broker/archive/live-inbox events and `relay` for cross-host messages surfaced by the relay-inbox watcher. In human output, relay-sourced messages are marked with `🌐`. Caveat: the legacy `--live --json` inline path may omit `source`; the default archive-mode path and relay watcher include it.

### `drain`

An inbox was touched and no new messages were emitted. Emitted only when `--drains` is set.

```json
{
  "event_type": "drain",
  "alias":      "coordinator1",
  "monitor_ts": "1745241240.123"
}
```

### `sweep`

An inbox file was deleted (sweep or manual removal). Emitted only when `--sweeps` is set.

```json
{
  "event_type": "sweep",
  "alias":      "old-agent-xyz",
  "monitor_ts": "1745241300.000"
}
```

---

### `peer.alive`

A new alias appeared in `registry.json` (new registration). Emitted in live mode only (not in `--archive` mode).

```json
{
  "event_type": "peer.alive",
  "alias":      "coder2-expert",
  "monitor_ts": "1745241290.001"
}
```

### `peer.dead`

An alias was removed from `registry.json` (deregistration or sweep). Emitted in live mode only.

```json
{
  "event_type": "peer.dead",
  "alias":      "old-agent-xyz",
  "monitor_ts": "1745241300.500"
}
```

### `room.join`

An alias was added to a room's `members.json`. Emitted in live mode only.

```json
{
  "event_type": "room.join",
  "room_id":    "swarm-lounge",
  "alias":      "coder1",
  "monitor_ts": "1745241305.001"
}
```

### `room.leave`

An alias was removed from a room's `members.json`. Emitted in live mode only.

```json
{
  "event_type": "room.leave",
  "room_id":    "swarm-lounge",
  "alias":      "old-agent-xyz",
  "monitor_ts": "1745241320.500"
}
```

### `room.invite`

An alias was added to a room's `meta.json` `invited_members` list (#433). Emitted in live mode only. The broker also auto-DMs the invitee with a `<c2c event="room-invite" ...>` envelope so the invitee learns about the invite even when they are not running a monitor.

```json
{
  "event_type": "room.invite",
  "room_id":    "swarm-lounge",
  "alias":      "newbie-agent",
  "monitor_ts": "1745241340.700"
}
```

---

## Relay-inbox watcher (B089)

In the default archive mode, `c2c monitor` also peeks the resolved alias's relay inbox when a relay URL is configured through `C2C_RELAY_URL` or `c2c relay setup`. Relay peeks are non-draining: the monitor calls the relay peek path and does not consume messages, so a connector or `c2c relay dm poll` can still receive every message.

Relay-sourced events are visible as:

- `"source": "relay"` on `message` JSON events.
- `🌐` on human-readable monitor lines.
- `relay_watch` status on the startup `monitor.ready` JSON event.

Relay controls:

- `--no-relay`: disable the relay-inbox watcher; local broker only.
- `--relay-interval SECONDS`: interval between relay peeks; default `5.0`. `0` disables the relay watcher, equivalent to `--no-relay`.
- `--relay-node-id ID`: relay node id whose inbox should be peeked. Default is `cli-<alias>`, matching `c2c relay register --alias <alias>`. `C2C_RELAY_NODE_ID` is the environment override.
- `--relay-session-id ID`: relay session id whose inbox should be peeked. Default is the relay node id. `C2C_RELAY_SESSION_ID` is the environment override. Connector-managed aliases commonly need both `--relay-node-id` and `--relay-session-id`.

The relay watcher is gated to the default archive mode for deduplication. Under `--live`, `monitor.ready.relay_watch` reports it off.

---

## Notes

- `monitor_ts` is the wall-clock time the monitor process observed the event, not the message send time (`ts`). Use `ts` for message ordering; use `monitor_ts` for latency measurement.
- In archive mode (`--archive`, now the default), `event_type: "message"` events are read from the append-only `archive/*.jsonl` files. This avoids racing with a PostToolUse hook that drains the live inbox. When a session inbox is resolved, archive mode also watches that session's live inbox and peeks it by default so messages can surface even before another consumer drains them to the archive.
- Drain and sweep events can be emitted in either live mode or archive mode when a watched live inbox is touched or deleted. In a pure archive-only run with no resolved session inbox, there is no live inbox watch, so drain/sweep events will not fire.
- All output is flushed immediately (`%!` / `print_newline`). Safe to consume line-by-line from a subprocess.
