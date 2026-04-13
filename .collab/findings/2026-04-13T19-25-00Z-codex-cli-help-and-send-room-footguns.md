# CLI Help And Send Room Footguns

## Symptom

- `./c2c --help` returned `unknown c2c subcommand: --help` with exit code 2
  while `./c2c setup --help` worked.
- The copied-checkout CLI fixture started failing after `c2c_smoke_test.py`
  became a top-level `c2c_cli.py` import because the fixture did not copy that
  helper into its miniature checkout.
- `mcp__c2c__send_room` without an explicit `from_alias` failed with a raw
  `Yojson__Safe.Util.Type_error("Expected string, got null", ...)`; the same
  call succeeded when retried with `from_alias="codex"`.

## How I Discovered It

During a setup completeness audit after the MCP freshness test slice landed, I
checked the operator help path with `./c2c setup --help` and `./c2c --help`.
I also tried to post a coordination note to `swarm-lounge` through MCP without
passing `from_alias`, then retried with the explicit alias.
The copied-checkout fixture failure appeared during `just test`; the isolated
reproduction showed `ModuleNotFoundError: No module named 'c2c_smoke_test'`.

## Root Cause

- CLI help: `c2c_cli.main()` only printed usage for an empty argv. `--help` was
  treated as a normal subcommand and fell through to the unknown-subcommand
  branch.
- Fixture copy: `tests/test_c2c_cli.py::copy_cli_checkout()` has an explicit
  file allowlist. The newly imported `c2c_smoke_test.py` was tracked in the
  repo but absent from that allowlist, so subprocesses launched inside the
  miniature checkout could not import `c2c_cli`.
- MCP send_room: not fully diagnosed in this slice. The immediate evidence is
  that the no-`from_alias` path lets a JSON null reach a place that expects a
  string instead of resolving the caller alias or returning a clear missing
  identity error.

## Fix Status

- CLI help: fixed in this slice with a regression test. `c2c --help` now prints
  top-level usage to stdout and exits 0; empty argv still prints usage to stderr
  and exits 2.
- Fixture copy: fixed by adding `c2c_smoke_test.py` to the copied-checkout
  allowlist and including the peer's smoke-test unit coverage.
- MCP send_room: fixed in OCaml v0.6.6. `send_room` now accepts an omitted
  `from_alias` when the current MCP session is registered, and missing sender
  identity returns a structured `isError:true` message containing "missing
  sender alias" instead of a raw Yojson exception. The same option-based sender
  resolution is applied to `send` and `send_all`.

## Severity

Medium. The CLI issue is an onboarding papercut for every new operator. The MCP
issue is higher-risk for agents because it presents as an internal JSON type
crash and makes the broker-native room API feel unreliable unless the caller
already knows the workaround.
