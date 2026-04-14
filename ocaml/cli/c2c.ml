(* c2c CLI — human-friendly command-line interface to the c2c broker.
   When invoked with no arguments, shows help.
   Otherwise dispatches to CLI subcommands. *)

let ( // ) = Filename.concat
open Cmdliner.Term.Syntax

(* --- broker root resolution ------------------------------------------------ *)

let broker_root_from_env () =
  match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
  | Some path when String.trim path <> "" -> Some path
  | _ -> None

let git_common_dir () =
  match
    Unix.open_process_in "git rev-parse --git-common-dir 2>/dev/null"
  with
  | ic ->
      let line =
        try
          let l = input_line ic in
          ignore (Unix.close_process_in ic);
          String.trim l
        with End_of_file ->
          ignore (Unix.close_process_in ic);
          ""
      in
      if line <> "" && Sys.is_directory line then Some line else None

let resolve_broker_root () =
  match broker_root_from_env () with
  | Some dir -> dir
  | None -> (
      match git_common_dir () with
      | Some git_dir ->
          let dir = git_dir // "c2c" // "mcp" in
          if Sys.is_directory dir then dir
          else (
            (try
               let parent = git_dir // "c2c" in
               if not (Sys.file_exists parent) then Unix.mkdir parent 0o755;
               Unix.mkdir dir 0o755
             with Unix.Unix_error _ -> ());
            dir)
      | None ->
          Printf.eprintf
            "error: cannot find broker root. Set C2C_MCP_BROKER_ROOT or run \
             from inside a git repo.\n%!";
          exit 1)

(* --- session / alias resolution ------------------------------------------- *)

let env_session_id () =
  match Sys.getenv_opt "C2C_MCP_SESSION_ID" with
  | Some v when String.trim v <> "" -> Some (String.trim v)
  | _ -> None

let env_auto_alias () =
  match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
  | Some v when String.trim v <> "" -> Some (String.trim v)
  | _ -> None

let resolve_alias broker =
  match env_session_id () with
  | None -> (
      match env_auto_alias () with
      | Some a -> a
      | None ->
          Printf.eprintf
            "error: cannot determine your alias. Set C2C_MCP_AUTO_REGISTER_ALIAS \
             or C2C_MCP_SESSION_ID.\n%!";
          exit 1)
  | Some sid ->
      let regs = C2c_mcp.Broker.list_registrations broker in
      (match
         List.find_opt
           (fun (r : C2c_mcp.registration) -> r.session_id = sid)
           regs
       with
      | Some r -> r.alias
      | None -> (
          match env_auto_alias () with
          | Some a -> a
          | None ->
              Printf.eprintf
                "error: session %s is not registered and no alias is set.\n%!"
                sid;
              exit 1))

let resolve_session_id () =
  match env_session_id () with
  | Some sid -> sid
  | None ->
      Printf.eprintf
        "error: cannot determine session ID. Set C2C_MCP_SESSION_ID.\n%!";
      exit 1

(* --- output helpers -------------------------------------------------------- *)

type output_mode = Human | Json

let json_flag =
  Cmdliner.Arg.(value & flag & info [ "json"; "j" ] ~doc:"Output machine-readable JSON.")

let print_json json =
  Yojson.Safe.pretty_to_channel stdout json;
  print_newline ()

(* --- subcommand: send ----------------------------------------------------- *)

let send_cmd =
  let to_alias =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ALIAS" ~doc:"Recipient alias.")
  in
  let message =
    Cmdliner.Arg.(non_empty & pos_right 0 string [] & info [] ~docv:"MSG" ~doc:"Message body (remaining args joined with spaces).")
  in
  let+ json = json_flag
  and+ to_alias = to_alias
  and+ message = message in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let from_alias = resolve_alias broker in
  let content = String.concat " " message in
  let output_mode = if json then Json else Human in
  (try
     C2c_mcp.Broker.enqueue_message broker ~from_alias ~to_alias ~content;
     let ts = Unix.gettimeofday () in
     match output_mode with
     | Json ->
         print_json
           (`Assoc
             [ ("queued", `Bool true)
             ; ("ts", `Float ts)
             ; ("from_alias", `String from_alias)
             ; ("to_alias", `String to_alias)
             ])
     | Human ->
         Printf.printf "ok -> %s (from %s)\n" to_alias from_alias
   with Invalid_argument msg ->
     Printf.eprintf "error: %s\n%!" msg;
     exit 1)

(* --- subcommand: list ----------------------------------------------------- *)

let list_cmd =
  let all =
    Cmdliner.Arg.(value & flag & info [ "all"; "a" ] ~doc:"Show extended info (session ID, registered time).")
  in
  let+ json = json_flag
  and+ all = all in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let regs = C2c_mcp.Broker.list_registrations broker in
  let output_mode = if json then Json else Human in
  if regs = [] then (
    match output_mode with
    | Json -> print_json (`List [])
    | Human -> Printf.printf "No registered peers.\n")
  else
    match output_mode with
    | Json ->
        let json_regs =
          List.map
            (fun (r : C2c_mcp.registration) ->
              let base : (string * Yojson.Safe.t) list =
                [ ("session_id", `String r.session_id)
                ; ("alias", `String r.alias)
                ]
              in
              let with_pid =
                match r.pid with
                | Some n -> base @ [ ("pid", `Int n) ]
                | None -> base
              in
              let alive_val : Yojson.Safe.t =
                match C2c_mcp.Broker.registration_liveness_state r with
                | C2c_mcp.Broker.Alive -> `Bool true
                | C2c_mcp.Broker.Dead -> `Bool false
                | C2c_mcp.Broker.Unknown -> `Null
              in
              let with_alive = with_pid @ [ ("alive", alive_val) ] in
              let fields =
                match r.registered_at with
                | Some ts -> with_alive @ [ ("registered_at", `Float ts) ]
                | None -> with_alive
              in
              `Assoc fields)
            regs
        in
        print_json (`List json_regs)
    | Human ->
        List.iter
          (fun (r : C2c_mcp.registration) ->
            let alive_str =
              match C2c_mcp.Broker.registration_liveness_state r with
              | C2c_mcp.Broker.Alive -> "alive"
              | C2c_mcp.Broker.Dead -> "dead "
              | C2c_mcp.Broker.Unknown -> "???  "
            in
            let pid_str =
              match r.pid with
              | Some p -> Printf.sprintf " pid=%d" p
              | None -> ""
            in
            if all then
              let session_short =
                let s = r.session_id in
                if String.length s > 12 then String.sub s 0 12 ^ "..." else s
              in
              let time_str =
                match r.registered_at with
                | None -> ""
                | Some ts ->
                    let t = Unix.gmtime ts in
                    Printf.sprintf " %04d-%02d-%02d %02d:%02d"
                      (1900 + t.tm_year) (1 + t.tm_mon) t.tm_mday t.tm_hour t.tm_min
              in
              Printf.printf "  %-20s %s%s  %s%s\n" r.alias alive_str pid_str session_short time_str
            else
              Printf.printf "  %-20s %s%s\n" r.alias alive_str pid_str)
          regs

(* --- subcommand: whoami --------------------------------------------------- *)

let whoami_cmd =
  let+ json = json_flag in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let output_mode = if json then Json else Human in
  match env_session_id () with
  | None ->
      Printf.eprintf "error: no session ID. Set C2C_MCP_SESSION_ID.\n%!";
      exit 1
  | Some sid ->
      let alias =
        List.find_opt
          (fun (r : C2c_mcp.registration) -> r.session_id = sid)
          (C2c_mcp.Broker.list_registrations broker)
        |> Option.map (fun (r : C2c_mcp.registration) -> r.alias)
      in
      match output_mode with
      | Json ->
          print_json
            (`Assoc
              [ ("session_id", `String sid)
              ; ("alias", `String (Option.value alias ~default:""))
              ])
      | Human ->
          Printf.printf "alias:     %s\nsession_id: %s\n"
            (Option.value alias ~default:"(not registered)")
            sid

(* --- subcommand: poll-inbox ----------------------------------------------- *)

let poll_inbox_cmd =
  let peek =
    Cmdliner.Arg.(value & flag & info [ "peek"; "p" ] ~doc:"Peek without draining.")
  in
  let+ json = json_flag
  and+ peek = peek in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let session_id = resolve_session_id () in
  let messages =
    if peek then
      C2c_mcp.Broker.read_inbox broker ~session_id
    else
      C2c_mcp.Broker.drain_inbox broker ~session_id
  in
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      print_json
        (`List
          (List.map
             (fun (m : C2c_mcp.message) ->
               `Assoc
                 [ ("from_alias", `String m.from_alias)
                 ; ("to_alias", `String m.to_alias)
                 ; ("content", `String m.content)
                 ])
             messages))
  | Human ->
      if messages = [] then
        Printf.printf "(no messages)\n"
      else
        List.iter
          (fun (m : C2c_mcp.message) -> Printf.printf "[%s] %s\n" m.from_alias m.content)
          messages

(* --- subcommand: send-all ------------------------------------------------- *)

let send_all_cmd =
  let message =
    Cmdliner.Arg.(non_empty & pos_all string [] & info [] ~docv:"MSG" ~doc:"Message body.")
  in
  let exclude =
    Cmdliner.Arg.(value & opt (list string) [] & info [ "exclude"; "x" ] ~docv:"ALIAS" ~doc:"Aliases to skip.")
  in
  let+ json = json_flag
  and+ exclude = exclude
  and+ message = message in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let from_alias = resolve_alias broker in
  let content = String.concat " " message in
  let result =
    C2c_mcp.Broker.send_all broker ~from_alias ~content ~exclude_aliases:exclude
  in
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      print_json
        (`Assoc
          [ ( "sent_to",
              `List (List.map (fun a -> `String a) result.sent_to) )
          ; ( "skipped",
              `List
                (List.map
                   (fun (a, r) ->
                     `Assoc [ ("alias", `String a); ("reason", `String r) ])
                   result.skipped) )
          ])
  | Human ->
      Printf.printf "Sent to: %s\n"
        (match result.sent_to with [] -> "(none)" | l -> String.concat ", " l);
      if result.skipped <> [] then
        List.iter
          (fun (a, r) -> Printf.printf "  skipped %s (%s)\n" a r)
          result.skipped

(* --- subcommand: sweep ---------------------------------------------------- *)

let sweep_cmd =
  let+ json = json_flag in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let result = C2c_mcp.Broker.sweep broker in
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      print_json
        (`Assoc
          [ ( "dropped_regs",
              `List
                (List.map
                   (fun (r : C2c_mcp.registration) ->
                     `Assoc
                       [ ("session_id", `String r.session_id)
                       ; ("alias", `String r.alias)
                       ])
                   result.dropped_regs) )
          ; ( "deleted_inboxes",
              `List (List.map (fun s -> `String s) result.deleted_inboxes) )
          ; ("preserved_messages", `Int result.preserved_messages)
          ])
  | Human ->
      Printf.printf "Dropped %d registrations, %d inboxes, %d messages preserved.\n"
        (List.length result.dropped_regs)
        (List.length result.deleted_inboxes)
        result.preserved_messages;
      List.iter
        (fun (r : C2c_mcp.registration) -> Printf.printf "  dropped: %s (%s)\n" r.alias r.session_id)
        result.dropped_regs

(* --- subcommand: history -------------------------------------------------- *)

let history_cmd =
  let limit =
    Cmdliner.Arg.(value & opt int 50 & info [ "limit"; "l" ] ~docv:"N" ~doc:"Max messages to return.")
  in
  let+ json = json_flag
  and+ limit = limit in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let session_id = resolve_session_id () in
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
      if entries = [] then
        Printf.printf "(no history)\n"
      else
        List.iter
          (fun (e : C2c_mcp.Broker.archive_entry) ->
            let time =
              let t = Unix.gmtime e.ae_drained_at in
              Printf.sprintf "%04d-%02d-%02d %02d:%02d"
                (1900 + t.tm_year) (1 + t.tm_mon) t.tm_mday t.tm_hour t.tm_min
            in
            Printf.printf "[%s] <%s> %s\n" time e.ae_from_alias e.ae_content)
          entries

(* --- subcommand: health --------------------------------------------------- *)

let health_cmd =
  let+ json = json_flag in
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in
  let root_exists = Sys.is_directory root in
  let registry_exists = Sys.file_exists (root // "registry.json") in
  let dead_letter_exists =
    Sys.file_exists (C2c_mcp.Broker.dead_letter_path broker)
  in
  let regs = C2c_mcp.Broker.list_registrations broker in
  let alive_count =
    List.filter C2c_mcp.Broker.registration_is_alive regs |> List.length
  in
  let rooms = C2c_mcp.Broker.list_rooms broker in
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      print_json
        (`Assoc
          [ ("broker_root", `String root)
          ; ("root_exists", `Bool root_exists)
          ; ("registry_exists", `Bool registry_exists)
          ; ("dead_letter_exists", `Bool dead_letter_exists)
          ; ("registrations", `Int (List.length regs))
          ; ("alive", `Int alive_count)
          ; ("rooms", `Int (List.length rooms))
          ])
  | Human ->
      Printf.printf "broker root:    %s\n" root;
      Printf.printf "root exists:    %s\n" (string_of_bool root_exists);
      Printf.printf "registry:       %s\n" (string_of_bool registry_exists);
      Printf.printf "dead-letter:    %s\n" (string_of_bool dead_letter_exists);
      Printf.printf "registrations:  %d (%d alive)\n"
        (List.length regs) alive_count;
      Printf.printf "rooms:          %d\n" (List.length rooms)

(* --- subcommand: register ------------------------------------------------- *)

let register_cmd =
  let alias =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias"; "a" ] ~docv:"ALIAS" ~doc:"Alias to register (default: C2C_MCP_AUTO_REGISTER_ALIAS).")
  in
  let session_id_opt =
    Cmdliner.Arg.(value & opt (some string) None & info [ "session-id"; "s" ] ~docv:"ID" ~doc:"Session ID (default: C2C_MCP_SESSION_ID).")
  in
  let+ json = json_flag
  and+ alias_opt = alias
  and+ session_id_opt = session_id_opt in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let alias =
    match alias_opt with
    | Some a -> a
    | None -> (
        match env_auto_alias () with
        | Some a -> a
        | None ->
            Printf.eprintf "error: no alias specified and C2C_MCP_AUTO_REGISTER_ALIAS not set.\n%!";
            exit 1)
  in
  let session_id =
    match session_id_opt with
    | Some s -> s
    | None -> (
        match env_session_id () with
        | Some s -> s
        | None ->
            Printf.eprintf "error: no session ID specified and C2C_MCP_SESSION_ID not set.\n%!";
            exit 1)
  in
  let pid = Some (Unix.getppid ()) in
  let pid_start_time = C2c_mcp.Broker.capture_pid_start_time pid in
  C2c_mcp.Broker.register broker ~session_id ~alias ~pid ~pid_start_time;
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      print_json
        (`Assoc
          [ ("alias", `String alias)
          ; ("session_id", `String session_id)
          ])
  | Human ->
      Printf.printf "registered %s (session %s)\n" alias session_id

(* --- subcommand: tail-log ------------------------------------------------ *)

let tail_log_cmd =
  let limit =
    Cmdliner.Arg.(value & opt int 50 & info [ "limit"; "l" ] ~docv:"N" ~doc:"Max log entries (default 50, max 500).")
  in
  let+ json = json_flag
  and+ limit = limit in
  let limit = min (max limit 1) 500 in
  let root = resolve_broker_root () in
  let log_path = root // "broker.log" in
  let output_mode = if json then Json else Human in
  if not (Sys.file_exists log_path) then (
    match output_mode with
    | Json -> print_json (`List [])
    | Human -> Printf.printf "(no log)\n")
  else
    let lines =
      let ic = open_in log_path in
      Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
        let buf = Buffer.create 4096 in
        (try while true do
             let line = String.trim (input_line ic) in
             if line <> "" then begin
               Buffer.add_string buf line;
               Buffer.add_char buf '\n'
             end
           done with End_of_file -> ());
        String.split_on_char '\n' (Buffer.contents buf)
        |> List.filter (fun s -> String.trim s <> ""))
    in
    let n = List.length lines in
    let tail =
      if n <= limit then lines
      else
        let drop = n - limit in
        let rec skip i = function
          | [] -> []
          | _ :: rest when i > 0 -> skip (i - 1) rest
          | lst -> lst
        in
        skip drop lines
    in
    let parsed =
      List.filter_map
        (fun line ->
          try Some (Yojson.Safe.from_string line)
          with _ -> None)
        tail
    in
    match output_mode with
    | Json -> print_json (`List parsed)
    | Human -> List.iter (fun line -> print_endline line) tail

(* --- subcommand: my-rooms ---------------------------------------------- *)

let my_rooms_cmd =
  let+ json = json_flag in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let session_id = resolve_session_id () in
  let rooms = C2c_mcp.Broker.my_rooms broker ~session_id in
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      print_json
        (`List
          (List.map
             (fun (r : C2c_mcp.Broker.room_info) ->
               `Assoc
                 [ ("room_id", `String r.ri_room_id)
                 ; ("member_count", `Int r.ri_member_count)
                 ; ("members",
                     `List (List.map (fun a -> `String a) r.ri_members))
                 ; ( "visibility",
                     `String
                       (match r.ri_visibility with
                       | C2c_mcp.Public -> "public"
                       | C2c_mcp.Invite_only -> "invite_only"))
                 ])
             rooms))
  | Human ->
      if rooms = [] then
        Printf.printf "Not in any rooms.\n"
      else
        List.iter
          (fun (r : C2c_mcp.Broker.room_info) ->
            Printf.printf "%s (%d members)\n" r.ri_room_id r.ri_member_count)
          rooms

(* --- subcommand: dead-letter ---------------------------------------------- *)

let dead_letter_cmd =
  let limit =
    Cmdliner.Arg.(value & opt int 50 & info [ "limit"; "l" ] ~docv:"N" ~doc:"Max entries to return.")
  in
  let+ json = json_flag
  and+ limit = limit in
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in
  let path = C2c_mcp.Broker.dead_letter_path broker in
  let output_mode = if json then Json else Human in
  if not (Sys.file_exists path) then (
    match output_mode with
    | Json -> print_json (`List [])
    | Human -> Printf.printf "(no dead-letter file)\n")
  else
    let ic = open_in path in
    let entries =
      Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
        let buf = Buffer.create 4096 in
        (try while true do
             let line = input_line ic in
             Buffer.add_string buf line;
             Buffer.add_char buf '\n'
           done with End_of_file -> ());
        let content = Buffer.contents buf in
        if String.trim content = "" then []
        else
          String.split_on_char '\n' content
          |> List.filter (fun s -> String.trim s <> "")
          |> List.filter_map
               (fun line ->
                 try Some (Yojson.Safe.from_string line)
                 with _ -> None))
    in
    let n = List.length entries in
    let entries =
      if n <= limit then entries
      else
        let drop = n - limit in
        let rec skip i = function
          | [] -> []
          | _ :: rest when i > 0 -> skip (i - 1) rest
          | lst -> lst
        in
        skip drop entries
    in
    match output_mode with
    | Json -> print_json (`List entries)
    | Human ->
        if entries = [] then
          Printf.printf "(empty)\n"
        else
          List.iter (fun j -> print_endline (Yojson.Safe.pretty_to_string j)) entries

(* --- subcommand: prune-rooms ---------------------------------------------- *)

let prune_rooms_cmd =
  let+ json = json_flag in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let evicted = C2c_mcp.Broker.prune_rooms broker in
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      print_json
        (`List
          (List.map
             (fun (room_id, alias) ->
               `Assoc [ ("room_id", `String room_id); ("alias", `String alias) ])
             evicted))
  | Human ->
      if evicted = [] then
        Printf.printf "No dead members to evict.\n"
      else
        (Printf.printf "Evicted %d dead members:\n" (List.length evicted);
         List.iter
           (fun (room_id, alias) ->
             Printf.printf "  %s from %s\n" alias room_id)
           evicted)

(* --- rooms subcommands ---------------------------------------------------- *)

let rooms_send_cmd =
  let room_id =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ROOM" ~doc:"Room ID.")
  in
  let message =
    Cmdliner.Arg.(non_empty & pos_right 0 string [] & info [] ~docv:"MSG" ~doc:"Message body (remaining args joined with spaces).")
  in
  let+ json = json_flag
  and+ room_id = room_id
  and+ message = message in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let from_alias = resolve_alias broker in
  let content = String.concat " " message in
  let output_mode = if json then Json else Human in
  (try
     let result =
       C2c_mcp.Broker.send_room broker ~from_alias ~room_id ~content
     in
     match output_mode with
     | Json ->
         print_json
           (`Assoc
             [ ( "delivered_to",
                 `List
                   (List.map (fun a -> `String a) result.sr_delivered_to) )
             ; ( "skipped",
                 `List (List.map (fun a -> `String a) result.sr_skipped) )
             ; ("ts", `Float result.sr_ts)
             ])
     | Human ->
         Printf.printf "Sent to room %s (%d delivered, %d skipped)\n"
           room_id
           (List.length result.sr_delivered_to)
           (List.length result.sr_skipped)
   with Invalid_argument msg ->
     Printf.eprintf "error: %s\n%!" msg;
     exit 1)

let rooms_join_cmd =
  let room_id =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ROOM" ~doc:"Room ID.")
  in
  let+ json = json_flag
  and+ room_id = room_id in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let alias = resolve_alias broker in
  let session_id = resolve_session_id () in
  let output_mode = if json then Json else Human in
  (try
     let members =
       C2c_mcp.Broker.join_room broker ~room_id ~alias ~session_id
     in
     match output_mode with
     | Json ->
         print_json
           (`Assoc
             [ ("room_id", `String room_id)
             ; ( "members",
                 `List
                   (List.map
                      (fun (m : C2c_mcp.room_member) ->
                        `Assoc
                          [ ("alias", `String m.rm_alias)
                          ; ("session_id", `String m.rm_session_id)
                          ])
                      members))
             ])
     | Human ->
         Printf.printf "Joined room %s (%d members)\n" room_id
           (List.length members);
         List.iter
           (fun (m : C2c_mcp.room_member) -> Printf.printf "  %s\n" m.rm_alias)
           members
   with Invalid_argument msg ->
     Printf.eprintf "error: %s\n%!" msg;
     exit 1)

