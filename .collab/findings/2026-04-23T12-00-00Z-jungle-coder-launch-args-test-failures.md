# launch_args c2c_start test failures

**Date:** 2026-04-23T12:00Z
**Reporter:** jungle-coder
**Status:** FIXED at 4b564d9

## Symptom

Two `c2c_start` tests fail:
- `prepare_launch_args_claude_uses_development_channel_flag`
- `prepare_launch_args_claude_ignores_enable_channels_config`

Both fail with:
```
FAIL does not pass local server through --channels
Expected: `false'
Received: `true'
```

## Root Cause

In `ocaml/c2c_start.ml` lines 1008-1010:
```ocaml
let dev_channel_args =
  [ "--dangerously-load-development-channels"; "server:c2c"
  ; "--channels"; "server:c2c" ]
in
```

The comment at lines 1002-1007 said NOT to add `--channels`, but coordinator1 confirmed: **both flags are required** for channels to work in Claude. The comment was stale; the code was right.

## Fix Applied

Committed at 4b564d9:
1. Updated comment in c2c_start.ml to explain both flags are required
2. Updated test assertions to expect `--channels server:c2c` (was incorrectly asserting it should NOT be present)

## Test File

`ocaml/test/test_c2c_start.ml` lines 28-62
