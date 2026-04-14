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
  let abs_path p =
    if Filename.is_relative p then Sys.getcwd () // p else p
  in
  match broker_root_from_env () with
  | Some dir -> abs_path dir
  | None -> (
      match git_common_dir () with
      | Some git_dir ->
          let abs_git = abs_path git_dir in
          let dir = abs_git // "c2c" // "mcp" in
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

(* --- subcommand: status --------------------------------------------------- *)

let status_cmd =
  let min_messages =
    Cmdliner.Arg.(
      value
      & opt int 1
      & info [ "min-messages" ] ~docv:"N"
          ~doc:"Minimum total messages (sent+received) to include a peer.")
  in
  let+ json = json_flag
  and+ min_messages = min_messages in
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in
  let now = Unix.gettimeofday () in
  let archive_dir = root // "archive" in

  let sent_by_alias = Hashtbl.create 16 in
  let received_by_sid = Hashtbl.create 16 in
  let last_sent_by_alias = Hashtbl.create 16 in
  let last_recv_by_sid = Hashtbl.create 16 in

  if Sys.is_directory archive_dir then
    let entries =
      try Array.to_list (Sys.readdir archive_dir)
      with Sys_error _ -> []
    in
    List.iter
      (fun fname ->
         if Filename.check_suffix fname ".jsonl" then (
           let session_id = Filename.chop_extension fname in
           let path = archive_dir // fname in
           try
             let ic = open_in path in
             Fun.protect
               ~finally:(fun () -> close_in_noerr ic)
               (fun () ->
                  let rec loop () =
                    match input_line ic with
                    | exception End_of_file -> ()
                    | line ->
                        let line = String.trim line in
                        if line <> "" then (
                          try
                            let json = Yojson.Safe.from_string line in
                            let open Yojson.Safe.Util in
                            let from_alias =
                              try json |> member "from_alias" |> to_string
                              with _ -> ""
                            in
                            let drained_at =
                              match json |> member "drained_at" with
                              | `Float f -> f
                              | `Int i -> float_of_int i
                              | _ -> 0.0
                            in
                            if from_alias <> "" && from_alias <> "c2c-system"
                            then (
                              let prev =
                                try Hashtbl.find sent_by_alias from_alias
                                with Not_found -> 0
                              in
                              Hashtbl.replace sent_by_alias from_alias
                                (prev + 1);
                              let prev_ts =
                                try Hashtbl.find last_sent_by_alias from_alias
                                with Not_found -> 0.0
                              in
                              if drained_at > prev_ts then
                                Hashtbl.replace last_sent_by_alias from_alias
                                  drained_at
                            );
                            let prev_recv =
                              try Hashtbl.find last_recv_by_sid session_id
                              with Not_found -> 0.0
                            in
                            if drained_at > prev_recv then
                              Hashtbl.replace last_recv_by_sid session_id
                                drained_at;
                            let prev_recv_count =
                              try Hashtbl.find received_by_sid session_id
                              with Not_found -> 0
                            in
                            Hashtbl.replace received_by_sid session_id
                              (prev_recv_count + 1)
                          with _ -> ());
                        loop ()
                  in
                  loop ())
           with Sys_error _ -> ()))
      entries;

  let goal_count = 20 in
  let regs = C2c_mcp.Broker.list_registrations broker in
  let rooms = C2c_mcp.Broker.list_rooms broker in

  let alive_peers =
    List.filter_map
      (fun (r : C2c_mcp.registration) ->
         if C2c_mcp.Broker.registration_is_alive r then (
           let sent =
             try Hashtbl.find sent_by_alias r.alias with Not_found -> 0
           in
           let received =
             try Hashtbl.find received_by_sid r.session_id with Not_found ->
               try Hashtbl.find received_by_sid r.alias with Not_found -> 0
           in
           if sent + received >= min_messages then
             let last_sent =
               try Hashtbl.find last_sent_by_alias r.alias
               with Not_found -> 0.0
             in
             let last_recv =
               try Hashtbl.find last_recv_by_sid r.session_id with Not_found ->
                 try Hashtbl.find last_recv_by_sid r.alias
                 with Not_found -> 0.0
             in
             let last_active = max last_sent last_recv in
             let goal_met = sent >= goal_count && received >= goal_count in
             Some (r.alias, sent, received, goal_met, last_active)
           else None)
         else None)
      regs
  in

  let dead_peer_count = List.length regs - List.length alive_peers in
  let overall_goal_met =
    alive_peers <> []
    && List.for_all (fun (_, _, _, gm, _) -> gm) alive_peers
  in

  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      let peer_json (alias, sent, received, goal_met, last_active) =
        `Assoc
          [ ("alias", `String alias)
          ; ("sent", `Int sent)
          ; ("received", `Int received)
          ; ("goal_met", `Bool goal_met)
          ; ("last_active_ts", `Float last_active)
          ]
      in
      let room_json (r : C2c_mcp.Broker.room_info) =
        let alive_members =
          List.filter_map
            (fun (m : C2c_mcp.Broker.room_member_info) ->
               if m.rmi_alive <> Some false then Some (`String m.rmi_alias)
               else None)
            r.ri_member_details
        in
        `Assoc
          [ ("room_id", `String r.ri_room_id)
          ; ("member_count", `Int r.ri_member_count)
          ; ("alive_count", `Int r.ri_alive_member_count)
          ; ("alive_members", `List alive_members)
          ]
      in
      print_json
        (`Assoc
           [ ("alive_peers", `List (List.map peer_json alive_peers))
           ; ("dead_peer_count", `Int dead_peer_count)
           ; ("total_peer_count", `Int (List.length regs))
           ; ("rooms", `List (List.map room_json rooms))
           ; ("overall_goal_met", `Bool overall_goal_met)
           ])
  | Human ->
      Printf.printf "c2c Status\n";
      Printf.printf "==================================================\n\n";
      Printf.printf "Alive peers (%d/%d):\n" (List.length alive_peers)
        (List.length regs);
      List.iter
        (fun (alias, sent, received, goal_met, last_active) ->
           let age =
             let delta = now -. last_active in
             if delta < 0.0 then "just now"
             else if delta < 60.0 then Printf.sprintf "%.0fs ago" delta
             else if delta < 3600.0 then
               Printf.sprintf "%.0fm ago" (delta /. 60.0)
             else if delta < 86400.0 then
               Printf.sprintf "%.0fh ago" (delta /. 3600.0)
             else Printf.sprintf "%.0fd ago" (delta /. 86400.0)
           in
           let status = if goal_met then "goal_met" else "pending" in
           Printf.printf "  %-20s sent=%3d recv=%3d  %-8s  last=%s\n" alias
             sent received status age)
        alive_peers;
      if alive_peers = [] then Printf.printf "  (none)\n";
      Printf.printf "\nRooms:\n";
      List.iter
        (fun (r : C2c_mcp.Broker.room_info) ->
           Printf.printf "  %-20s %d member(s), %d alive\n" r.ri_room_id
             r.ri_member_count r.ri_alive_member_count)
        rooms;
      if rooms = [] then Printf.printf "  (none)\n";
      Printf.printf "\nOverall goal_met: %s\n"
        (if overall_goal_met then "YES" else "NO")

