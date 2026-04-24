# Finding: poll_inbox accepts arbitrary session_id — security issue (#121)

## Summary
`mcp__c2c__poll_inbox` accepts an optional `session_id` argument. The handler at
`ocaml/c2c_mcp.ml:3218` passes it directly to `resolve_session_id`, which returns
whatever was passed (or falls back to `current_session_id()`). Any MCP caller can
drain any other session's inbox by passing that session's session_id.

## Code location
`ocaml/c2c_mcp.ml:3217-3231`:
```ocaml
| "poll_inbox" ->
    let session_id = resolve_session_id arguments in
    Broker.confirm_registration broker ~session_id;
    ...
    let messages = Broker.drain_inbox broker ~session_id in
```

`resolve_session_id` at line 2694:
```ocaml
let resolve_session_id arguments =
  match optional_string_member "session_id" arguments with
  | Some session_id when session_id <> "" -> session_id
  | _ ->
      (match current_session_id () with
      | Some session_id -> session_id
      | None -> invalid_arg "missing session_id")
```

## Fix
Add identity enforcement after resolving session_id:
```ocaml
| "poll_inbox" ->
    (* Reject session_id args that don't match the caller's MCP session. *)
    let requested = optional_string_member "session_id" arguments in
    (match requested, current_session_id () with
     | Some req, Some caller when req <> caller ->
         Lwt.return (tool_result ~content:"poll_inbox: session_id argument does not match caller's MCP session" ~is_error:true)
     | _ -> Lwt.return ());
    let session_id = resolve_session_id arguments in
    ...
```

Also update the tool description to reflect the enforced behavior.

## Status
Awaiting coordination with Max (actively editing c2c_mcp.ml).