let rooms_leave_cmd =
  let room_id =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ROOM" ~doc:"Room ID.")
  in
  let+ json = json_flag
  and+ room_id = room_id in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let alias = resolve_alias broker in
  let output_mode = if json then Json else Human in
  (try
     let members =
       C2c_mcp.Broker.leave_room broker ~room_id ~alias
     in
     match output_mode with
     | Json ->
         print_json
           (`Assoc
             [ ("room_id", `String room_id)
             ; ( "members",
                 `List
                   (List.map
                      (fun (m : C2c_mcp.room_member) ->
                        `Assoc
                          [ ("alias", `String m.rm_alias)
                          ; ("session_id", `String m.rm_session_id)
                          ])
                      members))
             ])
     | Human ->
         Printf.printf "Left room %s (%d members remaining)\n" room_id
           (List.length members)
   with Invalid_argument msg ->
     Printf.eprintf "error: %s\n%!" msg;
     exit 1)

let rooms_list_cmd =
  let+ json = json_flag in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let rooms = C2c_mcp.Broker.list_rooms broker in
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      print_json
        (`List
          (List.map
             (fun (r : C2c_mcp.Broker.room_info) ->
               `Assoc
                 [ ("room_id", `String r.ri_room_id)
                 ; ("member_count", `Int r.ri_member_count)
                 ; ("members",
                     `List (List.map (fun a -> `String a) r.ri_members))
                 ; ( "visibility",
                     `String
                       (match r.ri_visibility with
                       | C2c_mcp.Public -> "public"
                       | C2c_mcp.Invite_only -> "invite_only"))
                 ])
             rooms))
  | Human ->
      if rooms = [] then
        Printf.printf "No rooms.\n"
      else
        List.iter
          (fun (r : C2c_mcp.Broker.room_info) ->
            let vis =
              match r.ri_visibility with
              | C2c_mcp.Public -> ""
              | C2c_mcp.Invite_only -> " [invite-only]"
            in
            Printf.printf "%s (%d members)%s\n" r.ri_room_id
              r.ri_member_count vis)
          rooms

let rooms_history_cmd =
  let room_id =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ROOM" ~doc:"Room ID.")
  in
  let limit =
    Cmdliner.Arg.(value & opt int 50 & info [ "limit"; "l" ] ~docv:"N" ~doc:"Max messages to return.")
  in
  let+ json = json_flag
  and+ room_id = room_id
  and+ limit = limit in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let output_mode = if json then Json else Human in
  (try
     let messages =
       C2c_mcp.Broker.read_room_history broker ~room_id ~limit
     in
     match output_mode with
     | Json ->
         print_json
           (`List
             (List.map
                (fun (m : C2c_mcp.room_message) ->
                  `Assoc
                    [ ("ts", `Float m.rm_ts)
                    ; ("from_alias", `String m.rm_from_alias)
                    ; ("content", `String m.rm_content)
                    ])
                messages))
     | Human ->
         if messages = [] then
           Printf.printf "(no history)\n"
         else
           List.iter
             (fun (m : C2c_mcp.room_message) ->
               let time =
                 let t = Unix.gmtime m.rm_ts in
                 Printf.sprintf "%04d-%02d-%02d %02d:%02d"
                   (1900 + t.tm_year) (1 + t.tm_mon) t.tm_mday t.tm_hour t.tm_min
               in
               Printf.printf "[%s] <%s> %s\n" time m.rm_from_alias m.rm_content)
             messages
   with Invalid_argument msg ->
     Printf.eprintf "error: %s\n%!" msg;
     exit 1)

