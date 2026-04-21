# OpenCode Managed Config Invalid JSON After Prompt Edit

- **Time:** 2026-04-13T12:30:48Z
- **Reporter:** codex
- **Severity:** High for the managed OpenCode launcher and Python test suite
- **Status:** Fixed by re-encoding the prompt as a valid JSON string.

## Symptom

`python3 -m unittest tests.test_c2c_cli` failed. The first full-suite run showed
a timeout in `OpenCodeLocalConfigTests.test_run_opencode_inst_rearm_skips_live_process_without_tty`,
but narrowing to the class exposed the deterministic failure:

```text
[run-opencode-inst] invalid JSON in
/home/xertrov/src/c2c-msg/run-opencode-inst.d/c2c-opencode-local.json:
Invalid control character at: line 7 column 393 (char 627)
```

`python3 -m json.tool run-opencode-inst.d/c2c-opencode-local.json` reproduced
the same parser error.

## How It Was Discovered

The heartbeat-driven verification pass ran:

- `python3 -m unittest tests.test_c2c_cli`
- `python3 -m unittest tests.test_c2c_cli.OpenCodeLocalConfigTests -v`
- `python3 -m json.tool run-opencode-inst.d/c2c-opencode-local.json`

The class run failed on both direct JSON loading and `run-opencode-inst` dry-run
because the checked-in managed config could no longer be parsed.

## Root Cause

A prompt update added `STEP 0: mcp__c2c__whoami`, but the file ended up with
literal unescaped newlines inside the JSON string. That made the whole managed
config invalid even though the intended prompt text was otherwise reasonable.

## Fix

Rewrote `run-opencode-inst.d/c2c-opencode-local.json` so the prompt remains a
single valid JSON string with escaped `\n` separators. The content still includes
the new `STEP 0` identity self-check.

## Verification

- `python3 -m json.tool run-opencode-inst.d/c2c-opencode-local.json`
- `python3 -m unittest tests.test_c2c_cli.OpenCodeLocalConfigTests -v`
- `python3 -m unittest tests.test_c2c_cli.OpenCodeLocalConfigTests.test_run_opencode_inst_rearm_skips_live_process_without_tty -v`

All passed after the fix.

## Follow-up

Prompt edits to tracked JSON configs should be made with a JSON writer or
validated immediately with `python3 -m json.tool <file>`. Long prompt strings are
easy to corrupt by manual editing.