let status =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "status" ~doc:"Show compact swarm overview.")
    status_cmd

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

let default_alias_for_client client =
  let user = try Sys.getenv "USER" with Not_found -> "user" in
  let host =
    try
      let h = Sys.getenv "HOSTNAME" in
      try String.sub h 0 (String.index h '.') with Not_found -> h
    with Not_found ->
      try
        let h = Unix.gethostname () in
        try String.sub h 0 (String.index h '.') with Not_found -> h
      with _ -> "localhost"
  in
  Printf.sprintf "%s-%s-%s" client user host

(* --- setup: Codex (TOML) --- *)

let c2c_tools_list = [
  "register"; "whoami"; "list";
  "send"; "send_all";
  "poll_inbox"; "peek_inbox"; "history";
  "join_room"; "leave_room"; "send_room"; "list_rooms"; "my_rooms"; "room_history";
  "sweep"; "tail_log";
]

let setup_codex ~output_mode ~root ~alias_val ~server_path =
  let config_path = Filename.concat (Sys.getenv "HOME") (".codex" // "config.toml") in
  let existing =
    if Sys.file_exists config_path then
      let ic = open_in config_path in
      Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
        let n = in_channel_length ic in
        let s = really_input_string ic n in
        s)
    else ""
  in
  let lines = String.split_on_char '\n' existing in
  let stripped =
    let buf = Buffer.create (String.length existing) in
    let in_c2c = ref false in
    List.iter (fun line ->
      let trimmed = String.trim line in
      if String.length trimmed > 0 && trimmed.[0] = '[' then begin
        in_c2c :=
          (try
             let sec = String.sub trimmed 1 (String.length trimmed - 2) in
             String.length sec >= String.length "mcp_servers.c2c"
             && String.sub sec 0 (String.length "mcp_servers.c2c") = "mcp_servers.c2c"
           with _ -> false)
      end;
      if not !in_c2c then Buffer.add_string buf line;
      Buffer.add_char buf '\n'
    ) lines;
    Buffer.contents buf
  in
  let buf = Buffer.create 1024 in
  Buffer.add_string buf "\n[mcp_servers.c2c]\n";
  Buffer.add_string buf "command = \"opam\"\n";
  Buffer.add_string buf (Printf.sprintf "args = [\"exec\", \"--\", \"dune\", \"run\", \"%s\"]\n" server_path);
  Buffer.add_string buf "\n[mcp_servers.c2c.env]\n";
  Buffer.add_string buf (Printf.sprintf "C2C_MCP_BROKER_ROOT = \"%s\"\n" root);
  Buffer.add_string buf (Printf.sprintf "C2C_MCP_SESSION_ID = \"%s\"\n" alias_val);
  Buffer.add_string buf "C2C_MCP_AUTO_JOIN_ROOMS = \"swarm-lounge\"\n";
  List.iter (fun tool ->
    Buffer.add_string buf (Printf.sprintf "\n[mcp_servers.c2c.tools.%s]\n" tool);
    Buffer.add_string buf "approval_mode = \"auto\"\n"
  ) c2c_tools_list;
  let new_content = stripped ^ Buffer.contents buf in
  (try Unix.mkdir (Filename.dirname config_path) 0o755 with Unix.Unix_error _ -> ());
  let tmp = config_path ^ ".tmp" in
  let oc = open_out tmp in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc new_content);
  Unix.rename tmp config_path;
  match output_mode with
  | Json ->
      print_json (`Assoc
        [ ("ok", `Bool true)
        ; ("client", `String "codex")
        ; ("alias", `String alias_val)
        ; ("broker_root", `String root)
        ; ("config", `String config_path)
        ])
  | Human ->
      Printf.printf "Configured Codex for c2c.\n";
      Printf.printf "  alias:       %s\n" alias_val;
      Printf.printf "  broker root: %s\n" root;
      Printf.printf "  config:      %s\n" config_path;
      Printf.printf "  server:      %s\n" server_path;
      Printf.printf "\nRestart Codex to pick up the new MCP server.\n"

