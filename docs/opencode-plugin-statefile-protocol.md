# OpenCode Plugin Statefile Protocol

This document specifies the plugin-side protocol used by `.opencode/plugins/c2c.ts`
to stream live OpenCode session state into `c2c oc-plugin stream-write-statefile`.

The OpenCode plugin is responsible for observing the current session and emitting a
small, stable event stream. The `c2c` binary is responsible for maintaining the
canonical on-disk statefile.

## Scope

This protocol covers:

- the subprocess contract between the OpenCode plugin and `c2c`
- the JSONL event stream written to stdin
- the plugin-side canonical schema
- the merge semantics for patches
- which OpenCode events are consumed by the plugin in v1

This protocol does not define the OCaml statefile format on disk.

## Transport

- Command: `c2c oc-plugin stream-write-statefile`
- Direction: plugin writes to child stdin
- Encoding: UTF-8 JSON Lines
- One JSON object per line
- No shell wrapping

The plugin starts one long-lived subprocess and keeps stdin open for the lifetime
of the OpenCode process.

## Resync Semantics

The plugin emits two event types:

1. `state.snapshot`
2. `state.patch`

Rules:

- Every successful writer start must be followed by one full `state.snapshot`
  before any `state.patch`.
- `state.snapshot` is authoritative replacement state for that writer lifetime.
- `state.patch` events are only valid after a preceding `state.snapshot` from the
  same writer lifetime.
- If the writer dies or stdin breaks, the plugin makes no further guarantees until
  a fresh writer start emits a new `state.snapshot`.

v1 does not define sequence numbers or replay.

## Event Types

### `state.snapshot`

Full state replacement.

Example:

```json
{
  "event": "state.snapshot",
  "ts": "2026-04-21T14:05:00.123Z",
  "state": {
    "c2c_session_id": "opencode-c2c",
    "c2c_alias": "opencode-mire-kiva",
    "root_opencode_session_id": null,
    "opencode_pid": 12345,
    "plugin_started_at": "2026-04-21T14:00:00.000Z",
    "state_last_updated_at": "2026-04-21T14:05:00.123Z",
    "agent": {
      "is_idle": null,
      "turn_count": 0,
      "step_count": 0,
      "last_step": null,
      "provider_id": null,
      "model_id": null
    },
    "tui_focus": {
      "ty": "unknown",
      "details": null
    },
    "prompt": {
      "has_text": null
    }
  }
}
```

### `state.patch`

Partial state update.

Example:

```json
{
  "event": "state.patch",
  "ts": "2026-04-21T14:05:01.456Z",
  "patch": {
    "root_opencode_session_id": "ses_abc123",
    "agent": {
      "is_idle": true,
      "turn_count": 3,
      "step_count": 5,
      "last_step": {
        "event_type": "session.idle",
        "at": "2026-04-21T14:05:01.456Z",
        "details": {
          "session_id": "ses_abc123"
        }
      }
    },
    "tui_focus": {
      "ty": "prompt",
      "details": null
    },
    "prompt": {
      "has_text": false
    },
    "state_last_updated_at": "2026-04-21T14:05:01.456Z"
  }
}
```

## Patch Merge Semantics

Consumers must apply patches as a deep object merge:

- omitted fields mean unchanged
- object values merge recursively
- scalar values replace the previous value
- `null` means explicit clear-to-null
- arrays, if ever introduced, replace the previous array entirely unless a later
  protocol version says otherwise

v1 intentionally avoids arrays.

## Canonical Schema

### Top-level fields

- `c2c_session_id: string`
- `c2c_alias: string | null`
- `root_opencode_session_id: string | null`
- `opencode_pid: number`
- `plugin_started_at: string`
- `state_last_updated_at: string`

All timestamps are ISO 8601 UTC strings with millisecond precision.

### `agent`

- `is_idle: boolean | null`
- `turn_count: number`
- `step_count: number`
- `last_step: null | { event_type: string, at: string, details: object | null }`
- `provider_id: string | null`
- `model_id: string | null`

v1 counter meanings:

- `turn_count`: number of observed root `session.idle` completions
- `step_count`: number of handled state-relevant events from this set only:
  - root `session.created`
  - root `session.idle`
  - root `permission.asked`
  - root `permission.updated`

### `tui_focus`

- `ty: "permission" | "question" | "prompt" | "menu" | "unknown"`
- `details: object | null`

### `prompt`

- `has_text: boolean | null`

## Root-Session Rules

The published state represents the root OpenCode session only.

Bootstrap rules:

1. If a root `session.created` event is observed (`parentID` absent), that session
   becomes `root_opencode_session_id`.
2. If the plugin attached late and no root `session.created` was seen, the first
   acceptable `session.idle` may bootstrap the root.
3. Once the root is known, sub-session events must not replace it.

Permission rule:

- Permission events continue to be handled by the plugin for approval flow.
- Only permission events whose `sessionID` matches the tracked root may mutate the
  published state stream.

## v1 Detail Payload Shapes

To keep the protocol stable and small, the plugin emits compact detail objects.

### Session step details

Used for root `session.created` / `session.idle`:

```json
{ "session_id": "ses_abc123" }
```

### Permission focus details

Used for root `permission.asked` / `permission.updated`:

```json
{
  "id": "perm-123",
  "title": "bash",
  "type": "bash"
}
```

The plugin must not emit raw upstream event payloads, prompt text, or large nested
fragments in v1.

## Consumed OpenCode Events

### Implemented in v1

| Event | Effect |
|---|---|
| `session.created` | Sets root session when event is for a root session; updates prompt focus and step metadata |
| `session.idle` | Sets idle state, increments turn/step counts, and may bootstrap root if attaching late |
| `permission.asked` | Sets permission focus and root-scoped step metadata when event belongs to the root session |
| `permission.updated` | Same as `permission.asked` |

### Observed but not part of the v1 state contract

These events may still be consumed by other plugin logic, but they do not currently
extend the published state schema:

- `question.asked`
- `question.replied`
- `message.updated`
- `message.part.updated`
- `session.status`
- `session.updated`
- `command.executed`
- `tui.prompt.append`

These stay out of the stable state contract until payload shape and value are
confirmed in code/tests.

## Unknown and Null Semantics

- `null` means the field is intentionally unknown or explicitly cleared
- omitted patch fields mean unchanged
- `prompt.has_text` starts as `null`, not `false`
- `provider_id` and `model_id` remain `null` unless explicit upstream fields are observed

## Failure Behavior

v1 is best-effort:

- spawn failure is non-fatal
- stdin write failure is non-fatal
- child exit is non-fatal
- the plugin continues delivering inbox messages and handling permission flows

If the writer becomes unavailable, the plugin stops emitting state until a later
plugin lifecycle start can create a new writer and send a new snapshot.

Future versions may add reconnect/backoff behavior.
