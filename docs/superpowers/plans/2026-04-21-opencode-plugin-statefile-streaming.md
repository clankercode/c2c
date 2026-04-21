# OpenCode Plugin Statefile Streaming Plan

> **For agentic workers:** review this plan before implementation. Do not start coding from memory. The plan intentionally separates plugin-side work from the OCaml statefile writer implementation.

**Goal:** Extend `.opencode/plugins/c2c.ts` so it maintains a small in-memory state model for the active root OpenCode session and streams that state over stdin to `c2c oc-plugin stream-write-statefile`. The plugin should emit an initial snapshot plus incremental patches as relevant OpenCode events occur. The OCaml command will own canonical statefile persistence; the plugin remains best-effort and must not break message delivery if the command is missing or fails.

**Architecture:** Replace the plugin's current one-shot `stream-write-statefile` snapshot calls with a persistent child process dedicated to state streaming, separate from the existing request/response `runC2c()` helper. The plugin will keep one root-session-focused state object, normalize incoming OpenCode events into state updates, and write newline-delimited JSON envelopes to the child stdin. v1 uses explicit `null` / `"unknown"` for fields the plugin cannot reliably observe yet. Delivery behavior (`poll-inbox`, `promptAsync`, permission DMs) remains unchanged except for state updates emitted alongside existing logic.

**Tech Stack:** TypeScript plugin, Node `child_process.spawn`, JSON Lines over stdin, existing Vitest unit tests in `.opencode/tests/c2c-plugin.unit.test.ts`, existing Node integration harness if needed, documentation under `docs/`.

---

## Scope

### In scope

- Plugin-managed in-memory state for the active root session only
- Persistent subprocess: `c2c oc-plugin stream-write-statefile`
- JSONL protocol from plugin to subprocess stdin
- Initial snapshot + incremental patch emission
- Stable minimal schema for:
  - c2c identity
  - OpenCode/root session identity
  - plugin lifecycle timestamps
  - `agent` state (`is_idle`, counters, last step, provider/model if known)
  - `tui_focus`
  - prompt text presence (`has_text`) only
- Tests covering emitted JSONL lines and non-fatal writer failure behavior
- A dedicated protocol/spec document describing emitted and consumed events

### Out of scope

- OCaml implementation of `c2c oc-plugin stream-write-statefile`
- Canonical on-disk statefile format or retention policy
- Multi-session or sub-agent aggregation in the plugin
- Prompt text content capture
- Heuristic inference beyond explicit best-effort defaults
- Changes to the existing delivery protocol or permission approval UX

---

## Current Facts

- The plugin currently uses `runC2c()` for short-lived request/response commands like `poll-inbox`, `list`, and `send`.
- The plugin already has one persistent child process: `c2c monitor`.
- The plugin already contains an early state-streaming implementation that must be replaced, not layered on top:
  - a `pluginState` object
  - event summarization/provider/model mining
  - one-shot `spawn(command, ["oc-plugin", "stream-write-statefile"])`
  - per-event snapshot writes rather than persistent streaming
- The plugin sidecar currently stores:
  - `session_id`
  - `alias`
  - `broker_root`
- The setup alias written into `.opencode/c2c-plugin.json` can differ from a later runtime shell alias created by `c2c init`.
- The plugin has reliable handling today for:
  - `session.created`
  - `session.idle`
  - `permission.asked`
  - `permission.updated`
- Repo research suggests additional OpenCode event names may exist and may become useful for state tracking:
  - `question.asked`
  - `question.replied`
  - `message.updated`
  - `message.part.updated`
  - `session.status`
  - `session.updated`
  - `command.executed`
  - `tui.prompt.append`

These additional events must be handled only when payload shape is confirmed in code or tests. Unknown payloads must not be guessed into the stable schema.

---

## Output Contracts

## Contract 1: Plugin subprocess contract

- Command: `c2c oc-plugin stream-write-statefile`
- Transport: newline-delimited JSON written to child stdin
- Child lifecycle:
  - start once during plugin startup
  - emit a full `state.snapshot` immediately after every successful writer start, before any patches
  - keep stdin open for the process lifetime
  - close/kill on plugin process exit
- Failure policy in v1:
  - spawn failure is non-fatal
  - stdin write failure is non-fatal
  - child exit after startup is non-fatal
  - plugin logs locally and continues
  - writer becomes unavailable after failure; v1 does not attempt in-process restart
  - the next plugin lifecycle start is the resync point and must emit a fresh `state.snapshot`
  - TODO comment marks reconnect/backoff work for later