(* --- setup: Kimi (JSON) --- *)

let setup_kimi ~output_mode ~root ~alias_val ~server_path =
  let config_path = Filename.concat (Sys.getenv "HOME") (".kimi" // "mcp.json") in
  let existing =
    if Sys.file_exists config_path then json_read_file config_path
    else `Assoc []
  in
  let c2c_entry =
    `Assoc
      [ ("type", `String "stdio")
      ; ("command", `String "opam")
      ; ("args", `List [ `String "exec"; `String "--"; `String "dune"; `String "run"; `String server_path ])
      ; ("env", `Assoc
          [ ("C2C_MCP_BROKER_ROOT", `String root)
          ; ("C2C_MCP_SESSION_ID", `String alias_val)
          ; ("C2C_MCP_AUTO_JOIN_ROOMS", `String "swarm-lounge")
          ])
      ]
  in
  let config = match existing with
    | `Assoc fields ->
        let existing_mcp = match List.assoc_opt "mcpServers" fields with
          | Some (`Assoc m) -> List.filter (fun (k, _) -> k <> "c2c") m
          | _ -> []
        in
        `Assoc (List.filter (fun (k, _) -> k <> "mcpServers") fields
                @ [ ("mcpServers", `Assoc (existing_mcp @ [ ("c2c", c2c_entry) ])) ])
    | _ -> `Assoc [ ("mcpServers", `Assoc [ ("c2c", c2c_entry) ]) ]
  in
  (try Unix.mkdir (Filename.dirname config_path) 0o755 with Unix.Unix_error _ -> ());
  json_write_file config_path config;
  match output_mode with
  | Json ->
      print_json (`Assoc
        [ ("ok", `Bool true)
        ; ("client", `String "kimi")
        ; ("alias", `String alias_val)
        ; ("broker_root", `String root)
        ; ("config", `String config_path)
        ])
  | Human ->
      Printf.printf "Configured Kimi for c2c.\n";
      Printf.printf "  alias:       %s\n" alias_val;
      Printf.printf "  broker root: %s\n" root;
      Printf.printf "  config:      %s\n" config_path;
      Printf.printf "  server:      %s\n" server_path;
      Printf.printf "\nRestart Kimi to pick up the new MCP server.\n"