let rooms_invite_cmd =
  let room_id =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ROOM" ~doc:"Room ID.")
  in
  let invitee =
    Cmdliner.Arg.(required & pos 1 (some string) None & info [] ~docv:"ALIAS" ~doc:"Alias to invite.")
  in
  let+ json = json_flag
  and+ room_id = room_id
  and+ invitee = invitee in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let from_alias = resolve_alias broker in
  let output_mode = if json then Json else Human in
  (try
     C2c_mcp.Broker.send_room_invite broker ~room_id ~from_alias
       ~invitee_alias:invitee;
     match output_mode with
     | Json ->
         print_json
           (`Assoc
             [ ("ok", `Bool true)
             ; ("room_id", `String room_id)
             ; ("invitee_alias", `String invitee)
             ])
     | Human ->
         Printf.printf "Invited %s to room %s\n" invitee room_id
   with Invalid_argument msg ->
     Printf.eprintf "error: %s\n%!" msg;
     exit 1)

let rooms_members_cmd =
  let room_id =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ROOM" ~doc:"Room ID.")
  in
  let+ json = json_flag
  and+ room_id = room_id in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let output_mode = if json then Json else Human in
  (try
     let members = C2c_mcp.Broker.read_room_members broker ~room_id in
     match output_mode with
     | Json ->
         print_json
           (`List
             (List.map
                (fun (m : C2c_mcp.room_member) ->
                  `Assoc
                    [ ("alias", `String m.rm_alias)
                    ; ("session_id", `String m.rm_session_id)
                    ; ("joined_at", `Float m.joined_at)
                    ])
                members))
     | Human ->
         if members = [] then
           Printf.printf "No members in room %s.\n" room_id
         else
           List.iter
             (fun (m : C2c_mcp.room_member) ->
               Printf.printf "  %s (%s)\n" m.rm_alias m.rm_session_id)
             members
   with Invalid_argument msg ->
     Printf.eprintf "error: %s\n%!" msg;
     exit 1)

let rooms_visibility_cmd =
  let room_id =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ROOM" ~doc:"Room ID.")
  in
  let visibility =
    Cmdliner.Arg.(value & opt (some string) None & info [ "set"; "s" ] ~docv:"VIS" ~doc:"Visibility: public or invite_only.")
  in
  let+ json = json_flag
  and+ room_id = room_id
  and+ vis_opt = visibility in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let from_alias = resolve_alias broker in
  let output_mode = if json then Json else Human in
  (try
     (match vis_opt with
      | Some vis_str ->
          let vis =
            match String.lowercase_ascii vis_str with
            | "public" -> C2c_mcp.Public
            | "invite_only" | "invite-only" -> C2c_mcp.Invite_only
            | _ ->
                Printf.eprintf "error: unknown visibility '%s'. Use 'public' or 'invite_only'.\n%!" vis_str;
                exit 1
          in
          C2c_mcp.Broker.set_room_visibility broker ~room_id ~from_alias ~visibility:vis;
          (match output_mode with
           | Json -> print_json (`Assoc [ ("ok", `Bool true); ("visibility", `String vis_str) ])
           | Human -> Printf.printf "Room %s visibility set to %s\n" room_id vis_str)
      | None ->
          let meta = C2c_mcp.Broker.load_room_meta broker ~room_id in
          let vis_str =
            match meta.visibility with
            | C2c_mcp.Public -> "public"
            | C2c_mcp.Invite_only -> "invite_only"
          in
          (match output_mode with
           | Json ->
               print_json
                 (`Assoc
                   [ ("room_id", `String room_id)
                   ; ("visibility", `String vis_str)
                   ; ( "invited_members",
                       `List (List.map (fun a -> `String a) meta.invited_members))
                   ])
           | Human ->
               Printf.printf "Room %s: %s\n" room_id vis_str;
               if meta.invited_members <> [] then
                 Printf.printf "  invited: %s\n"
                   (String.concat ", " meta.invited_members)))
   with Invalid_argument msg ->
     Printf.eprintf "error: %s\n%!" msg;
     exit 1)

let rooms_list = Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List all rooms.") rooms_list_cmd
let rooms_join = Cmdliner.Cmd.v (Cmdliner.Cmd.info "join" ~doc:"Join a room.") rooms_join_cmd
let rooms_leave = Cmdliner.Cmd.v (Cmdliner.Cmd.info "leave" ~doc:"Leave a room.") rooms_leave_cmd
let rooms_send = Cmdliner.Cmd.v (Cmdliner.Cmd.info "send" ~doc:"Send a message to a room.") rooms_send_cmd
let rooms_history = Cmdliner.Cmd.v (Cmdliner.Cmd.info "history" ~doc:"Show room message history.") rooms_history_cmd
let rooms_invite = Cmdliner.Cmd.v (Cmdliner.Cmd.info "invite" ~doc:"Invite an alias to a room.") rooms_invite_cmd
let rooms_members = Cmdliner.Cmd.v (Cmdliner.Cmd.info "members" ~doc:"List room members.") rooms_members_cmd
let rooms_visibility = Cmdliner.Cmd.v (Cmdliner.Cmd.info "visibility" ~doc:"Get or set room visibility.") rooms_visibility_cmd

let rooms_group =
  Cmdliner.Cmd.group
    ~default:rooms_list_cmd
    (Cmdliner.Cmd.info "rooms" ~doc:"Manage persistent N:N rooms.")
    [ rooms_list; rooms_join; rooms_leave; rooms_send; rooms_history; rooms_invite; rooms_members; rooms_visibility ]

(* --- main entry point ----------------------------------------------------- *)

let send = Cmdliner.Cmd.v (Cmdliner.Cmd.info "send" ~doc:"Send a message to a registered peer alias.") send_cmd
let list = Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List registered C2C peers.") list_cmd
let whoami = Cmdliner.Cmd.v (Cmdliner.Cmd.info "whoami" ~doc:"Show current c2c identity.") whoami_cmd
let poll_inbox = Cmdliner.Cmd.v (Cmdliner.Cmd.info "poll-inbox" ~doc:"Drain (or peek at) your inbox.") poll_inbox_cmd
(* peek-inbox is an alias for poll-inbox --peek *)
let peek_inbox_cmd =
  let+ json = json_flag in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let session_id = resolve_session_id () in
  let messages = C2c_mcp.Broker.read_inbox broker ~session_id in
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      print_json
        (`List
          (List.map
             (fun (m : C2c_mcp.message) ->
               `Assoc
                 [ ("from_alias", `String m.from_alias)
                 ; ("to_alias", `String m.to_alias)
                 ; ("content", `String m.content)
                 ])
             messages))
  | Human ->
      if messages = [] then
        Printf.printf "(no messages)\n"
      else
        List.iter
          (fun (m : C2c_mcp.message) -> Printf.printf "[%s] %s\n" m.from_alias m.content)
          messages

let peek_inbox = Cmdliner.Cmd.v (Cmdliner.Cmd.info "peek-inbox" ~doc:"Peek at your inbox without draining.") peek_inbox_cmd
let send_all = Cmdliner.Cmd.v (Cmdliner.Cmd.info "send-all" ~doc:"Broadcast a message to all peers.") send_all_cmd
let sweep = Cmdliner.Cmd.v (Cmdliner.Cmd.info "sweep" ~doc:"Remove dead registrations and orphan inboxes.") sweep_cmd
let history = Cmdliner.Cmd.v (Cmdliner.Cmd.info "history" ~doc:"Show archived inbox messages.") history_cmd
let health = Cmdliner.Cmd.v (Cmdliner.Cmd.info "health" ~doc:"Show broker health diagnostics.") health_cmd
let register = Cmdliner.Cmd.v (Cmdliner.Cmd.info "register" ~doc:"Register an alias for the current session.") register_cmd
let tail_log = Cmdliner.Cmd.v (Cmdliner.Cmd.info "tail-log" ~doc:"Show recent broker RPC log entries.") tail_log_cmd
let my_rooms = Cmdliner.Cmd.v (Cmdliner.Cmd.info "my-rooms" ~doc:"List rooms you are a member of.") my_rooms_cmd
let dead_letter = Cmdliner.Cmd.v (Cmdliner.Cmd.info "dead-letter" ~doc:"Show dead-letter entries.") dead_letter_cmd
let prune_rooms = Cmdliner.Cmd.v (Cmdliner.Cmd.info "prune-rooms" ~doc:"Evict dead members from all rooms.") prune_rooms_cmd

(* --- subcommand: smoke-test ----------------------------------------------- *)

let smoke_test_cmd =
  let+ json = json_flag in
  let tmp_dir = Filename.temp_file "c2c-smoke-" "" in
  Sys.remove tmp_dir;
  Unix.mkdir tmp_dir 0o755;
  let broker_root = tmp_dir // "broker" in
  Unix.mkdir broker_root 0o755;
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let session_a = "smoke-session-a" in
  let session_b = "smoke-session-b" in
  let alias_a = "smoke-a" in
  let alias_b = "smoke-b" in
  let pid = Some (Unix.getpid ()) in
  let pid_start_time = C2c_mcp.Broker.capture_pid_start_time pid in
  C2c_mcp.Broker.register broker ~session_id:session_a ~alias:alias_a ~pid ~pid_start_time;
  C2c_mcp.Broker.register broker ~session_id:session_b ~alias:alias_b ~pid ~pid_start_time;
  let marker =
    Printf.sprintf "c2c-smoke-%d-%d"
      (Unix.gettimeofday () |> int_of_float)
      (Random.int 100000)
  in
  C2c_mcp.Broker.enqueue_message broker ~from_alias:alias_a ~to_alias:alias_b ~content:marker;
  let messages = C2c_mcp.Broker.drain_inbox broker ~session_id:session_b in
  let ok = List.exists (fun (m : C2c_mcp.message) -> m.content = marker) messages in
  let rec rm_rf path =
    if Sys.is_directory path then (
      let entries = Sys.readdir path in
      Array.iter (fun e -> rm_rf (path // e)) entries;
      Unix.rmdir path)
    else Sys.remove path
  in
  rm_rf tmp_dir;
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      print_json
        (`Assoc [ ("ok", `Bool ok); ("marker", `String marker) ])
  | Human ->
      if ok then
        Printf.printf "smoke-test passed (marker: %s)\n" marker
      else (
        Printf.eprintf "smoke-test failed: marker not received (marker: %s)\n%!" marker;
        exit 1)

let smoke_test = Cmdliner.Cmd.v (Cmdliner.Cmd.info "smoke-test" ~doc:"Run an end-to-end broker smoke test.") smoke_test_cmd

(* --- subcommand: install -------------------------------------------------- *)

let install_cmd =
  let dest =
    Cmdliner.Arg.(value & opt (some string) None & info [ "dest"; "d" ] ~docv:"DIR" ~doc:"Install destination (default: ~/.local/bin).")
  in
  let+ json = json_flag
  and+ dest_opt = dest in
  let dest_dir =
    match dest_opt with
    | Some d -> d
    | None ->
        let home = Sys.getenv "HOME" in
        home // ".local" // "bin"
  in
  let output_mode = if json then Json else Human in
  (* Determine path of the running executable *)
  let exe_path = Sys.executable_name in
  if not (Sys.file_exists exe_path) then (
    match output_mode with
    | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String "cannot determine executable path") ])
    | Human ->
        Printf.eprintf "error: cannot find executable at %s\n%!" exe_path;
        exit 1)
  else
    let result =
      try
        if not (Sys.is_directory dest_dir) then (
          let parent = Filename.dirname dest_dir in
          if not (Sys.is_directory parent) then Unix.mkdir parent 0o755;
          Unix.mkdir dest_dir 0o755);
        let dest_path = dest_dir // "c2c" in
        let ic = open_in_bin exe_path in
        let oc = open_out_bin (dest_path ^ ".tmp") in
        Fun.protect ~finally:(fun () -> close_in ic; close_out oc) (fun () ->
          let buf = Bytes.create 65536 in
          let rec copy () =
            let n = input ic buf 0 (Bytes.length buf) in
            if n > 0 then (output oc buf 0 n; copy ())
          in
          copy ());
        Unix.chmod (dest_path ^ ".tmp") 0o755;
        Unix.rename (dest_path ^ ".tmp") dest_path;
        Ok dest_path
      with
      | Unix.Unix_error (code, func, _arg) ->
          Error (Printf.sprintf "%s: %s" func (Unix.error_message code))
      | Sys_error msg -> Error msg
    in
    (match result with
     | Ok dest_path ->
         (match output_mode with
          | Json -> print_json (`Assoc [ ("ok", `Bool true); ("installed", `String dest_path) ])
          | Human -> Printf.printf "installed c2c to %s\n" dest_path)
     | Error msg ->
         (match output_mode with
          | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String msg) ])
          | Human ->
              Printf.eprintf "error: %s\n%!" msg;
              exit 1))

