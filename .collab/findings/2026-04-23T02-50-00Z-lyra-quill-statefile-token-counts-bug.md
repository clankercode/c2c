# Statefile Token Count Bug — Lyra-Quill

## Symptom
`c2c statefile` reports `tokens_input: 189`, `tokens_output: 58` for Lyra-Quill,
but the agent has 288 steps and 270 completed turns. These numbers are clearly wrong.

## Root Cause (provisional)
The OpenCode plugin at `.opencode/plugins/c2c.ts` has accumulation logic for
token counts:

```typescript
// line 948-955
const tokens = info.tokens ?? {};
const prev = pluginState.context_usage;
const next = {
  tokens_input: prev.tokens_input + (tokens.input ?? 0),
  tokens_output: prev.tokens_output + (tokens.output ?? 0),
  ...
};
```

The accumulation IS running (statefile shows accumulated values, not per-turn values).
However, `info.tokens` from OpenCode's `message.updated` event appears to be empty
or not contain `input`/`output` fields. This means `tokens.input ?? 0` is always 0,
so no tokens are ever added.

Evidence:
- `completed_turns: 270` IS accumulated correctly (different event path)
- `tokens_cache_read: 147972` IS accumulated (same pattern as tokens_input/output)
- `tokens_input: 189` and `tokens_output: 58` are suspiciously round and small —
  likely default/initial values with nothing ever added

## Debug Log Evidence
The debug log shows `message.part.delta` and `message.part.updated` events from
OpenCode, but no explicit token usage data in the events.

## Fix Direction
Need to get token usage data from a different source — either:
1. OpenCode events DO include token data somewhere we haven't looked
2. OpenCode API responses include token usage in a different event or field
3. OpenCode has a separate token reporting API we need to call

## Filed
- TODO.txt entry added by Lyra-Quill 2026-04-23
- Commit: (pending)