(* --- setup: OpenCode (JSON + plugin) --- *)

let setup_opencode ~output_mode ~root ~alias_val ~server_path ~target_dir_opt =
  let target_dir = match target_dir_opt with
    | Some d -> d
    | None -> Sys.getcwd ()
  in
  if not (Sys.is_directory target_dir) then begin
    Printf.eprintf "error: target directory does not exist: %s\n%!" target_dir;
    exit 1
  end;
  let config_dir = target_dir // ".opencode" in
  let config_path = config_dir // "opencode.json" in
  let dir_name = Filename.basename (Filename.chop_suffix target_dir "/") in
  let session_id = Printf.sprintf "opencode-%s" dir_name in
  (try Unix.mkdir config_dir 0o755 with Unix.Unix_error _ -> ());
  let config =
    `Assoc
      [ ("$schema", `String "https://opencode.ai/config.json")
      ; ("mcp", `Assoc
          [ ("c2c", `Assoc
              [ ("type", `String "local")
              ; ("command", `List [ `String "opam"; `String "exec"; `String "--"; `String "dune"; `String "run"; `String server_path ])
              ; ("environment", `Assoc
                  [ ("C2C_MCP_BROKER_ROOT", `String root)
                  ; ("C2C_MCP_SESSION_ID", `String session_id)
                  ; ("C2C_MCP_AUTO_DRAIN_CHANNEL", `String "0")
                  ; ("C2C_MCP_AUTO_JOIN_ROOMS", `String "swarm-lounge")
                  ])
              ; ("enabled", `Bool true)
              ])
          ])
      ]
  in
  json_write_file config_path config;
  let sidecar = config_dir // "c2c-plugin.json" in
  let sidecar_json =
    `Assoc
      [ ("session_id", `String session_id)
      ; ("alias", `String alias_val)
      ; ("broker_root", `String root)
      ]
  in
  json_write_file sidecar sidecar_json;
  let plugin_src = ".opencode/plugins/c2c.ts" in
  let plugin_note =
    if Sys.file_exists plugin_src then begin
      let plugins_dir = config_dir // "plugins" in
      (try Unix.mkdir plugins_dir 0o755 with Unix.Unix_error _ -> ());
      let dest = plugins_dir // "c2c.ts" in
      (try
         let ic = open_in_bin plugin_src in
         let oc = open_out_bin (dest ^ ".tmp") in
         Fun.protect ~finally:(fun () -> close_in ic; close_out oc) (fun () ->
           let buf = Bytes.create 65536 in
           let rec copy () =
             let n = input ic buf 0 (Bytes.length buf) in
             if n > 0 then (output oc buf 0 n; copy ())
           in
           copy ());
         Unix.rename (dest ^ ".tmp") dest;
         Printf.sprintf "plugin installed to %s" dest
       with _ -> "plugin copy failed")
    end else "plugin source not found (expected .opencode/plugins/c2c.ts in c2c repo)"
  in
  match output_mode with
  | Json ->
      print_json (`Assoc
        [ ("ok", `Bool true)
        ; ("client", `String "opencode")
        ; ("session_id", `String session_id)
        ; ("alias", `String alias_val)
        ; ("broker_root", `String root)
        ; ("config", `String config_path)
        ; ("plugin", `String plugin_note)
        ])
  | Human ->
      Printf.printf "Configured OpenCode for c2c.\n";
      Printf.printf "  session id:  %s\n" session_id;
      Printf.printf "  alias:       %s\n" alias_val;
      Printf.printf "  broker root: %s\n" root;
      Printf.printf "  config:      %s\n" config_path;
      Printf.printf "  plugin:      %s\n" plugin_note;
      Printf.printf "\nRun 'opencode mcp list' from %s to verify.\n" target_dir