let install = Cmdliner.Cmd.v (Cmdliner.Cmd.info "install" ~doc:"Install c2c binary to ~/.local/bin.") install_cmd

(* --- subcommand: setup --------------------------------------------------- *)

let alias_words = [| "amber"; "ash"; "azure"; "birch"; "blade"; "blaze"; "bloom"; "brass"; "brick"; "bright"; "bronze"; "brook"; "cedar"; "chalk"; "charm"; "clay"; "copper"; "coral"; "creek"; "crimson"; "crown"; "crystal"; "dawn"; "dusk"; "ember"; "fern"; "flame"; "flint"; "frost"; "gale"; "glow"; "granite"; "gravel"; "haze"; "hazel"; "iron"; "ivory"; "jade"; "lake"; "lava"; "leaf"; "limestone"; "lime"; "marble"; "mist"; "moss"; "mountain"; "onyx"; "opal"; "pine"; "quartz"; "reef"; "ridge"; "river"; "ruby"; "rust"; "sage"; "sand"; "shadow"; "silver"; "slate"; "smoke"; "snow"; "spark"; "steel"; "stone"; "storm"; "summit"; "thorn"; "tide"; "timber"; "vale"; "vine"; "wave"; "weld"; "willow" |]

let generate_alias () =
  let n = Array.length alias_words in
  let w1 = alias_words.(Random.int n) in
  let w2 = alias_words.(Random.int n) in
  Printf.sprintf "%s-%s" w1 w2

