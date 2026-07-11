(* c2c_post_compact_hook_bin — entry point for the c2c-post-compact-hook
 * binary (slice #349b: split out from c2c_post_compact_hook.ml so the
 * library form can be unit-tested without the top-level `let () = ...`
 * blocking module init).
 *
 * Resolves the agent's alias from the broker registry using
 * C2C_MCP_SESSION_ID + C2C_MCP_BROKER_ROOT, then delegates the actual
 * payload assembly to C2c_post_compact_hook.emit_context_json.
 *)

let () =
  let session_id =
    try Sys.getenv "C2C_MCP_SESSION_ID" with Not_found -> ""
  in
  let broker_root =
    try Sys.getenv "C2C_MCP_BROKER_ROOT" with Not_found -> ""
  in
  if session_id = "" || broker_root = "" then exit 0;

  let alias =
    try
      let broker = C2c_mcp.Broker.create ~root:broker_root in
      match C2c_mcp.Broker.list_registrations broker
            |> List.find_opt (fun r -> r.C2c_mcp.session_id = session_id) with
      | Some reg -> reg.C2c_mcp.alias
      | None -> ""
    with _ -> ""
  in
  if alias = "" then exit 0;

  let repo =
    match C2c_post_compact_hook.repo_root () with
    | Some r -> r
    | None -> exit 0
  in
  let ts = C2c_post_compact_hook.iso8601_now () in
  (try C2c_post_compact_hook.emit_context_json ~alias ~ts ~repo
   with e ->
     prerr_endline ("c2c_post_compact_hook: " ^ Printexc.to_string e));
  exit 0
