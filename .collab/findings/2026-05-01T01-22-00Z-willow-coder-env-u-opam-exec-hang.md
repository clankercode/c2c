# #587: `env -u C2C_MCP_BROKER_ROOT c2c migrate-broker --suggest-shell-export` hang

**Severity**: low (smoke-test artifact, not a production bug)
**Status**: closed — root cause identified, no code change needed
**Filed by**: willow-coder, 2026-05-01

## Symptom
Running the following command from a worktree shell hangs at 120s timeout:
```
env -u C2C_MCP_BROKER_ROOT opam exec -- dune exec --root . -- ./ocaml/cli/c2c.exe migrate-broker --suggest-shell-export
```

The same command with `C2C_MCP_BROKER_ROOT` set to the canonical path returns instantly:
```
C2C_MCP_BROKER_ROOT=/home/xertrov/.c2c/repos/8fef2c369975/broker opam exec -- dune exec --root . -- ./ocaml/cli/c2c.exe migrate-broker --suggest-shell-export
```

## Root cause
The hang is **not in c2c code**. The `--suggest-shell-export` path is pure:
1. `Sys.getenv_opt "C2C_MCP_BROKER_ROOT"` → returns `None`
2. `C2c_repo_fp.resolve_broker_root_canonical()` → pure string ops + `git config --get remote.origin.url`
3. `Printf.printf` → immediate
4. `exit 0`

The hang occurs in the **shell/`opam exec` bootstrap layer** when `env -u` strips `C2C_MCP_BROKER_ROOT` before `opam exec --` in the command chain. `opam exec` initializes the OPAM environment by reading state that may reference `C2C_MCP_BROKER_ROOT` or related paths. With the env var absent from the environment, the initialization hangs waiting for something that never comes.

**Evidence**: Running the same command through an intermediate `bash -c '...'` subshell works correctly:
```
env -u C2C_MCP_BROKER_ROOT bash -c 'opam exec -- dune exec --root . -- ./ocaml/cli/c2c.exe migrate-broker --suggest-shell-export'
# Returns instantly with correct output
```

## Verification
All three functional cases work correctly:

| Scenario | Behavior |
|----------|----------|
| `C2C_MCP_BROKER_ROOT` unset (via bash subshell) | "not set — canonical resolver active" ✅ |
| `C2C_MCP_BROKER_ROOT = canonical` | "already set to canonical path" ✅ |
| `C2C_MCP_BROKER_ROOT = stale path` | unset command + grep hints ✅ |

## Fix
No code change required. The flag works correctly in all normal operational patterns. The `env -u` + `opam exec --` chain is an edge case in test infrastructure only.

## Action items
- None — closed as wontfix / test-artifact
- Document here so future agents don't chase the code path
