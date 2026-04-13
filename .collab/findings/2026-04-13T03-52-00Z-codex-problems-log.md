# Codex Problems Log - MCP Startup Recovery Slice

## Host MCP tool missing during resume

- Symptom: the resume prompt instructed Codex to call `mcp__c2c__poll_inbox`, but this session did not expose any `mcp__c2c__*` tools after startup.
- Discovery: the heartbeat arrived, but only local shell/GitHub/patent tools were available. A direct `python3 c2c_mcp.py` JSON-RPC call still worked.
- Root cause: host-level MCP startup/tool exposure can fail independently of the repo implementation. Codex still needs a local fallback that does not rely on the host exposing the MCP tool namespace.
- Fix status: added `c2c-poll-inbox` / `c2c_poll_inbox.py`, which can poll through direct JSON-RPC and can drain the broker inbox directly under a POSIX `lockf` sidecar when the MCP server path is unavailable.
- Severity: high for autonomous recovery, because a missing MCP namespace otherwise prevents Codex from seeing broker messages after restart.

## Python broker lock sidecar did not match OCaml

- Symptom: Python broker sends used POSIX `lockf`, but the sidecar path was `<sid>.inbox.json.lock` while OCaml uses `<sid>.inbox.lock`.
- Discovery: implementing direct file fallback surfaced existing live sidecars named `codex-local.inbox.lock`, while `c2c_send.broker_inbox_write_lock()` would create `codex-local.inbox.json.lock`.
- Root cause: the previous Python fix switched from BSD `flock` to POSIX `lockf` but left the wrong sidecar filename. POSIX locks only interlock when processes open the same inode.
- Fix status: updated `c2c_send.py` to derive `<sid>.inbox.lock` for broker inboxes and added a regression test.
- Severity: high for cross-language race safety; without this, Python and OCaml can still perform concurrent read-modify-write on the same inbox.
