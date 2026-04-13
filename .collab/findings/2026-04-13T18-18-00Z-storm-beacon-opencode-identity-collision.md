# OpenCode Managed-vs-Repo Identity Collision

- Symptom: `restart-opencode-self` could relaunch the managed OpenCode process into the correct session, but `c2c list` still showed `opencode-local` as dead with a stale pid, so direct broker sends to `opencode-local` failed after restart.
- Discovery: the checked-in repo-local OpenCode config at `.opencode/opencode.json` and the managed launcher path in `run-opencode-inst` both set `C2C_MCP_SESSION_ID=opencode-local` and `C2C_MCP_AUTO_REGISTER_ALIAS=opencode-local`. Any ad hoc `opencode` started in this repo could overwrite the same broker registration row with its own short-lived MCP child pid.
- Root cause: managed and generic repo-local OpenCode paths shared one fixed broker identity, so the registration row for `opencode-local` was nondeterministically owned by whichever MCP child last auto-registered.
- Fix status: in progress. The checked-in repo-local config is being separated from the managed `opencode-local` identity so only `run-opencode-inst` owns that alias/session pair.
- Severity: high for restart verification because the restart harness appeared broken even after the explicit `--session <id>` fix landed.
