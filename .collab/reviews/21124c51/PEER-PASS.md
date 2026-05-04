# Peer-PASS — 21124c51 (cedar-coder)

**Reviewer**: test-agent
**Date**: 2026-05-03
**Commit**: 21124c51c4ddb038f93727abbb431aff89833bc2
**Branch**: (main tree, committed by cedar)
**Criteria checked**:
- `diff-reviewed` (code review below)

---

## Commit: docker-tests: pass session_id and alias as env vars in run() helper

### Bug

The `run()` helper in `test_broker_respawn_pid.py`, `test_ephemeral_contract.py`, and `test_sealed_sanity.py` accepted `session_id` and `alias` parameters but never forwarded them to the subprocess env. This caused:
- CLI subprocesses to fail alias resolution (`session_id_from_env` returns None)
- In race conditions with a live broker, could accidentally pick up another process's alias → "cannot send a message to yourself" error

### Fix

Forward `C2C_MCP_SESSION_ID` and `C2C_MCP_AUTO_REGISTER_ALIAS` into subprocess env when parameters are provided:

```python
if session_id is not None:
    env["C2C_MCP_SESSION_ID"] = session_id
if alias is not None:
    env["C2C_MCP_AUTO_REGISTER_ALIAS"] = alias
```

### Code quality

- Correct: `session_id` → `C2C_MCP_SESSION_ID` for alias lookup
- Correct: `alias` → `C2C_MCP_AUTO_REGISTER_ALIAS` for pre-register identity
- Consistent: identical fix applied to all 3 files with the same `run()` helper
- Comments accurately describe the purpose of each forwarding

## Verdict

**PASS** — minimal, targeted fix. Env vars correctly mapped. Same fix in all 3 affected files.
