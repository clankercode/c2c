(* c2c_history_cmd - history command assembly.
   Extracted from c2c.ml as part of the architecture refactoring. *)

open Cmdliner.Term.Syntax
open C2c_cli_helpers
open C2c_types

let history_cmd =
  let limit =
    Cmdliner.Arg.(value & opt int 50 & info [ "limit"; "l" ] ~docv:"N" ~doc:"Max messages to return.")
  in
  let session_id_flag =
    Cmdliner.Arg.(value & opt (some string) None & info [ "session-id"; "s" ] ~docv:"ID"
      ~doc:"Session ID to read archive for. Overrides C2C_MCP_SESSION_ID.")
  in
  let no_headers_flag =
    Cmdliner.Arg.(value & flag & info [ "no-headers" ]
      ~doc:"Suppress per-message header lines (timestamp + from -> to). \
            Default emits a header before each body so messages are \
            distinguishable; pass this to restore the legacy bare-body \
            output for grep-friendly scripts. Has no effect with --json.")
  in
  let alias_flag =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias"; "a" ] ~docv:"ALIAS"
      ~doc:"Look up session ID by alias and read that session's archive. \
Mutually exclusive with --session-id.")
  in
  let+ json = json_flag
  and+ limit = limit
  and+ session_id_opt = session_id_flag
  and+ no_headers = no_headers_flag
  and+ alias_opt = alias_flag in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let session_id =
    match session_id_opt, alias_opt with
    | Some _, Some _ ->
        Printf.eprintf "error: --session-id and --alias are mutually exclusive.\n%!";
        exit 1
    | Some sid, None -> sid
    | None, Some alias ->
        let regs = C2c_mcp.Broker.list_registrations broker in
        let matches = List.filter (fun (r : C2c_mcp.registration) -> r.alias = alias) regs in
        (match matches with
         | [] ->
             Printf.eprintf "error: alias '%s' not found in registry.\n%!" alias;
             exit 1
         | [ r ] -> r.session_id
         | _ ->
             Printf.eprintf "error: alias '%s' matches multiple sessions.\n%!" alias;
             exit 1)
    | None, None -> resolve_session_id_for_inbox broker
  in
  let entries = C2c_mcp.Broker.read_archive broker ~session_id ~limit in
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      print_json
        (`List
          (List.map
             (fun (e : C2c_mcp.Broker.archive_entry) ->
               `Assoc
                 [ ("drained_at", `Float e.ae_drained_at)
                 ; ("from_alias", `String e.ae_from_alias)
                 ; ("to_alias", `String e.ae_to_alias)
                 ; ("content", `String e.ae_content)
                 ])
             entries))
  | Human ->
      let headers = not no_headers in
      List.iter print_endline (C2c_history.format_human ~headers entries)

let history : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "history" ~doc:"Show archived inbox messages.")
    history_cmd