let setup_cmd =
  let client =
    Cmdliner.Arg.(value & opt (some string) None & info [ "client"; "c" ] ~docv:"CLIENT" ~doc:"Client type: claude, codex, kimi, opencode (default: claude).")
  in
  let alias =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias"; "a" ] ~docv:"ALIAS" ~doc:"Alias to use (default: auto-generated per client).")
  in
  let broker_root =
    Cmdliner.Arg.(value & opt (some string) None & info [ "broker-root"; "b" ] ~docv:"DIR" ~doc:"Broker root directory (default: auto-detected).")
  in
  let target_dir =
    Cmdliner.Arg.(value & opt (some string) None & info [ "target-dir"; "t" ] ~docv:"DIR" ~doc:"Target directory for opencode config (default: cwd).")
  in
  let force =
    Cmdliner.Arg.(value & flag & info [ "force"; "f" ] ~doc:"Overwrite existing configuration.")
  in
  let+ json = json_flag
  and+ client_opt = client
  and+ alias_opt = alias
  and+ broker_root_opt = broker_root
  and+ target_dir_opt = target_dir
  and+ _force = force in
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
    | None -> default_alias_for_client client
  in
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
   | "codex" -> setup_codex ~output_mode ~root ~alias_val ~server_path
   | "kimi" -> setup_kimi ~output_mode ~root ~alias_val ~server_path
   | "opencode" -> setup_opencode ~output_mode ~root ~alias_val ~server_path ~target_dir_opt
   | _ ->
       (match output_mode with
        | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String (Printf.sprintf "unknown client '%s'. Use: claude, codex, kimi, opencode" client)) ])
        | Human ->
            Printf.eprintf "error: unknown client '%s'. Use: claude, codex, kimi, opencode\n%!" client;
            exit 1))

let setup = Cmdliner.Cmd.v (Cmdliner.Cmd.info "setup" ~doc:"Configure a client for c2c messaging.") setup_cmd

(* --- subcommand: serve (MCP server mode) ---------------------------------- *)

