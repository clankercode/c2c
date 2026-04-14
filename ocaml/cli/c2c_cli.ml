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
    Cmdliner.Arg.(non_empty & pos_right 1 string [] & info [] ~docv:"MSG" ~doc:"Message body (remaining args joined with spaces).")
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
  let _all =
    Cmdliner.Arg.(value & flag & info [ "all"; "a" ] ~doc:"Show all info.")
  in
  let+ json = json_flag in
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
          (fun r ->
            let alive_str =
              match
                C2c_mcp.Broker.registration_liveness_state r
              with
              | C2c_mcp.Broker.Alive -> "alive"
              | C2c_mcp.Broker.Dead -> "dead "
              | C2c_mcp.Broker.Unknown -> "???  "
            in
            let pid_str =
              match r.pid with
              | Some p -> Printf.sprintf " pid=%d" p
              | None -> ""
            in
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
    Cmdliner.Arg.(non_empty & pos_right 0 string [] & info [] ~docv:"MSG" ~doc:"Message body.")
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

(* --- rooms subcommands ---------------------------------------------------- *)

let rooms_send_cmd =
  let room_id =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ROOM" ~doc:"Room ID.")
  in
  let message =
    Cmdliner.Arg.(non_empty & pos_right 1 string [] & info [] ~docv:"MSG" ~doc:"Message body.")
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

let rooms_list = Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List all rooms.") rooms_list_cmd
let rooms_join = Cmdliner.Cmd.v (Cmdliner.Cmd.info "join" ~doc:"Join a room.") rooms_join_cmd
let rooms_leave = Cmdliner.Cmd.v (Cmdliner.Cmd.info "leave" ~doc:"Leave a room.") rooms_leave_cmd
let rooms_send = Cmdliner.Cmd.v (Cmdliner.Cmd.info "send" ~doc:"Send a message to a room.") rooms_send_cmd
let rooms_history = Cmdliner.Cmd.v (Cmdliner.Cmd.info "history" ~doc:"Show room message history.") rooms_history_cmd
let rooms_invite = Cmdliner.Cmd.v (Cmdliner.Cmd.info "invite" ~doc:"Invite an alias to a room.") rooms_invite_cmd

let rooms_group =
  Cmdliner.Cmd.group
    (Cmdliner.Cmd.info "rooms" ~doc:"Manage persistent N:N rooms.")
    [ rooms_list; rooms_join; rooms_leave; rooms_send; rooms_history; rooms_invite ]

(* --- main entry point ----------------------------------------------------- *)

let send = Cmdliner.Cmd.v (Cmdliner.Cmd.info "send" ~doc:"Send a message to a registered peer alias.") send_cmd
let list = Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List registered C2C peers.") list_cmd
let whoami = Cmdliner.Cmd.v (Cmdliner.Cmd.info "whoami" ~doc:"Show current c2c identity.") whoami_cmd
let poll_inbox = Cmdliner.Cmd.v (Cmdliner.Cmd.info "poll-inbox" ~doc:"Drain (or peek at) your inbox.") poll_inbox_cmd
let send_all = Cmdliner.Cmd.v (Cmdliner.Cmd.info "send-all" ~doc:"Broadcast a message to all peers.") send_all_cmd
let sweep = Cmdliner.Cmd.v (Cmdliner.Cmd.info "sweep" ~doc:"Remove dead registrations and orphan inboxes.") sweep_cmd
let history = Cmdliner.Cmd.v (Cmdliner.Cmd.info "history" ~doc:"Show archived inbox messages.") history_cmd
let health = Cmdliner.Cmd.v (Cmdliner.Cmd.info "health" ~doc:"Show broker health diagnostics.") health_cmd

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
                    $(b,send-all), $(b,sweep), $(b,history), $(b,health)"
               ; `P "$(b,rooms) — manage N:N chat rooms"
               ])
          [ send; list; whoami; poll_inbox; send_all; sweep; history; health; rooms_group ]))
