# Verification

## Best Verification Surface

The best verification surface is the session transcript JSONL.

Relevant files for the two C2C sessions:

- `~/.claude/projects/-home-xertrov-tmp/e2deb862-9bf1-4f9f-92f5-3df93978b8d4.jsonl`
- `~/.claude/projects/-home-xertrov-tmp/d5722f5b-6355-4f2f-a712-39e9a113fc06.jsonl`

## Validation Pattern

Use a unique marker prompt such as:

- `Reply with exactly: PTY_DELIVERY_20260411_A`

Then verify:

1. a new `user` message containing the marker appears
2. a new assistant reply containing the marker appears

For C2C verification, count only user turns wrapped as `<c2c event="message" ...>...</c2c>`. Ignore onboarding envelopes such as `event="onboarding"`.

## Confirmed Example

This exact marker was successfully injected into `C2C-test-agent2` and produced a normal assistant response.

## Secondary Verification

- watch the target terminal visually
- compare transcript line counts before and after injection
