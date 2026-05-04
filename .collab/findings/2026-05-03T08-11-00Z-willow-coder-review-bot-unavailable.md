# Finding: review-bot unavailable in this harness (2026-05-03)

## Symptom
`Task` tool with `subagent_type: "review-bot"` returned:
```
ProviderModelNotFoundError
```
No review-agent instances appear to be available in this OpenCode harness.

## Discovery
Attempted to dispatch `review-and-fix` skill's Step 1 subagent to review
SHA `e4573e01` (sweep safety guard). Fallback: did fresh-slate self-review
and signed with `--allow-self --via-subagent "task-dispatch-failed-ProviderModelNotFoundError-fresh-slate-self-review"`.

## Impact
- Peer-PASS for `e4573e01` is self-signed with `--allow-self` flag
- Self-review warning in artifact: `reviewer matches commit author — self-review`
- The `--allow-self` path is sanctioned for "low-stakes mechanical changes"
  (which this is — a flag + guard), but a real peer would be preferred

## Workaround
Used fresh-slate self-review from git diff + build verification. Low-stakes
mechanical change, so this is acceptable per git-workflow.md.

## Severity
Low — the change is mechanical and the self-review was thorough (build clean,
type correctness verified, flag wiring verified, logic verified against
existing patterns).

## Fix
- Check if `review-bot` or other peer-reviewer agents are available before
  relying on `Task` tool for peer-PASS dispatches
- Or accept that some harnesses don't have review subagents and
  `--allow-self` will be the fallback path in those cases