let serve_cmd =
  let open Cmdliner.Term in
  let+ () = const () in
  let root =
    match broker_root_from_env () with
    | Some r -> r
    | None -> resolve_broker_root ()
  in
  C2c_mcp.auto_register_startup ~broker_root:root;
  C2c_mcp.auto_join_rooms_startup ~broker_root:root;
  let open Lwt.Syntax in
  let auto_drain =
    match Sys.getenv_opt "C2C_MCP_AUTO_DRAIN_CHANNEL" with
    | Some v ->
        let n = String.lowercase_ascii (String.trim v) in
        not (List.mem n [ "0"; "false"; "no"; "off" ])
    | None -> false
  in
  let session_id =
    match Sys.getenv_opt "C2C_MCP_SESSION_ID" with
    | Some v when String.trim v <> "" -> Some (String.trim v)
    | _ -> None
  in
  let assoc_opt name json =
    match json with `Assoc fields -> List.assoc_opt name fields | _ -> None
  in
  let string_field name json =
    match assoc_opt name json with Some (`String v) -> Some v | _ -> None
  in
  let client_supports_channel request =
    let cap =
      let params = assoc_opt "params" request in
      let caps = Option.bind params (assoc_opt "capabilities") in
      let exp = Option.bind caps (assoc_opt "experimental") in
      Option.bind exp (assoc_opt "claude/channel")
    in
    match cap with
    | Some (`Bool false) | Some `Null | None -> false
    | Some _ -> true
  in
  let next_channel_cap ~current request =
    match string_field "method" request with
    | Some "initialize" -> client_supports_channel request
    | _ -> current
  in
  let starts_with_ci ~prefix s =
    let p = String.lowercase_ascii prefix in
    let v = String.lowercase_ascii s in
    String.length v >= String.length p && String.sub v 0 (String.length p) = p
  in
  let parse_content_length line =
    match String.index_opt line ':' with
    | None -> None
    | Some i ->
        let n = String.trim (String.sub line (i + 1) (String.length line - i - 1)) in
        int_of_string_opt n
  in
  let rec read_until_blank () =
    let* line = Lwt_io.read_line_opt Lwt_io.stdin in
    match line with
    | None -> Lwt.return_unit
    | Some l -> if String.trim l = "" then Lwt.return_unit else read_until_blank ()
  in
  let rec read_message () =
    let* first = Lwt_io.read_line_opt Lwt_io.stdin in
    match first with
    | None -> Lwt.return_none
    | Some line ->
        let trimmed = String.trim line in
        if trimmed = "" then read_message ()
        else if starts_with_ci ~prefix:"Content-Length:" trimmed then
          match parse_content_length trimmed with
          | None -> Lwt.return_none
          | Some len ->
              let* () = read_until_blank () in
              let* body = Lwt_io.read ~count:len Lwt_io.stdin in
              if String.length body = len then Lwt.return_some body else Lwt.return_none
        else Lwt.return_some line
  in
  let write_message json =
    let body = Yojson.Safe.to_string json in
    let* () = Lwt_io.write_line Lwt_io.stdout body in
    Lwt_io.flush Lwt_io.stdout
  in
  let jsonrpc_error ~id ~code ~message =
    `Assoc
      [ ("jsonrpc", `String "2.0")
      ; ("id", id)
      ; ("error", `Assoc [ ("code", `Int code); ("message", `String message) ])
      ]
  in
  let rec loop ~channel_capable =
    let* msg = read_message () in
    match msg with
    | None -> Lwt.return_unit
    | Some line ->
        let json = try Ok (Yojson.Safe.from_string line) with _ -> Error () in
        match json with
        | Error () ->
            let* () = write_message (jsonrpc_error ~id:`Null ~code:(-32700) ~message:"Parse error") in
            loop ~channel_capable
        | Ok request ->
            let channel_capable = next_channel_cap ~current:channel_capable request in
            let* response = C2c_mcp.handle_request ~broker_root:root request in
            let* () = match response with None -> Lwt.return_unit | Some resp -> write_message resp in
            let* () =
              match (auto_drain, channel_capable, session_id) with
              | false, _, _ -> Lwt.return_unit
              | true, false, _ -> Lwt.return_unit
              | true, true, None -> Lwt.return_unit
              | true, true, Some sid ->
                  let broker = C2c_mcp.Broker.create ~root in
                  let queued = C2c_mcp.Broker.drain_inbox broker ~session_id:sid in
                  let rec emit = function
                    | [] -> Lwt.return_unit
                    | m :: rest ->
                        let* () = write_message (C2c_mcp.channel_notification m) in
                        emit rest
                  in
                  emit queued
            in
            loop ~channel_capable
  in
  Lwt_main.run (loop ~channel_capable:false)

