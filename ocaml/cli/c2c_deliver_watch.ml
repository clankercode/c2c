(* c2c_deliver_watch: CLI deliver --watch subcommand (#482 S6).

   P4: also drains the global sessions broker
   (C2C_SESSIONS_BROKER_ROOT / resolve_sessions_broker_root) alongside the
   per-repo broker, so messages sent via `c2c send --session <id>` reach
   codex/opencode sessions too. *)

open Cmdliner.Term.Syntax

let ( // ) = Filename.concat

(* xml_escape sourced from C2c_mcp (c2c_mcp_helpers.ml) — canonical def *)

type output_mode =
  | Stdout
  | XmlFd of Unix.file_descr
  | Null

let default_broker_root () : string =
  match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
  | Some b -> b
  | None ->
      let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
      home // ".c2c" // "repos" // "default" // "broker"

(* P4: Check if a global session inbox exists for the given session_id. *)
let global_inbox_exists ~root ~session_id =
  Sys.file_exists (Filename.concat root (session_id ^ ".inbox.json"))

(* P4: Drain messages from the global sessions broker.
   Returns [] if no global inbox exists. *)
let drain_global_messages ~session_id =
  if not (C2c_name.is_valid session_id) then []
  else
  let root = C2c_repo_fp.resolve_sessions_broker_root () in
  if global_inbox_exists ~root ~session_id then
    let broker = C2c_mcp.Broker.create ~root in
    C2c_mcp.Broker.drain_inbox ~drained_by:"deliver-watch-global" broker ~session_id
  else []

let watch_loop
    ~(broker_root : string)
    ~(session_id : string)
    ~(interval : float)
    (mode : output_mode) : unit =
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let iterations = ref 0 in
  let total = ref 0 in
  let rec loop () =
    incr iterations;
    let repo_messages =
      C2c_mcp.Broker.drain_inbox ~drained_by:"deliver-watch" broker ~session_id
    in
    let global_messages = drain_global_messages ~session_id in
    let messages = repo_messages @ global_messages in
    total := !total + List.length messages;
    (if List.length repo_messages > 0 then
       C2c_deliver_inbox_log.log_drain
         ~broker_root
         ~session_id
         ~client:"deliver-watch"
         ~count:(List.length repo_messages)
         ~drained_by_pid:(Unix.getpid ()));
    (if List.length global_messages > 0 then
       C2c_deliver_inbox_log.log_drain
         ~broker_root:(C2c_repo_fp.resolve_sessions_broker_root ())
         ~session_id
         ~client:"deliver-watch-global"
         ~count:(List.length global_messages)
         ~drained_by_pid:(Unix.getpid ()));
    List.iter
      (fun (msg : C2c_mcp.message) ->
        match mode with
        | Stdout ->
            Printf.printf "[%s] %s\n%!" msg.from_alias msg.content;
            flush stdout
        | XmlFd fd ->
            let tag = C2c_mcp.extract_tag_from_content msg.content in
            let envelope =
              C2c_mcp.format_c2c_envelope
                ~from_alias:msg.from_alias
                ~to_alias:msg.to_alias
                ?tag
                ?reply_via:msg.reply_via
                ~with_reply_hint:true
                ~content:msg.content
                ()
            in
            let frame =
              Printf.sprintf
                "<message type=\"user\" queue=\"AfterAnyItem\">%s</message>\n"
                envelope
            in
            let oc = Unix.out_channel_of_descr fd in
            (try output_string oc frame; flush oc
             with exn ->
               Printf.eprintf "[c2c-deliver-watch] xml write failed: %s\n%!"
                 (Printexc.to_string exn))
        | Null -> ()
      ) messages;
    (if List.length messages > 0 then
       Printf.printf "[c2c-deliver-watch] iteration %d: %d message(s)\n%!"
         !iterations (List.length messages)
     else
       Printf.printf "[c2c-deliver-watch] iteration %d: no messages\n%!"
         !iterations);
    flush stdout;
    ignore (Unix.select [] [] [] interval);
    loop ()
  in
  loop ()  (* unreachable: loop recurses forever; next lines are dead code *)

open Cmdliner

let deliver_watch_cmd =
  let session_id_flag =
    Arg.(required & opt (some string) None
         & info ["session-id"] ~docv:"ID"
         ~doc:"Broker session ID to deliver (required).")
  in
  let broker_root_flag =
    Arg.(value & opt (some string) None
         & info ["broker-root"] ~docv:"DIR"
         ~doc:"Broker root directory.")
  in
  let interval_flag =
    Arg.(value & opt (some float) (Some 1.0)
         & info ["interval"] ~docv:"SECS"
         ~doc:"Polling interval in seconds (default: 1.0).")
  in
  let xml_fd_flag =
    Arg.(value & opt (some int) None
         & info ["xml-fd"] ~docv:"N"
         ~doc:"Write XML frames to this fd.")
  in
  let man = [
    `S "DESCRIPTION";
    `P "c2c deliver --watch polls the broker inbox continuously.";
    `S "OUTPUT MODES";
    `P "Default: one line per message: [from_alias] body";
    `P "--xml-fd N: XML frames matching Codex --xml-input-fd contract.";
  ] in
  let info = Cmdliner.Cmd.info "watch" ~doc:"Watch mode" ~man in
  let term =
    let+ () = Cmdliner.Term.const ()
    and+ session_id = session_id_flag
    and+ broker_root_opt = broker_root_flag
    and+ interval_opt = interval_flag
    and+ xml_fd_opt = xml_fd_flag
    in
    let broker_root =
      match broker_root_opt with
      | Some b when String.trim b <> "" -> String.trim b
      | _ -> default_broker_root ()
    in
    let mode =
      match xml_fd_opt with
      | Some fd ->
          let fd_obj : Unix.file_descr = Obj.magic fd in
          XmlFd fd_obj
      | None -> Stdout
    in
    let interval = match interval_opt with Some f -> f | None -> 1.0 in
    watch_loop ~broker_root ~session_id ~interval mode
  in
  Cmdliner.Cmd.v info term

let deliver_group =
  Cmdliner.Cmd.group
    (Cmdliner.Cmd.info "deliver" ~doc:"Message delivery commands.")
    [ deliver_watch_cmd ]
