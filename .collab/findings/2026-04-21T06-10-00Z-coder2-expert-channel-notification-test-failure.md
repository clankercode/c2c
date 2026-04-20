# Finding: pre-existing test_full_session_lifecycle failure

**Session**: coder2-expert  
**Date**: 2026-04-21  
**Status**: Confirmed pre-existing (unrelated to canonical_alias or other 2026-04-21 changes)

## Symptom

`tests/test_c2c_mcp_channel_integration.py::TestE2ESessionLifecycle::test_full_session_lifecycle`
writes 2 messages to an inbox JSON file and expects 2 `notifications/claude/channel`
MCP notifications, but only receives 1 (the first message).

```
AssertionError: assert 1 == 2
# 1 notification received, expected 2
```

## How Discovered

`just test` (Python test suite) fails on this case. Confirmed pre-existing with `git stash`
— failure reproduces on clean HEAD with no working-tree changes.

## Root Cause (suspected, not confirmed)

The inbox watcher in `ocaml/server/c2c_mcp_server.ml` (`start_inbox_watcher`) polls every
1.0 second. It detects a file-size increase, drains all messages, then calls `emit_all`
sequentially:

```ocaml
let rec emit_all = function
  | [] -> Lwt.return_unit
  | msg :: rest ->
      let* () = emit_notification msg in
      emit_all rest
in
```

The test writes both messages at once (single atomic write), so both are present when the
watcher fires. `emit_all` calls `emit_notification` twice sequentially.

The test's `read_all_jsonrpc` function reads until a `select()` timeout:

```python
def read_all_jsonrpc(fd, timeout=0.5):
    messages = []
    while True:
        r, _, _ = select.select([fd], [], [], timeout)
        if not r:
            break
        line = fd.readline()
        if line:
            messages.append(json.loads(line))
    return messages
```

Likely cause: `emit_notification` writes to stdout via OCaml's buffered IO, but the
second write may not flush before the 0.5s select timeout expires in the test. The
first notification arrives and is consumed; the second is either still in the OCaml
stdio buffer or arrives after the timeout window closes.

**Alternative**: both notifications are emitted but JSON framing causes the second to
be parsed as part of the first (unlikely — they're line-delimited).

## Fix Status

Not fixed. This needs either:
1. An explicit `flush` after each `emit_notification` write, or
2. A longer timeout in `read_all_jsonrpc`, or  
3. A loop in the test that retries until N messages accumulate

Option 1 (flush in OCaml) is the cleanest — `emit_notification` should `flush stdout`
after each JSON-RPC write to avoid buffering races with the test reader.

Look for the write call in `c2c_mcp_server.ml` around `write_message` / `output_string`.

## Severity

Low — no production impact (real MCP clients use line-buffered stdio or async IO).
Test-only race. Does block `just test` from going green.

## Suggested Fix Location

`ocaml/server/c2c_mcp_server.ml` — after `output_string` / `Buffer.output_buffer` call
in `write_message` (or equivalent), add `flush stdout` / `Out_channel.flush stdout`.
