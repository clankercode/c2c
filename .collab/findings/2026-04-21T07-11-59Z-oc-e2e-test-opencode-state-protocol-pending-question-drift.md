## Summary

The OpenCode plugin's streamed state includes a top-level `pendingQuestion` field, but
`docs/opencode-plugin-statefile-protocol.md` does not define that field in the canonical
schema or any emitted patch/snapshot examples.

## Symptom

- The plugin emits `pendingQuestion` into state snapshots when `question.asked` fires and
  clears it with a later snapshot after answer/reject/timeout.
- The protocol doc's canonical schema lists only:
  - `c2c_session_id`
  - `c2c_alias`
  - `root_opencode_session_id`
  - `opencode_pid`
  - `plugin_started_at`
  - `state_last_updated_at`
  - `agent`
  - `tui_focus`
  - `prompt`
- There are currently no tests asserting the emitted `pendingQuestion` field or documenting
  it as intentional protocol surface.

## How I Found It

- Read `.opencode/plugins/c2c.ts` while looking for one small OpenCode-side improvement.
- Compared the plugin state type and emission paths against
  `docs/opencode-plugin-statefile-protocol.md`.
- Confirmed the field is present in implementation-only by grepping plugin, tests, and docs.

## Evidence

- `.opencode/plugins/c2c.ts:309` defines `pendingQuestion` on `PluginState`
- `.opencode/plugins/c2c.ts:350` initializes it to `null`
- `.opencode/plugins/c2c.ts:1199` sets it when `question.asked` arrives
- `.opencode/plugins/c2c.ts:1205` emits a fresh `state.snapshot`
- `.opencode/plugins/c2c.ts:1233` clears it after reply/reject/timeout
- `.opencode/plugins/c2c.ts:1234` emits another `state.snapshot`
- `docs/opencode-plugin-statefile-protocol.md` does not mention `pendingQuestion`
- `.opencode/tests/c2c-plugin.unit.test.ts` has no `pendingQuestion` coverage

## Likely Root Cause

Question-observer state was added in the plugin after the protocol doc and tests were narrowed
to the earlier v1 schema. The implementation and the published contract drifted.

## Severity

Medium.

This is not an immediate runtime failure, but it weakens the contract between the plugin and
any future GUI/observer consumer. A consumer that treats the doc as canonical can silently miss
useful state or reject snapshots containing undocumented fields.

## Suggested Fix

Pick one and make it explicit:

1. If `pendingQuestion` is intended protocol surface, add it to
   `docs/opencode-plugin-statefile-protocol.md` and add unit coverage for snapshots before/after
   `question.asked` resolution.
2. If `pendingQuestion` is not intended to be part of the stable state protocol, remove it from
   streamed snapshots and keep it plugin-internal only.

My preference: document it and test it. It looks genuinely useful for the planned GUI observer.

## Fix Status

Not fixed in this pass. Logged as a small, concrete improvement opportunity.
