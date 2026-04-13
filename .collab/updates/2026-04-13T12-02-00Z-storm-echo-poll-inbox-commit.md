# storm-echo: committing poll_inbox + releasing ocaml locks

**Session:** c2c-r2-b1 (storm-echo, session_id `c78d64e9-1c7d-413f-8440-6ab33e0bf8fe`)
**Time:** 2026-04-13T12:02:00Z
**Audience:** storm-beacon (c2c-r2-b2), main coordinating session, Max

## What I'm committing (scope-limited)

Two OCaml files only — no other source changes sneak in:

- `ocaml/c2c_mcp.ml`
  - Updated `instructions` string: documents `poll_inbox` as the flag-independent
    pull path; notes that `notifications/claude/channel` is still emitted for
    clients launched with `--dangerously-load-development-channels server:c2c`.
  - Added `poll_inbox` to `tool_definitions`.
  - Added `| "poll_inbox" ->` handler: resolves `session_id` from the MCP env,
    drains via `Broker.drain_inbox`, and returns JSON-serialized messages
    through `tool_result`.
- `ocaml/test/test_c2c_mcp.ml`
  - Picks up storm-beacon's pre-existing rename fix
    (`test_initialize_echoes_requested_protocol_version` →
    `test_initialize_reports_supported_protocol_version`) that was left in
    the working tree from the 01:47Z build-fix.
  - Adds `test_tools_call_poll_inbox_drains_messages_as_tool_result`:
    registers two sessions, enqueues two messages, invokes `tools/call`
    `poll_inbox`, asserts parsed JSON and that the inbox is drained.
  - Adds `test_tools_call_poll_inbox_empty_inbox_returns_empty_json_array`.
  - Updates the `tools/list` expected-names assertion to include
    `poll_inbox`.
  - Registers both new tests in the runner.

Test status (already verified by the main session at 02:15Z):
`dune exec --root /home/xertrov/src/c2c-msg ./ocaml/test/test_c2c_mcp.exe`
→ `14 tests run, Test Successful`.

## What I'm NOT touching

- `ocaml/c2c_mcp.mli` — `type message` is already exposed; poll_inbox handler
  constructs JSON inline, no new helpers.
- `ocaml/server/c2c_mcp_server.ml` — keeping the drain/emit loop intact so
  that future flag-enabled clients still get push-channel delivery.
- `c2c_mcp.py`, `tests/test_c2c_cli.py`, `CLAUDE.md` — those belong to the
  main session's broker-registry preservation track; leaving them staged
  in the working tree.

## Lock release

Immediately after the commit lands I will remove both `storm-echo` rows
from the Active locks table in `tmp_collab_lock.md` and add a History line.

## Also included in this work cycle (separate commit)

At Max's explicit request I created a small launcher harness so models can
adjust their own launch flags between runs:

- `run-claude-inst-outer` — Python outer loop (exec-style, fresh inner each
  iteration so in-flight edits are safe).
- `run-claude-inst` — Python inner that reads
  `run-claude-inst.d/<name>.json`, sets the terminal title, and
  `os.execvpe`s the configured `claude` command.
- `run-claude-inst.d/c2c-r2-b1.json` and
  `run-claude-inst.d/c2c-r2-b2.json` — seed configs with
  `--dangerously-skip-permissions` + `--dangerously-load-development-channels
  server:c2c` so the next relaunch actually surfaces
  `notifications/claude/channel`.

That goes in its own commit so the OCaml change stays tidy.
