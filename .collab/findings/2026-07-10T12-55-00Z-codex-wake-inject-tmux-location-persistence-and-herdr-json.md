# codex-wake-inject slice: two discoveries (tmux_location never persisted; herdr agent-get JSON wrapper)

**Agent**: codex-wake-inject slice worker (worktree `.worktrees/codex-wake-inject`)
**Date**: 2026-07-10
**Severity**: medium (1), would-have-been-high (2, caught pre-merge)

## 1. `tmux_location` was never persisted to the registry (#517 latent bug)

**Symptom**: `c2c list` was supposed to show each peer's tmux pane
(#517, commit 045768e0, whose message claims "registration_to_json:
include tmux_location") — but the field never round-tripped the registry
file, so any cross-process reader always saw `None`.

**Root cause**: `registration_to_json` destructured the field away
(`tmux_location = _`) and never emitted it. OCaml's warning 9
(missing-record-field in pattern) did not fire because the pattern listed
the field (bound to `_`), so the omission in the JSON build chain was
silent. `registration_of_json` *did* parse the key — a write/read
asymmetry that made the bug invisible to same-process tests.

**Fix**: codex-wake-inject slice commit `380d7196` — `tmux_location`,
`herdr_pane`, `herdr_socket` are now emitted by `registration_to_json`,
with a round-trip regression test (`test_c2c_wake_inject.ml`
"wake targets round-trip registry").

**Lesson**: when a record field is added, grep the `to_json` for `= _`
drops; add a round-trip test in the same slice.
(Note: `opaque_host_id` is STILL not persisted by `registration_to_json`
— left untouched here as it may be deliberate relay-passthrough; worth a
follow-up check.)

## 2. `herdr agent get` wraps its payload — `agent_status` is nested

**Symptom** (caught during slice self-review, before merge): the wake
injector's herdr idle probe parsed `agent_status` at the top level of
`herdr agent get` output. Live output (read-only query, 2026-07-10) is:

```json
{"id":"cli:agent:get","result":{"agent":{"agent":"codex","agent_status":"idle",...},"type":"agent_info"}}
```

so the naive parser always read "unknown" → the herdr backend would
never have injected (fail-closed, but silently useless).

**Fix**: `parse_herdr_agent_status` now searches the JSON tree for the
first `agent_status` member (handles top-level, `result.agent`, and
future wrapper drift), unit-tested against the captured live shape
(commit `66ae8f65`).

**Bonus discovery**: at-rest panes report `agent_status:"done"` (turn
finished, composer waiting) at least as often as `"idle"` — both codex
panes at rest showed done/idle. The injectable set is now
`idle | done`; `working`/`blocked`/`unknown` are never injected.

**Lesson**: fixture-gated tests prove command *shape*, not response
*shape*. When integrating a CLI you cannot exercise in CI, capture one
real response (read-only) and pin the parser to it with a unit test.