let generate_session_id () =
  let buf = Buffer.create 36 in
  for _ = 1 to 8 do
    Buffer.add_string buf (string_of_int (Random.int 16))
  done;
  Buffer.add_char buf '-';
  for _ = 1 to 4 do
    Buffer.add_string buf (string_of_int (Random.int 16))
  done;
  Buffer.add_char buf '-';
  for _ = 1 to 4 do
    Buffer.add_string buf (string_of_int (Random.int 16))
  done;
  Buffer.contents buf

let find_ocaml_server_path () =
  (* Look for c2c_mcp_server.exe in _build, then try opam *)
  let candidates = [
    "_build/default/ocaml/server/c2c_mcp_server.exe";
    "_build/ocaml/server/c2c_mcp_server.exe";
  ] in
  let extra_candidates =
    try
      let switch = Sys.getenv "OPAM_SWITCH_PREFIX" in
      [ switch // "bin/c2c_mcp_server" ]
    with Not_found -> []
  in
  let all = candidates @ extra_candidates in
  List.find_opt Sys.file_exists all

let json_read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    let s = really_input_string ic (in_channel_length ic) in
    Yojson.Safe.from_string s)

let json_write_file path json =
  let tmp = path ^ ".tmp" in
  let oc = open_out tmp in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    Yojson.Safe.pretty_to_channel oc json);
  Unix.rename tmp path

