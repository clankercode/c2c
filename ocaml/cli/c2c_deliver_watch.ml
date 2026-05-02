(* c2c_deliver_watch: CLI deliver --watch subcommand (#482 S6). *)

open Cmdliner.Term.Syntax

let ( // ) = Filename.concat

let xml_escape (s : string) : string =
  let b = Bytes.make (String.length s * 7) '\000' in
  let j = ref 0 in
  for i = 0 to String.length s - 1 do
    let c = s.[i] in
    match c with
    | '&' ->
        Bytes.blit_string "&amp;" 0 b !j 5; j := !j + 5
    | '<' ->
        Bytes.blit_string "&lt;" 0 b !j 4; j := !j + 4
    | '>' ->
        Bytes.blit_string "&gt;" 0 b !j 4; j := !j + 4
    | '"' ->
        Bytes.blit_string "&quot;" 0 b !j 6; j := !j + 6
    | '\'' ->
        Bytes.blit_string "&apos;" 0 b !j 6; j := !j + 6
    | _ ->
        Bytes.set b !j c; incr j
  done;
  Bytes.sub_string b 0 !j

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
    let messages =
      C2c_mcp.Broker.drain_inbox ~drained_by:"deliver-watch" broker ~session_id
    in
    total := !total + List.length messages;
    List.iter
      (fun (msg : C2c_mcp.message) ->
        match mode with
        | Stdout ->
            Printf.printf "[%s] %s\n%!" msg.from_alias msg.content;
            flush stdout
        | XmlFd fd ->
            let from_e = xml_escape msg.from_alias in
            let to_e   = xml_escape session_id in
            let body_e = xml_escape msg.content in
            let frame =
              Printf.sprintf
                "<message type=\"user\" queue=\"AfterAnyItem\"><c2c event=\"message\" from=\"%s\" to=\"%s\">%s</c2c></message>\n"
                from_e to_e body_e
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
  loop ();
  Printf.printf "[c2c-deliver-watch] stopped after %d iterations, %d total delivered\n%!"
    !iterations !total;
  flush stdout

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