### Resync rule

The OCaml consumer must treat every `state.snapshot` as authoritative replacement of previously accumulated plugin state for that writer identity.

The plugin contract for v1 is:

- every successful writer process start is followed by one full `state.snapshot`
- `state.patch` events are only valid after a `state.snapshot` from the same writer lifetime
- if the writer dies or stdin breaks, no more guarantees exist until the plugin starts a fresh writer and emits a new snapshot

This keeps the protocol safe without inventing partial replay or sequence numbering in v1.

## Contract 2: JSONL envelope types

Use two emitted event types:

1. `state.snapshot`
2. `state.patch`

Rationale:

- `state.snapshot` gives the OCaml side a clean bootstrap point even if it starts mid-session.
- `state.patch` keeps steady-state traffic small.
- Typed envelopes are easier to debug than raw partial objects.

### Snapshot envelope

```json
{
  "event": "state.snapshot",
  "ts": "2026-04-21T12:34:56.789Z",
  "state": {
    "c2c_session_id": "opencode-c2c",
    "c2c_alias": "opencode-mire-kiva",
    "root_opencode_session_id": null,
    "opencode_pid": 12345,
    "plugin_started_at": "2026-04-21T12:30:00.000Z",
    "state_last_updated_at": "2026-04-21T12:34:56.789Z",
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

### Patch envelope

```json
{
  "event": "state.patch",
  "ts": "2026-04-21T12:35:01.222Z",
  "patch": {
    "agent": {
      "is_idle": true,
      "turn_count": 4,
      "step_count": 19,
      "last_step": {
        "event_type": "session.idle",
        "at": "2026-04-21T12:35:01.222Z",
        "details": null
      }
    },
    "tui_focus": {
      "ty": "prompt",
      "details": null
    },
    "state_last_updated_at": "2026-04-21T12:35:01.222Z"
  }
}
```

### Patch merge semantics

The consumer must apply patches as a deep object merge with these rules:

- omitted fields mean "unchanged"
- object values merge recursively
- scalar values replace the previous value
- `null` means explicit clear-to-null, not "unknown by omission"
- arrays, if introduced later, replace the previous array entirely unless a later version says otherwise

For v1, the plugin should avoid emitting arrays in patches.

---

## Canonical Plugin-Side State Schema

### Identity and lifecycle

- `c2c_session_id: string`
  - From sidecar/env plugin session ID
- `c2c_alias: string | null`
  - From sidecar alias only in v1
- `root_opencode_session_id: string | null`
  - Root `ses_*` ID discovered from `session.created` or from the first acceptable bootstrap `session.idle`
- `opencode_pid: number`
  - `process.pid`
- `plugin_started_at: string`
  - ISO 8601 with milliseconds
- `state_last_updated_at: string`
  - ISO 8601 with milliseconds; bump on every emitted snapshot/patch

### `agent`

- `is_idle: boolean | null`
- `turn_count: number`
  - v1 definition: number of observed root `session.idle` completions
- `step_count: number`
  - v1 definition: number of handled state-relevant events from this fixed set only:
    - root `session.created`
    - root `session.idle`
    - tracked permission events that belong to the root session
- `last_step: null | {
    event_type: string,
    at: string,
    details: unknown
  }`
- `provider_id: string | null`
- `model_id: string | null`

### `tui_focus`

- `ty: "permission" | "question" | "prompt" | "menu" | "unknown"`
- `details: unknown | null`

v1 detail-shape rule:

- `tui_focus.details` and `agent.last_step.details` must be compact JSON objects with a documented field set per event class
- do not emit raw upstream payloads
- target size should stay comfortably small; aim for a terse summary rather than full event mirroring

### `prompt`

- `has_text: boolean | null`

---

## Event Mapping Plan

Only root-session state is tracked. Sub-session events must not mutate root state unless explicitly promoted later.

### Root bootstrap rule

Because the plugin may attach after the root session already exists, v1 uses this bootstrap rule:

1. If a root `session.created` event is observed (`info.id` present and `parentID` absent), that session becomes `root_opencode_session_id`.
2. Otherwise, if `root_opencode_session_id` is still null and a `session.idle` event arrives, the plugin may adopt that idle session as root using the same fallback the current delivery code relies on.
3. Once `root_opencode_session_id` is set, later sub-session events must not replace it.

This rule is intentionally aligned with the plugin's existing delivery bootstrap so state tracking does not regress sessions that start before the plugin begins observing events.

### Permission-session rule

Permission events only affect root-tracked state when they belong to the root session.

- If a permission event has a `sessionID` matching `root_opencode_session_id`, update root state.
- If `root_opencode_session_id` is still null and the permission event's `sessionID` becomes the accepted bootstrap root by the rule above, update root state.
- Otherwise, preserve current permission-handling behavior for delivery/approval, but do not let the non-root permission event mutate the published root-session state snapshot.

| Upstream event | Handle in v1? | State impact |
|---|---|---|
| `session.created` | Yes | For root sessions only: set `root_opencode_session_id`, increment `step_count`, update `last_step`, set `tui_focus.ty="prompt"` best-effort |
| `session.idle` | Yes | For the adopted root session only: set `agent.is_idle=true`, increment `turn_count`, increment `step_count`, update `last_step`, set `tui_focus.ty="prompt"` |
| `permission.asked` | Yes | For the root session only: set `agent.is_idle=false`, increment `step_count`, update `last_step`, set `tui_focus.ty="permission"`, attach compact details |
| `permission.updated` | Yes | Same as `permission.asked` |
| `question.asked` | Tentative | If payload shape is confirmed, set `agent.is_idle=false`, `tui_focus.ty="question"`, attach details |
| `question.replied` | Tentative | If payload shape is confirmed, clear question focus back toward `prompt` or `unknown` |
| `message.updated` | Tentative | Increment `step_count`, update `last_step`, mine provider/model only if explicit |
| `message.part.updated` | Tentative | Same as `message.updated` if payload gives explicit model/provider fields |
| `command.executed` | Tentative | Update `last_step.details` if payload is compact and useful |
| `tui.prompt.append` | Tentative | If payload shape is confirmed, update `prompt.has_text` |
| `session.status` / `session.updated` | Tentative | Use only if payload cleanly improves `is_idle` or provider/model confidence |

### Notes on unknowns

- If a payload shape is not confirmed, log it and do not emit guessed schema changes.
- `prompt.has_text` starts as `null`, not `false`.
- `provider_id` and `model_id` start as `null` and stay null unless explicit fields are observed.
- `menu` focus should not be emitted until there is a concrete event/payload source.

### Compact detail field sets for v1

Use these safe detail shapes in v1:

- `agent.last_step.details` for root `session.created` / `session.idle`:
  - `{ "session_id": string | null }`
- `tui_focus.details` for permission events:
  - `{ "id": string | null, "title": string | null, "type": string | null }`

Do not include previews, raw prompt text, full permission payloads, or arbitrary nested payload fragments in v1.

---

## File Map

| File | Role |
|------|------|
| `.opencode/plugins/c2c.ts` | **MODIFY** — replace one-shot state streaming with persistent writer lifecycle, typed JSONL emission, and root-scoped event mapping |
| `.opencode/tests/c2c-plugin.unit.test.ts` | **MODIFY** — assert snapshot/patch writes, root-session scoping, non-fatal failure behavior |
| `.opencode/tests/integration-harness.ts` | **OPTIONAL MODIFY** — only if needed to expose or observe stream writes during integration |
| `docs/opencode-plugin-statefile-protocol.md` | **NEW** — protocol/spec document for emitted JSONL events and consumed OpenCode events |
| `docs/client-delivery.md` | **MODIFY** — add a short pointer to the new protocol doc if useful |

---

## Task 1: Add plugin-side state model and writer process

**Files:**

- Modify: `.opencode/plugins/c2c.ts`
- Test: `.opencode/tests/c2c-plugin.unit.test.ts`

- [ ] **Step 1: Write failing unit tests for state stream startup behavior**

Add tests that assert plugin startup attempts to:

- spawn `c2c oc-plugin stream-write-statefile`
- emit exactly one `state.snapshot` line on successful startup
- include `c2c_session_id`, `c2c_alias`, `opencode_pid`, `plugin_started_at`, and null defaults
- stop using the old one-shot-per-event snapshot path

- [ ] **Step 2: Run the new tests and verify failure**

Run the plugin unit test subset for stream startup. Expected: FAIL because no writer process/state emission exists yet.

- [ ] **Step 3: Implement a dedicated persistent writer path**

In `.opencode/plugins/c2c.ts`:

- add state types for snapshot/patch envelopes
- reuse or reshape the existing `pluginState` object rather than duplicating it
- add a separate `spawnStateWriter()` helper that does **not** reuse `runC2c()`
- add `writeStateSnapshot()` and `writeStatePatch()` helpers
- ensure writes append a single newline-delimited JSON string to child stdin
- remove or replace the current one-shot `streamStateSnapshot()` behavior so only the new protocol remains

Design constraints:

- no shell invocation
- no waiting for subprocess response
- no throw on spawn/write failure
- kill/close child on process exit

- [ ] **Step 4: Keep failure behavior explicitly best-effort**

If spawn or write fails:

- log with existing plugin logging
- disable or mark writer unavailable
- leave inbox delivery and permission flows untouched
- do not attempt synchronous fallback spawning on every event
- add a TODO for restart/backoff behavior once OCaml command exists

- [ ] **Step 5: Run the startup/state-stream tests and verify PASS**

- [ ] **Step 6: Self-review for minimalism**

Check that:

- writer process code is separate from `runC2c()`
- no duplicate timestamp helpers or unnecessary abstractions were added
- no existing delivery code path was changed except to emit state updates

---

## Task 2: Emit patches from confirmed root-session events

**Files:**

- Modify: `.opencode/plugins/c2c.ts`
- Test: `.opencode/tests/c2c-plugin.unit.test.ts`

- [ ] **Step 1: Write failing tests for root-session event mapping**

Add tests covering:

- `session.created` for a root session emits a patch updating `root_opencode_session_id`, `step_count`, `last_step`, and `tui_focus.ty`
- `session.idle` can bootstrap the root when the plugin attaches mid-session and no root `session.created` was observed yet
- `session.idle` for the adopted root emits a patch setting `agent.is_idle=true`, incrementing `turn_count`, incrementing `step_count`, and moving focus to `prompt`
- sub-session `session.created` with `parentID` does not overwrite root-session state

- [ ] **Step 2: Run the event-mapping tests and verify failure**

- [ ] **Step 3: Implement root-session-only state transitions**

Use the existing root-session tracking rules already in the plugin:

- ignore sub-sessions for root identity
- allow the first acceptable `session.idle` to bootstrap the root when needed
- only mutate root-focused state from root events after bootstrap
- centralize patch creation so the emitted patch matches the in-memory mutation

- [ ] **Step 4: Run tests and verify PASS**

- [ ] **Step 5: Review the counter semantics**

Confirm the code matches the documented v1 meanings:

- `turn_count` = observed root `session.idle` completions
- `step_count` = handled state-relevant events

---

## Task 3: Emit patches from permission and other confirmed focus events

**Files:**

- Modify: `.opencode/plugins/c2c.ts`
- Test: `.opencode/tests/c2c-plugin.unit.test.ts`

- [ ] **Step 1: Write failing tests for permission-driven focus changes**

Add tests asserting that `permission.asked` and `permission.updated` emit a patch that:

- sets `agent.is_idle=false`
- increments `step_count`
- sets `tui_focus.ty="permission"`
- includes compact `details` with safe fields only, e.g. `id`, `title`, `type`
- does not mutate published root state for non-root permission events

- [ ] **Step 2: Run the tests and verify failure**

- [ ] **Step 3: Implement permission focus patches**

Keep details compact and stable. Avoid copying the full permission payload if it includes noisy or unstable fields.

- [ ] **Step 4: Gate any non-permission event support behind payload confirmation**

For `question.*`, `message.*`, `command.executed`, `tui.prompt.append`, `session.status`, and `session.updated`:

- only add v1 support if payload shape is directly confirmed in code/tests during implementation
- otherwise leave explicit TODOs and keep schema values as null/unknown

- [ ] **Step 5: Run tests and verify PASS**

---

## Task 4: Document the protocol and complete emitted/consumed event spec

**Files:**

- Create: `docs/opencode-plugin-statefile-protocol.md`
- Possibly modify: `docs/client-delivery.md`

- [ ] **Step 1: Write the protocol/spec document**

This task should be started before code shape is allowed to drift. If implementation begins first, the protocol doc must still be written early enough to guide, not merely post-hoc describe, the envelope format.

The document must fully specify:

- subprocess command and stdin transport
- emitted JSONL envelope types (`state.snapshot`, `state.patch`)
- canonical schema fields and null/unknown semantics
- root-session-only scope rules
- event mapping table for all consumed OpenCode events considered by the plugin
- which events are implemented in v1 vs documented-but-unhandled
- failure behavior and future reconnect TODO

- [ ] **Step 2: Include concrete examples**

At minimum include:

- one boot snapshot
- one `session.idle` patch
- one permission-focus patch

- [ ] **Step 3: Link the protocol doc from an operator-facing page if useful**

Add a short pointer from `docs/client-delivery.md` if that improves discoverability without bloating the page.

- [ ] **Step 4: Review the doc for contract completeness**

A reviewer should be able to implement the OCaml consumer from the document alone.

---

## Task 5: Verification and review gate

**Files:**

- Modify as needed from previous tasks

- [ ] **Step 1: Run focused plugin unit tests**

Run the relevant `.opencode/tests/c2c-plugin.unit.test.ts` subset covering:

- snapshot emission
- patch emission
- root-session scoping
- root bootstrap from idle
- permission focus updates
- writer failure tolerance
- absence of the old one-shot snapshot-per-event path

- [ ] **Step 2: Run broader plugin tests if the repo already has a cheap path**

If there is a fast existing command for the OpenCode plugin test file, run it. Do not broaden into unrelated full-suite work unless required.

- [ ] **Step 2a: Re-run existing delivery and permission tests as regression coverage**

At minimum preserve coverage for the behaviors the plugin already owns:

- promptAsync delivery envelope formatting
- spool retry after promptAsync failure
- empty inbox no-op behavior
- permission DM / timeout / late-reply handling
- monitor coexistence assumptions if there is an existing cheap test path

- [ ] **Step 3: Perform a code review pass focused on regressions**

Check for:

- accidental interference with inbox delivery or promptAsync behavior
- duplicate state writes from old + new streaming paths both remaining live
- added hot-path subprocess churn
- accidental dependence on the OCaml command already existing
- child-process leaks on exit
- overlarge or unstable `details` payloads
- root/sub-session mixing

- [ ] **Step 4: Record any discovered gaps before implementation closes**

If implementation reveals missing OpenCode payload guarantees or protocol ambiguities, log them in `.collab/findings/` before moving on.

---

## Risks and Mitigations

### Risk: Prompt state is not actually observable

Mitigation:

- keep `prompt.has_text = null` until `tui.prompt.append` or equivalent payload is confirmed
- do not invent a heuristic from unrelated events

### Risk: Provider/model metadata is not exposed in usable event payloads

Mitigation:

- keep `provider_id` / `model_id` null unless explicit fields are observed
- document this clearly in the protocol spec

### Risk: Persistent writer child introduces leaks or stale pipes

Mitigation:

- own the child in one place
- kill/close on process exit
- emit a fresh snapshot on every writer start
- keep v1 failure behavior simple instead of complex half-restart logic

### Risk: Sidecar alias differs from runtime shell alias

Mitigation:

- document that v1 emits sidecar/setup alias only
- do not attempt runtime alias discovery from the plugin yet

### Risk: Patch semantics drift from implementation

Mitigation:

- keep emitted envelope types and schema examples in the dedicated protocol doc
- define deep-merge and null-clear semantics explicitly
- assert exact JSON shape in unit tests where practical

### Risk: Existing one-shot streaming code remains alongside the new path

Mitigation:

- treat replacement of the old path as explicit scope
- add tests ensuring state streaming uses the persistent writer contract only
- review for duplicate writes before implementation closes

---

## Acceptance Criteria

- The plugin spawns a persistent `c2c oc-plugin stream-write-statefile` subprocess and writes JSONL to stdin.
- The plugin emits one `state.snapshot` on every successful writer start before any `state.patch`.
- The plugin emits `state.patch` updates for confirmed v1 events at least covering:
  - root `session.created`
  - root `session.idle`
  - `permission.asked`
  - `permission.updated`
- Patch merge semantics and null-clear behavior are explicitly documented.
- The plugin ignores subprocess spawn/write failures without breaking message delivery.
- Existing delivery behavior and permission handling remain covered by regression tests.
- Root-session-only scoping is preserved.
- A dedicated protocol doc exists and completely describes emitted JSONL events plus consumed OpenCode event mappings.
- Focused tests cover the new behavior.

---

## Recommended Implementation Order

1. Tighten protocol doc shape and merge semantics
2. Replace old one-shot streaming path with writer process + snapshot
3. Root-session event patches and idle bootstrap
4. Permission/focus patches
5. Focused verification and regression review
