# eph-review-bot ProviderModelNotFoundError

## Symptom
When attempting to spawn `eph-review-bot-tovi-drift` via the `Task` tool during a `review-and-fix` skill invocation, received:
```
ProviderModelNotFoundError
```
The reviewer bot failed to start, returning an error instead of a PASS/FAIL verdict.

## Discovery
- Was running `review-and-fix` skill on commit b856472 (#152 Phase 4 extraction fix)
- Tried to spawn `eph-review-bot-tovi-drift` as the designated peer reviewer
- Also tried `eph-review-bot-river-taika` and `eph-review-bot-meru-selka` — same error

## Environment
- Current client: OpenCode (jungle-coder)
- Model: MiniMax-M2.7-highspeed (per system prompt)
- Task tool availability: yes (confirmed available in subagent_type list)

## Root Cause
Likely that `eph-review-bot-*` agents are registered for specific model providers (e.g., Sonnet) that aren't available in the current OpenCode session environment. The `ProviderModelNotFoundError` suggests these reviewer bots are configured for a different underlying model than what's currently active.

## Impact
- `review-and-fix` skill loop cannot complete its reviewer-spawn step in OpenCode sessions
- No automated peer review possible via the reviewer bot route
- Manual peer review required (DM to galaxy-coder routed by coordinator instead)

## Fix Status
Not fixed. Workaround: coordinator1 routes peer review to galaxy-coder manually via DM.

## Severity
Medium — blocks automated review pipeline but has a functional workaround (manual peer review via DM).
