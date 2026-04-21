# Finding: live `send -> poll_inbox` broker proof is achieved with the running Codex participant

- A real Codex participant is running via `run-codex-inst-outer` with broker session id `codex-local` and broker alias `codex`.
- Broker registry confirms the broker-only peer is present in `.git/c2c/mcp/registry.json`.
- Local support slice for this path is green:
  - `python -m pytest tests/test_c2c_cli.py -k "sync_broker_registry or c2c_mcp_auto_drain_can_be_disabled_for_polling_clients or run_codex_inst"`
  - result: `6 passed`

## Live evidence

- Main session attempted `python c2c_send.py codex ...` and got `unknown alias: codex`.
- This is a limitation of `c2c_send.py`'s YAML/live-Claude resolution path, not of the broker path itself.
- Coordination requests were then sent directly to the live Claude peers asking them to use `mcp__c2c__send` to alias `codex`.
- `storm-beacon` later delivered this broker message into `codex-local.inbox.json`:

  - `{"from_alias":"storm-beacon","to_alias":"codex",...}`

- `storm-beacon` also reported an inotify-observed drain event on the Codex inbox file:

  - `codex-local.inbox.json went 236B->0B at 12:58:54 via inotify monitor`

- `storm-beacon` explicitly summarized that as:

  - `live send->poll proof achieved via running MCP`

## Interpretation

- The flag-independent receive path is now proven at the live broker/tool level:
  - live peer uses `mcp__c2c__send`
  - running Codex participant polls and drains via MCP
  - sender-side peer observes the drain and receives/records the acknowledgment

- The remaining gap is not `poll_inbox` implementation. The remaining gaps are:
  1. transcript-visible push delivery for Claude channel notifications
  2. convenience surfaces like `c2c_send.py`, which still target YAML/live-Claude routing rather than broker-only peers such as Codex

## Practical next step

- Treat the pull-based broker receive path as working for autonomous collaboration.
- If we want a cleaner operator UX, add or adjust a CLI/tool surface that can target broker-only peers directly instead of requiring an already-running live MCP peer to initiate the send.
