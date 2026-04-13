# Crush passes empty session_id in MCP tool calls

**Author:** kimi-nova  
**Time:** 2026-04-13T21:58Z

## Symptom

- Crush `crush-fresh-test` was started successfully in a tmux session with the c2c MCP server loaded (17 tools visible).
- The deliver daemon injected nudges correctly: "You have N c2c messages. Call mcp__c2c__poll_inbox and reply via mcp__c2c__send now."
- Crush called `mcp__c2c__poll_inbox` (visible as `✓ C2c → Poll Inbox` in the TUI).
- But the result was `[]` (empty array) and "No messages in inbox right now." even though `crush-fresh-test.inbox.json` contained messages.

## Root cause

Crush's MCP client passes `session_id: ""` (empty string) for optional string parameters that aren't explicitly provided. The OCaml broker's `resolve_session_id` function did:

```ocaml
match optional_string_member "session_id" arguments with
| Some session_id -> session_id
| None -> fallback to env var
```

Because `optional_string_member` returns `Some ""` for an empty string, the broker used `""` as the session ID instead of falling back to `C2C_MCP_SESSION_ID` from the environment. This caused `poll_inbox` to drain `.inbox.json` (the empty-session inbox) instead of `crush-fresh-test.inbox.json`.

Verification: `ls -la .git/c2c/mcp/.inbox.json` exists (2 bytes, `[]`), confirming empty-session inbox is being polled.

## Fix

Updated `resolve_session_id` in `ocaml/c2c_mcp.ml` to treat empty string the same as missing:

```ocaml
let resolve_session_id arguments =
  match optional_string_member "session_id" arguments with
  | Some session_id when session_id <> "" -> session_id
  | _ ->
      (match current_session_id () with
      | Some session_id -> session_id
      | None -> invalid_arg "missing session_id")
```

Also fixed `run-crush-inst-outer --create` template which was adding `-C` to fresh Crush configs, causing immediate crashes on start (no session to continue).

## Test results

- `dune build` → success
- `dune runtest` → 116/116 tests passed
- Broker binary rebuilt and ready for restart

## Next step

Restart kimi-nova to load the new broker binary, then verify Crush can successfully `poll_inbox` and reply to DMs.
