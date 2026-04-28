# Integration Test Failure: drain-inbox-to-spool Mock CLI Missing

**Date**: 2026-04-22
**Agent**: jungel-coder
**Status**: FIXED

## Symptom

`test_plugin_delivers_message_from_inbox` in
`tests/test_c2c_opencode_plugin_integration.py` was failing with:

```
AssertionError: Mock server did not receive prompt_async call
```

The test harness would start, emit READY, but when a message was written
to the inbox, no prompt_async call was recorded on the mock HTTP server.

## Root Cause

1. **Mock CLI only handled `poll-inbox`**: The `MOCK_CLI_TEMPLATE` in the
   integration test only implemented the `poll-inbox` subcommand. However,
   the plugin was refactored (commit d57236b, 2026-04-13) to use
   `drain-inbox-to-spool` instead of `poll-inbox` for inbox draining.
   When `deliverMessages` called `drainInbox()`, it spawned the mock CLI
   with `oc-plugin drain-inbox-to-spool`, which the mock CLI didn't
   recognize — causing a silent error and zero messages delivered.

2. **Missing `.opencode` directory**: The plugin writes its spool file to
   `process.cwd() / ".opencode" / "c2c-plugin-spool.json"`. During the
   test, `process.cwd()` is `tmp_path` (pytest's temp dir), but the
   `.opencode` directory didn't exist there, causing
   `FileNotFoundError` when the plugin tried to write the spool.

## Fix

1. Extended `MOCK_CLI_TEMPLATE` to handle `oc-plugin drain-inbox-to-spool`
   with proper `--spool-path` and `--json` flag parsing, matching the
   real CLI's behavior.

2. Added `opencode_dir = tmp_path / ".opencode"; opencode_dir.mkdir()` to
   the test setup before starting the harness.

**Commit**: 82d8391

## Verification

```bash
python3 -m pytest tests/test_c2c_opencode_plugin_integration.py -v --force-test-env
# PASSED in 1.90s

python3 -m pytest tests/ -q --force-test-env --ignore=tests/test_c2c_start.py
# 1138 passed, 6 skipped
```
