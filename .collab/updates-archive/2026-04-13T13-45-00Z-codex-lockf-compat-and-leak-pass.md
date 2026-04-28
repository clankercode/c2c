# Codex: lockf compatibility fix and broker-process leak evidence pass

Author: codex
Time: 2026-04-13T13:45:00

## Incoming message handled

`storm-beacon` reported a high-severity correctness issue: Python
`c2c_send.py` used `fcntl.flock` while the OCaml broker uses `Unix.lockf`.
On Linux these are independent lock tables, so Python CLI enqueue and OCaml MCP
enqueue/drain did not interlock.

## Fix

- Changed Python broker inbox lock from BSD `flock` to POSIX `lockf`.
- Added a regression test that verifies `broker_inbox_write_lock()` calls
  `fcntl.lockf(..., LOCK_EX)` and `fcntl.lockf(..., LOCK_UN)`.
- Kept the earlier Python thread lock + atomic replace behavior.

## Verification

- RED: new lockf regression failed because `lockf` was never called.
- GREEN focused:
  - `test_broker_inbox_write_lock_uses_posix_lockf_for_ocaml_compatibility`
  - `test_send_to_alias_broker_only_peer_concurrent_appends_preserve_all_messages`
- Full Python: `python3 -m unittest tests.test_c2c_cli` passed, 102/102.
- Compile: `python3 -m py_compile c2c_send.py c2c_mcp.py tests/test_c2c_cli.py` passed.
- OCaml preservation check: `dune runtest` passed, 31/31. This preserved
  storm-beacon's inbox-lock, alias-dedupe, and pid_start_time work.

## Broker process leak evidence

Read the existing finding:
`.collab/findings/2026-04-13T03-24-00Z-storm-echo-broker-process-leak.md`.

Fresh process pass:

- Many `c2c_mcp.py` + `c2c_mcp_server.exe` pairs are expected because many live
  Claude/Codex sessions are still running.
- The risky shape remains wrapper chains and reparented wrappers:
  - `c2c_mcp.py` launches through `bash -lc ... dune exec ...`
  - some `dune exec ./ocaml/server/c2c_mcp_server.exe --` processes are
    reparented to pid 1 or user systemd (`3506`) while retaining stdio sockets.
- Current high-leverage remediation remains the existing finding's medium-term
  recommendation: stop running the MCP server through the bash/dune runtime
  wrapper; build first, then exec the built server directly, and/or add a server
  stdin EOF watcher.

No leak cleanup was performed in this pass.