let serve = Cmdliner.Cmd.v (Cmdliner.Cmd.info "serve" ~doc:"Run the MCP server (JSON-RPC over stdio).") serve_cmd

(* --- subcommand: instances ------------------------------------------------ *)

let instances_dir () =
  Filename.concat (Sys.getenv "HOME") (".local" // "share" // "c2c" // "instances")

let list_instance_dirs () =
  let base = instances_dir () in
  if not (Sys.file_exists base) then []
  else begin
    let dirs = Sys.readdir base in
    Array.fold_left (fun acc name ->
      let full = base // name in
      if Sys.is_directory full && Sys.file_exists (full // "config.json") then
        full :: acc
      else acc
    ) [] dirs
  end

let instances_cmd =
  let+ json = json_flag in
  let output_mode = if json then Json else Human in
  let dirs = list_instance_dirs () in
  if dirs = [] then begin
    match output_mode with
    | Json -> print_json (`List [])
    | Human -> Printf.printf "No managed instances.\n"
  end else begin
    let instances =
      List.sort String.compare dirs |> List.map (fun dir ->
        let name = Filename.basename dir in
        let config_path = dir // "config.json" in
        let config =
          try Some (json_read_file config_path) with _ -> None
        in
        let client = match config with
          | Some (`Assoc fields) -> (match List.assoc_opt "client" fields with Some (`String c) -> c | _ -> "?")
          | _ -> "?"
        in
        let status, pid =
          let outer_pid_path = dir // "outer.pid" in
          if Sys.file_exists outer_pid_path then begin
            let pid_s =
              let ic = open_in outer_pid_path in
              Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
                let s = input_line ic in String.trim s)
            in
            match int_of_string_opt pid_s with
            | Some pid ->
                (try
                   ignore (Unix.kill pid 0);
                   ("running", Some pid)
                 with Unix.Unix_error _ -> ("stopped", Some pid))
            | None -> ("unknown", None)
          end else ("stopped", None)
        in
        let fields : (string * Yojson.Safe.t) list =
          [ ("name", `String name)
          ; ("client", `String client)
          ; ("status", `String status)
          ]
        in
        let fields = match pid with
          | Some p -> fields @ [ ("pid", `Int p) ]
          | None -> fields
        in
        `Assoc fields)
    in
    match output_mode with
    | Json -> print_json (`List instances)
    | Human ->
        List.iter (fun (inst : Yojson.Safe.t) ->
          match inst with
          | `Assoc fields ->
              let name = match List.assoc_opt "name" fields with Some (`String s) -> s | _ -> "?" in
              let client = match List.assoc_opt "client" fields with Some (`String s) -> s | _ -> "?" in
              let status = match List.assoc_opt "status" fields with Some (`String s) -> s | _ -> "?" in
              let pid_str = match List.assoc_opt "pid" fields with Some (`Int n) -> Printf.sprintf " (pid %d)" n | _ -> "" in
              Printf.printf "  %-20s %-10s %s%s\n" name client status pid_str
          | _ -> ()
        ) instances
  end

let instances = Cmdliner.Cmd.v (Cmdliner.Cmd.info "instances" ~doc:"List managed c2c instances.") instances_cmd

(* --- subcommand: start ---------------------------------------------------- *)

let start_cmd =
  let client =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"CLIENT" ~doc:"Client to start (claude, codex, kimi, opencode, crush).")
  in
  let name =
    Cmdliner.Arg.(value & opt (some string) None & info [ "name"; "n" ] ~docv:"NAME" ~doc:"Instance name (default: auto-generated).")
  in
  let+ json = json_flag
  and+ client = client
  and+ name_opt = name in
  let output_mode = if json then Json else Human in
  let root = resolve_broker_root () in
  let inst_dir = instances_dir () in
  (try Unix.mkdir inst_dir 0o755 with Unix.Unix_error _ -> ());
  let inst_name = match name_opt with
    | Some n -> n
    | None -> Printf.sprintf "%s-%d" client (Random.int 10000)
  in
  let inst_path = inst_dir // inst_name in
  if Sys.file_exists inst_path then begin
    (match output_mode with
     | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String (Printf.sprintf "instance '%s' already exists" inst_name)) ])
     | Human -> Printf.eprintf "error: instance '%s' already exists. Use 'c2c stop %s' first.\n%!" inst_name inst_name);
    exit 1
  end;
  Unix.mkdir inst_path 0o755;
  let alias = default_alias_for_client client in
  let config =
    `Assoc
      [ ("client", `String client)
      ; ("name", `String inst_name)
      ; ("alias", `String alias)
      ; ("broker_root", `String root)
      ]
  in
  json_write_file (inst_path // "config.json") config;
  match output_mode with
  | Json ->
      print_json (`Assoc
        [ ("ok", `Bool true)
        ; ("name", `String inst_name)
        ; ("client", `String client)
        ; ("alias", `String alias)
        ; ("dir", `String inst_path)
        ])
  | Human ->
      Printf.printf "Instance '%s' registered.\n" inst_name;
      Printf.printf "  client: %s\n" client;
      Printf.printf "  alias:  %s\n" alias;
      Printf.printf "  dir:    %s\n" inst_path;
      Printf.printf "\nFull lifecycle management coming soon.\n";
      Printf.printf "For now use: python3 c2c_start.py start %s -n %s\n" client inst_name

let start = Cmdliner.Cmd.v (Cmdliner.Cmd.info "start" ~doc:"Register a managed c2c instance.") start_cmd

(* --- subcommand: stop ----------------------------------------------------- *)

let stop_cmd =
  let name =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc:"Instance name to stop.")
  in
  let+ json = json_flag
  and+ name = name in
  let output_mode = if json then Json else Human in
  let inst_path = instances_dir () // name in
  if not (Sys.file_exists inst_path) then begin
    (match output_mode with
     | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String (Printf.sprintf "instance '%s' not found" name)) ])
     | Human -> Printf.eprintf "error: instance '%s' not found.\n%!" name);
    exit 1
  end;
  let outer_pid_path = inst_path // "outer.pid" in
  let result =
    if Sys.file_exists outer_pid_path then begin
      let pid_s =
        let ic = open_in outer_pid_path in
        Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
          let s = input_line ic in String.trim s)
      in
      match int_of_string_opt pid_s with
      | Some pid ->
          (try
             Unix.kill pid Sys.sigterm;
             let stopped = ref false in
             for _ = 1 to 10 do
               if not !stopped then begin
                 (try ignore (Unix.kill pid 0) with Unix.Unix_error _ -> stopped := true);
                 if not !stopped then Unix.sleepf 0.5
               end
             done;
             if not !stopped then
               (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
             "stopped"
           with Unix.Unix_error _ -> "stopped")
      | None -> "no pid found"
    end else "no outer.pid"
  in
  match output_mode with
  | Json ->
      print_json (`Assoc [ ("ok", `Bool true); ("name", `String name); ("status", `String result) ])
  | Human ->
      Printf.printf "Instance '%s': %s\n" name result

let stop = Cmdliner.Cmd.v (Cmdliner.Cmd.info "stop" ~doc:"Stop a managed c2c instance.") stop_cmd

(* --- main entry point ----------------------------------------------------- *)

let () =
  exit
    (Cmdliner.Cmd.eval
       (Cmdliner.Cmd.group
          (Cmdliner.Cmd.info "c2c"
             ~version:"0.8.0"
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
                    $(b,status), $(b,register), $(b,tail-log), $(b,my-rooms), \
                    $(b,dead-letter), $(b,prune-rooms), $(b,smoke-test), \
                    $(b,install), $(b,setup), $(b,serve), $(b,start), \
                    $(b,stop), $(b,instances)"
               ; `P "$(b,rooms) — manage N:N chat rooms"
               ])
          [ send; list; whoami; poll_inbox; peek_inbox; send_all; sweep; history
          ; health; status; register; tail_log; my_rooms; dead_letter; prune_rooms
          ; smoke_test; install; setup; serve; start; stop; instances; rooms_group ]))
