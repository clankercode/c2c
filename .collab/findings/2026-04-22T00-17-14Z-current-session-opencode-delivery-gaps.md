# OpenCode Delivery Gaps: OCaml Spool Path And Shared CLI Pin

- Symptom: unmanaged or globally installed OpenCode plugin subprocesses could inherit the wrong `session_id` / `broker_root`, causing delivery commands to target the wrong inbox or default broker.
  - Root cause: the plugin read sidecar identity locally, but spawned `c2c` subprocesses with plain `process.env`.
  - Fix status: fixed in `.opencode/plugins/c2c.ts` by merging sidecar-derived `C2C_MCP_SESSION_ID` and `C2C_MCP_BROKER_ROOT` into child process env.
  - Severity: high

- Symptom: OpenCode plugin delivery durability still depended on Python-style `poll-inbox` semantics and a best-effort TypeScript spool write, so drain + write failures could lose messages.
  - Root cause: the plugin drained via `poll-inbox --json` and swallowed spool write errors.
  - Fix status: fixed by adding OCaml `c2c oc-plugin drain-inbox-to-spool` and switching the plugin to use it; retry spool writes are now atomic and no longer silently ignored.
  - Severity: high

- Symptom: `c2c install opencode` and managed `c2c start opencode` did not consistently pin `C2C_CLI_COMMAND`, so plugin subprocesses could resolve the wrong `c2c` binary.
  - Root cause: the managed launch env set `C2C_CLI_COMMAND`, but shared OpenCode config refresh/setup paths did not.
  - Fix status: fixed in `ocaml/cli/c2c.ml` and `ocaml/c2c_start.ml`; shared OpenCode config now includes `C2C_CLI_COMMAND` while still omitting per-instance session/alias keys.
  - Severity: high

- Symptom: OpenCode auto-kickoff could hard-fail just because another same-broker peer was alive, preventing concurrent peers in the same repo.
  - Root cause: plugin conflict detection treated any alive same-broker peer as fatal in auto-kickoff mode.
  - Fix status: fixed in `.opencode/plugins/c2c.ts`; only explicit resume/session clashes now fail.
  - Severity: important