let setup_cmd =
  let client =
    Cmdliner.Arg.(value & opt (some string) None & info [ "client"; "c" ] ~docv:"CLIENT" ~doc:"Client type: claude, codex, kimi, opencode (default: claude).")
  in
  let alias =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias"; "a" ] ~docv:"ALIAS" ~doc:"Alias to use (default: auto-generated).")
  in
  let broker_root =
    Cmdliner.Arg.(value & opt (some string) None & info [ "broker-root"; "b" ] ~docv:"DIR" ~doc:"Broker root directory (default: auto-detected).")
  in
  let+ json = json_flag
  and+ client_opt = client
  and+ alias_opt = alias
  and+ broker_root_opt = broker_root in
  let output_mode = if json then Json else Human in
  let client = Option.value client_opt ~default:"claude" in
  let root =
    match broker_root_opt with
    | Some r -> r
    | None -> resolve_broker_root ()
  in
  let alias_val =
    match alias_opt with
    | Some a -> a
    | None -> generate_alias ()
  in
  let session_id = generate_session_id () in
  let server_path =
    match find_ocaml_server_path () with
    | Some p -> p
    | None ->
        (match output_mode with
         | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String "cannot find c2c_mcp_server binary") ])
         | Human ->
             Printf.eprintf "error: cannot find c2c_mcp_server binary. Build with: just build\n%!");
        exit 1
  in
  let server_path =
    if Filename.is_relative server_path then
      Sys.getcwd () // server_path
    else server_path
  in
  (match String.lowercase_ascii client with
   | "claude" ->
       let claude_json = Filename.concat (Sys.getenv "HOME") ".claude.json" in
       let config =
         if Sys.file_exists claude_json then json_read_file claude_json
         else `Assoc []
       in
       let mcp_entry =
         `Assoc
           [ ("command", `String "opam")
           ; ("args", `List [ `String "exec"; `String "--"; `String "dune"; `String "run"; `String server_path ])
           ; ("env", `Assoc
               [ ("C2C_MCP_BROKER_ROOT", `String root)
               ; ("C2C_MCP_AUTO_REGISTER_ALIAS", `String alias_val)
               ; ("C2C_MCP_AUTO_JOIN_ROOMS", `String "swarm-lounge")
               ])
           ]
       in
       let config = match config with
         | `Assoc fields ->
             let filtered = List.filter (fun (k, _) -> k <> "mcpServers") fields in
             let existing_mcp = match List.assoc_opt "mcpServers" fields with
               | Some (`Assoc m) -> List.filter (fun (k, _) -> k <> "c2c") m
               | _ -> []
             in
             `Assoc (filtered @ [ ("mcpServers", `Assoc (existing_mcp @ [ ("c2c", mcp_entry) ])) ])
         | _ -> `Assoc [ ("mcpServers", `Assoc [ ("c2c", mcp_entry) ]) ]
       in
       json_write_file claude_json config;
       (match output_mode with
        | Json ->
            print_json (`Assoc
              [ ("ok", `Bool true)
              ; ("client", `String "claude")
              ; ("alias", `String alias_val)
              ; ("session_id", `String session_id)
              ; ("broker_root", `String root)
              ; ("config", `String claude_json)
              ])
        | Human ->
            Printf.printf "Configured Claude Code for c2c.\n";
            Printf.printf "  alias:       %s\n" alias_val;
            Printf.printf "  broker root: %s\n" root;
            Printf.printf "  config:      %s\n" claude_json;
            Printf.printf "  server:      %s\n" server_path;
            Printf.printf "\nRestart Claude Code to pick up the new MCP server.\n")
   | "codex" | "kimi" | "opencode" ->
       (match output_mode with
        | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String (Printf.sprintf "client '%s' not yet implemented in OCaml CLI" client)) ])
        | Human ->
            Printf.printf "Setup for %s is not yet implemented in the OCaml CLI.\n" client;
            Printf.printf "Use: python3 c2c_configure_%s.py --alias %s\n" client alias_val;
            exit 1)
   | _ ->
       (match output_mode with
        | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String (Printf.sprintf "unknown client '%s'. Use: claude, codex, kimi, opencode" client)) ])
        | Human ->
            Printf.eprintf "error: unknown client '%s'. Use: claude, codex, kimi, opencode\n%!" client;
            exit 1))

let setup = Cmdliner.Cmd.v (Cmdliner.Cmd.info "setup" ~doc:"Configure a client for c2c messaging.") setup_cmd

let () =
  exit
    (Cmdliner.Cmd.eval
       (Cmdliner.Cmd.group
          (Cmdliner.Cmd.info "c2c"
             ~version:"0.7.0"
             ~doc:"c2c — peer-to-peer messaging for AI agents"
             ~man:
               [ `S "DESCRIPTION"
               ; `P
                   "c2c is a peer-to-peer messaging broker between AI coding \
                    sessions. Use subcommands to interact with the broker."
               ; `S "COMMANDS"
               ; `P
                   "$(b,send), $(b,list), $(b,whoami), $(b,poll-inbox), \
                    $(b,send-all), $(b,sweep), $(b,history), $(b,health), \
                    $(b,register), $(b,tail-log), $(b,my-rooms), \
                    $(b,dead-letter), $(b,prune-rooms), $(b,smoke-test), \
                    $(b,install), $(b,setup)"
               ; `P "$(b,rooms) — manage N:N chat rooms"
               ])
          [ send; list; whoami; poll_inbox; peek_inbox; send_all; sweep; history; health; register; tail_log; my_rooms; dead_letter; prune_rooms; smoke_test; install; setup; rooms_group ]))
