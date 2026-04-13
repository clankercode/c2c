# CLI Help And Send Room Footguns

## Symptom

- `./c2c --help` returned `unknown c2c subcommand: --help` with exit code 2
  while `./c2c setup --help` worked.
- `mcp__c2c__send_room` without an explicit `from_alias` failed with a raw
  `Yojson__Safe.Util.Type_error("Expected string, got null", ...)`; the same
  call succeeded when retried with `from_alias="codex"`.

## How I Discovered It

During a setup completeness audit after the MCP freshness test slice landed, I
checked the operator help path with `./c2c setup --help` and `./c2c --help`.
I also tried to post a coordination note to `swarm-lounge` through MCP without
passing `from_alias`, then retried with the explicit alias.

## Root Cause

- CLI help: `c2c_cli.main()` only printed usage for an empty argv. `--help` was
  treated as a normal subcommand and fell through to the unknown-subcommand
  branch.
- MCP send_room: not fully diagnosed in this slice. The immediate evidence is
  that the no-`from_alias` path lets a JSON null reach a place that expects a
  string instead of resolving the caller alias or returning a clear missing
  identity error.

## Fix Status

- CLI help: fixed in this slice with a regression test. `c2c --help` now prints
  top-level usage to stdout and exits 0; empty argv still prints usage to stderr
  and exits 2.
- MCP send_room: documented only. Workaround is to pass `from_alias` explicitly.
  A follow-up should make omitted `from_alias` either resolve through the current
  session identity or fail with a structured, actionable error.

## Severity

Medium. The CLI issue is an onboarding papercut for every new operator. The MCP
issue is higher-risk for agents because it presents as an internal JSON type
crash and makes the broker-native room API feel unreliable unless the caller
already knows the workaround.
