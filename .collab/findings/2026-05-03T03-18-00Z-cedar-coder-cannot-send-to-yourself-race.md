# Finding: "cannot send to yourself" broker race — cedar-coder 2026-05-03

## Symptom
Two docker-tests fail with: `error: cannot send a message to yourself (heal-bob-TS)`
- `test_ephemeral_contract.py`
- `test_broker_respawn_pid.py`

The error is the CLI-level guard at `c2c.ml:409`:
```ocaml
if from_alias = to_alias then (
  Printf.eprintf "error: cannot send a message to yourself (%s)\n%!" from_alias;
  exit 1
)
```

## Audit finding (jungle-coder)
Ref: `.collab/research/2026-05-03-docker-tests-audit.md` lines 210-220

**Root cause (suspected):** concurrent registration alias resolution race. Both test processes register simultaneously; the broker's `current_registered_alias` returns the wrong session's alias due to a race in the registry lookup.

## Investigation so far

### How `resolve_alias` works for CLI subprocesses

Each test subprocess calls `c2c send <alias_b> <msg>`. The subprocess has NO `C2C_MCP_SESSION_ID` set (only `C2C_MCP_CLIENT_PID` is set). So `session_id_from_env()` returns `None`.

This means `current_registered_alias` returns `None` for the subprocess, and `resolve_alias` falls back to `env_auto_alias` = `C2C_MCP_AUTO_REGISTER_ALIAS`. But `C2C_MCP_AUTO_REGISTER_ALIAS` is NOT set in the subprocess environment.

So `env_auto_alias` returns `None`, and `resolve_alias` should fail with "cannot determine your alias".

Yet the error message says "cannot send a message to yourself (heal-bob-TS)" — meaning `from_alias = to_alias = heal-bob-TS`. This means `resolve_alias` IS returning bob's alias for alice's subprocess.

### How this could happen

The test's `run()` function sets subprocess env vars:
```python
env["C2C_MCP_CLIENT_PID"] = str(proc.pid)
```
But it does NOT set `C2C_MCP_SESSION_ID`.

The key question: how does alice's subprocess get `from_alias = heal-bob-{ts}`?

Possibility: the registry lookup in `current_registered_alias` finds bob's registration when called for alice's session. This would require a race in the registry read.

### Relevant code paths

1. `resolve_alias` (`c2c.ml:105`) → `current_registered_alias` (`c2c_mcp_helpers_post_broker.ml:1079`)
2. `current_registered_alias` calls `Broker.list_registrations broker` and does `List.find_opt (fun reg -> reg.session_id = session_id)`
3. If the subprocess's `session_id` from env is somehow bob's session_id, the lookup returns bob's registration

But the subprocess doesn't have `C2C_MCP_SESSION_ID` set. Where does it get bob's alias?

### Remaining questions
1. Is `C2C_MCP_AUTO_REGISTER_ALIAS` being set by the test harness to the WRONG alias (e.g., inherited from a parent process)?
2. Or is `session_id_from_env` somehow returning bob's session_id?
3. Or is there a bug in how the test harness passes `--alias` to the subprocess?

### Test harness analysis

```python
def run(argv, session_id=None, alias=None):
    env = dict(os.environ)
    env["C2C_CLI_FORCE"] = "1"
    env["C2C_MCP_BROKER_ROOT"] = BROKER_ROOT
    env["C2C_MCP_CLIENT_PID"] = "0"
    proc = subprocess.Popen([C2C] + argv, ...)
    env["C2C_MCP_CLIENT_PID"] = str(proc.pid)
    # NOTE: session_id and alias are NEVER added to env
```

The `session_id` and `alias` parameters to `run()` are NOT passed as env vars! They're unused in the subprocess call.

The `register` command is called with `--alias <alias>`, which sets the alias in the broker registry. The `send` command doesn't have an `--alias` flag — it relies on `resolve_alias` which needs `C2C_MCP_SESSION_ID` or `C2C_MCP_AUTO_REGISTER_ALIAS`.

### Conclusion
The test harness doesn't pass `session_id` or `alias` as env vars to the subprocess. For the `send` command, `resolve_alias` should fail ("cannot determine your alias"). The fact that it returns bob's alias suggests either:
- A bug in the test harness (session_id/alias not being used)
- OR the subprocess IS somehow getting bob's alias via `C2C_MCP_AUTO_REGISTER_ALIAS` from a parent process

## Status
Unresolved. Needs deeper investigation by the agent who implements the fix.

## Files to examine
- `ocaml/cli/c2c.ml:105` (`resolve_alias`)
- `ocaml/c2c_mcp_helpers_post_broker.ml:1079` (`current_registered_alias`)
- `ocaml/c2c_send_handlers.ml:272` (MCP handler self-send guard)
- `docker-tests/test_ephemeral_contract.py`
- `docker-tests/test_broker_respawn_pid.py`
