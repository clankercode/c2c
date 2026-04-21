# Test Failures: c2c_start nested-session guardrail breaks test isolation

**Date:** 2026-04-21
**Severity:** Test debt (pre-existing, not caused by recent commits)
**Status:** Needs fix

## Symptom

15 tests fail in `tests/test_c2c_start.py` and `tests/test_c2c_start_resume.py` after installing commits 3460531/02553ee (nested-session guardrail):

```
FAILED tests/test_c2c_start.py::C2CStartExit109RegressionTests::test_exit109_logs_death_record
FAILED tests/test_c2c_start.py::C2CStartExit109RegressionTests::test_exit109_prints_hint
FAILED tests/test_c2c_start.py::C2CStartExit109RegressionTests::test_exit109_propagated
... (15 total)
```

The FATAL error:
```
FATAL: refusing to start nested session.
You are already running inside a c2c agent session (C2C_MCP_SESSION_ID=ceo).
```

## Root Cause

The `_run_c2c_start()` helper in `C2CStartExit109RegressionTests` passes `**os.environ` to the subprocess, which includes `C2C_MCP_SESSION_ID=ceo` inherited from the CEO parent shell.

The nested-session guardrail (3460531) checks: `C2C_MCP_SESSION_ID` set + `C2C_WRAPPER_SELF` absent → FATAL + exit 1.

Since the test subprocess inherits `C2C_MCP_SESSION_ID=ceo` from the parent, `c2c start` immediately exits with FATAL before reaching the opencode stub.

## Pre-existing?

YES. The guardrail (3460531) was added AFTER origin/master (64cfadb). The tests were written before the guardrail existed and were never updated to isolate from parent environment.

Verifying: `git log --oneline origin/master..HEAD | grep -E "start|nested"` shows 3460531 and 02553ee are both post-origin/master commits.

## Fix Direction

In `_run_c2c_start()` (and similar helpers in other test classes), remove or override `C2C_MCP_SESSION_ID` and `C2C_MCP_AUTO_REGISTER_ALIAS` from the env passed to the subprocess:

```python
env = {
    **os.environ,
    "PATH": ...,
    "C2C_MCP_BROKER_ROOT": str(self.broker_root),
    "C2C_INSTANCES_DIR": str(self.instances_dir),
    "GIT_DIR": str(self.tmp_path / "no-such-git"),
}
# Clear c2c session vars so nested-session guardrail doesn't trigger
for var in ["C2C_MCP_SESSION_ID", "C2C_MCP_AUTO_REGISTER_ALIAS",
            "C2C_MCP_AUTO_REGISTER_ALIAS", "C2C_INSTANCE_NAME",
            "C2C_WRAPPER_SELF"]:
    env.pop(var, None)
```

Same fix needed in: `C2CStartOpencodeSessionPreflightTests`, `C2CStartRegistryCleanupRegressionTests`, `C2CStartNameValidationTests`, `C2CStartKickoffPromptTests`, `C2CStartInstallPromptTests`, and `test_c2c_start_resume.py`.

## Who Should Fix

Any coder. This is a test isolation fix, not a feature change.
