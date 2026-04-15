(* c2c CLI — human-friendly command-line interface to the c2c broker.
   When invoked with no arguments, shows help.
   Otherwise dispatches to CLI subcommands. *)

let ( // ) = Filename.concat
open Cmdliner.Term.Syntax
open C2c_mcp

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

let git_repo_toplevel () =
  match
    Unix.open_process_in "git rev-parse --show-toplevel 2>/dev/null"
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

let find_python_script script =
  match git_repo_toplevel () with
  | Some dir ->
      let path = dir // script in
      if Sys.file_exists path then Some path else None
  | None -> None

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

(* --- subcommand: sweep-dryrun --------------------------------------------- *)

let sweep_dryrun_run json =
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in
  let regs = C2c_mcp.Broker.list_registrations broker in
  let reg_by_sid = Hashtbl.create 16 in
  let alias_rows = Hashtbl.create 16 in
  let live_regs = ref [] in
  let dead_regs = ref [] in
  let legacy_regs = ref [] in
  List.iter (fun (r : C2c_mcp.registration) ->
    Hashtbl.replace reg_by_sid r.session_id r;
    let rows = try Hashtbl.find alias_rows r.alias with Not_found -> [] in
    Hashtbl.replace alias_rows r.alias (r :: rows);
    match C2c_mcp.Broker.registration_liveness_state r with
    | C2c_mcp.Broker.Alive -> live_regs := r :: !live_regs
    | C2c_mcp.Broker.Dead -> dead_regs := r :: !dead_regs
    | C2c_mcp.Broker.Unknown -> legacy_regs := r :: !legacy_regs
  ) regs;
  let inbox_count sid =
    try
      let msgs = C2c_mcp.Broker.read_inbox broker ~session_id:sid in
      Some (List.length msgs)
    with _ -> None
  in
  let orphan_inboxes = ref [] in
  let inbox_file_count = ref 0 in
  (try
     let files = Sys.readdir root in
     Array.iter (fun fname ->
       if Filename.check_suffix fname ".inbox.json" then begin
         incr inbox_file_count;
         let sid = String.sub fname 0 (String.length fname - String.length ".inbox.json") in
         if not (Hashtbl.mem reg_by_sid sid) then
           orphan_inboxes := (sid, inbox_count sid) :: !orphan_inboxes
       end
     ) files
   with Sys_error _ -> ());
  let duplicate_aliases = Hashtbl.fold (fun alias rows acc ->
    if List.length rows > 1 then
      (alias, List.map (fun (r : C2c_mcp.registration) -> r.session_id) rows) :: acc
    else acc
  ) alias_rows [] in
  let pid_map = Hashtbl.create 8 in
  List.iter (fun (r : C2c_mcp.registration) ->
    match r.pid with
    | Some pid ->
        let rows = try Hashtbl.find pid_map pid with Not_found -> [] in
        Hashtbl.replace pid_map pid (r :: rows)
    | None -> ()
  ) regs;
  let duplicate_pids = Hashtbl.fold (fun pid rows acc ->
    if List.length rows >= 2 then
      let aliases = List.map (fun (r : C2c_mcp.registration) -> r.alias) rows in
      (pid, aliases) :: acc
    else acc
  ) pid_map [] in
  let nonempty_dead = List.filter_map (fun (r : C2c_mcp.registration) ->
    match inbox_count r.session_id with
    | Some n when n > 0 -> Some (r.session_id, r.alias, n)
    | _ -> None
  ) !dead_regs in
  let nonempty_orphans = List.filter_map (fun (sid, count) ->
    match count with
    | Some n when n > 0 -> Some (sid, n)
    | _ -> None
  ) !orphan_inboxes in
  let risk = List.length nonempty_dead + List.length nonempty_orphans in
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      let json_reg (r : C2c_mcp.registration) =
        `Assoc
          [ ("session_id", `String r.session_id)
          ; ("alias", `String r.alias)
          ; ("pid", match r.pid with None -> `Null | Some p -> `Int p)
          ; ("inbox_messages", match inbox_count r.session_id with None -> `Null | Some n -> `Int n)
          ]
      in
      print_json (`Assoc
        [ ("root", `String root)
        ; ("totals", `Assoc
            [ ("registrations", `Int (List.length regs))
            ; ("live", `Int (List.length !live_regs))
            ; ("legacy_pidless", `Int (List.length !legacy_regs))
            ; ("dead", `Int (List.length !dead_regs))
            ; ("inbox_files_on_disk", `Int !inbox_file_count)
            ; ("orphan_inboxes", `Int (List.length !orphan_inboxes))
            ; ("would_drop_if_swept", `Int (List.length !dead_regs + List.length !orphan_inboxes))
            ; ("nonempty_content_at_risk", `Int risk)
            ])
        ; ("live_regs", `List (List.map json_reg !live_regs))
        ; ("legacy_pidless_regs", `List (List.map json_reg !legacy_regs))
        ; ("dead_regs", `List (List.map json_reg !dead_regs))
        ; ("orphan_inboxes", `List (List.map (fun (sid, count) ->
              `Assoc [ ("session_id", `String sid); ("messages", match count with None -> `Null | Some n -> `Int n) ]
            ) !orphan_inboxes))
        ; ("duplicate_aliases", `Assoc (List.map (fun (alias, sids) ->
              (alias, `List (List.map (fun s -> `String s) sids))
            ) duplicate_aliases))
        ; ("duplicate_pids", `List (List.map (fun (pid, aliases) ->
              `Assoc [ ("pid", `Int pid); ("aliases", `List (List.map (fun a -> `String a) aliases)) ]
            ) duplicate_pids))
        ])
  | Human ->
      Printf.printf "broker root: %s\n\n" root;
      Printf.printf "totals:\n";
      Printf.printf "  registrations          %d\n" (List.length regs);
      Printf.printf "    live                 %d\n" (List.length !live_regs);
      Printf.printf "    legacy (pid=None)    %d\n" (List.length !legacy_regs);
      Printf.printf "    dead                 %d\n" (List.length !dead_regs);
      Printf.printf "  inbox files on disk    %d\n" !inbox_file_count;
      Printf.printf "  orphan inboxes         %d\n" (List.length !orphan_inboxes);
      Printf.printf "  would drop if swept    %d\n" (List.length !dead_regs + List.length !orphan_inboxes);
      if risk > 0 then
        Printf.printf "  NON-EMPTY content risk %d\n" risk;
      if duplicate_aliases <> [] then begin
        Printf.printf "\nduplicate aliases (routing black-hole risk):\n";
        List.iter (fun (alias, sids) ->
          Printf.printf "  %s: %s\n" alias (String.concat ", " sids)
        ) duplicate_aliases
      end;
      if duplicate_pids <> [] then begin
        Printf.printf "\nduplicate PIDs (likely ghost registrations):\n";
        List.iter (fun (pid, aliases) ->
          Printf.printf "  pid=%d: %s\n" pid (String.concat ", " aliases)
        ) duplicate_pids
      end;
      if !dead_regs <> [] then begin
        Printf.printf "\ndead registrations (would be dropped):\n";
        List.iter (fun (r : C2c_mcp.registration) ->
          let suffix = match inbox_count r.session_id with
            | Some n when n > 0 -> Printf.sprintf "  [%d pending msgs]" n
            | _ -> ""
          in
          Printf.printf "  %-20s %s  pid=%s%s\n" r.alias r.session_id
            (match r.pid with None -> "None" | Some p -> string_of_int p)
            suffix
        ) !dead_regs
      end;
      if nonempty_dead <> [] || nonempty_orphans <> [] then begin
        Printf.printf "\nNON-EMPTY content that sweep would delete:\n";
        List.iter (fun (sid, alias, n) ->
          Printf.printf "  %s (%s)  (%d msgs)\n" sid alias n
        ) nonempty_dead;
        List.iter (fun (sid, n) ->
          Printf.printf "  %s  (%d msgs)\n" sid n
        ) nonempty_orphans;
        Printf.printf "  -> consider draining these before running sweep.\n"
      end

let sweep_dryrun_cmd =
  let+ json = json_flag in
  sweep_dryrun_run json

let sweep_dryrun =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "sweep-dryrun" ~doc:"Read-only preview of what sweep would drop (safe during active swarm).")
    sweep_dryrun_cmd

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
         if C2c_mcp.Broker.registration_liveness_state r = C2c_mcp.Broker.Alive then (
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

(* --- subcommand: verify --------------------------------------------------- *)

let verify_cmd =
  let alive_only =
    Cmdliner.Arg.(
      value & flag
      & info [ "alive-only" ] ~doc:"Exclude dead registrations from results.")
  in
  let min_messages =
    Cmdliner.Arg.(
      value
      & opt int 0
      & info [ "min-messages" ] ~docv:"N"
          ~doc:"Minimum total messages (sent+received) to include a peer.")
  in
  let+ json = json_flag
  and+ alive_only = alive_only
  and+ min_messages = min_messages in
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in
  let archive_dir = root // "archive" in
  let sent_by_alias = Hashtbl.create 16 in
  let received_by_sid = Hashtbl.create 16 in
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
                  let rec loop recv_count =
                    match input_line ic with
                    | exception End_of_file -> recv_count
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
                            if from_alias <> "" && from_alias <> "c2c-system"
                            then (
                              let prev =
                                try Hashtbl.find sent_by_alias from_alias
                                with Not_found -> 0
                              in
                              Hashtbl.replace sent_by_alias from_alias
                                (prev + 1)
                            );
                            loop (recv_count + 1)
                          with _ -> loop recv_count
                        ) else loop recv_count
                  in
                  let recv_count = loop 0 in
                  Hashtbl.replace received_by_sid session_id recv_count)
           with Sys_error _ -> ()))
      entries;
  let goal_count = 20 in
  let regs = C2c_mcp.Broker.list_registrations broker in
  let participants =
    List.filter_map
      (fun (r : C2c_mcp.registration) ->
         if alive_only && not (C2c_mcp.Broker.registration_liveness_state r = C2c_mcp.Broker.Alive) then
           None
         else (
           let sent =
             try Hashtbl.find sent_by_alias r.alias with Not_found -> 0
           in
           let received =
             try Hashtbl.find received_by_sid r.session_id with Not_found ->
               try Hashtbl.find received_by_sid r.alias with Not_found -> 0
           in
           if sent + received >= min_messages then
             Some (r.alias, sent, received)
           else None))
      regs
  in
  let goal_met =
    participants <> []
    && List.for_all
         (fun (_, s, r) -> s >= goal_count && r >= goal_count)
         participants
  in
  if json then
    print_json
      (`Assoc
         [ ( "participants"
           , `List
               (List.map
                  (fun (alias, sent, received) ->
                     `Assoc
                       [ ("alias", `String alias)
                       ; ("sent", `Int sent)
                       ; ("received", `Int received)
                       ])
                  participants) )
         ; ("goal_met", `Bool goal_met)
         ; ("source", `String "broker")
         ])
  else (
    List.iter
      (fun (alias, sent, received) ->
         let status =
           if sent >= goal_count && received >= goal_count then "goal_met"
           else "in_progress"
         in
         Printf.printf "%s: sent=%d received=%d status=%s\n" alias sent
           received status)
      participants;
    Printf.printf "goal_met: %s\n" (if goal_met then "yes" else "no"))

let verify =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "verify" ~doc:"Verify c2c message exchange progress.")
    verify_cmd

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
                 ; ("members",
                     `List (List.map (fun a -> `String a) r.ri_members))
                 ; ("alive_members", `List alive_members)
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
            let alive = if r.ri_alive_member_count > 0 then
              Printf.sprintf ", %d alive" r.ri_alive_member_count
            else "" in
            Printf.printf "%s (%d members%s)\n" r.ri_room_id r.ri_member_count alive)
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
                 ; ("members",
                     `List (List.map (fun a -> `String a) r.ri_members))
                 ; ("alive_members", `List alive_members)
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
            let alive = if r.ri_alive_member_count > 0 then
              Printf.sprintf ", %d alive" r.ri_alive_member_count
            else "" in
            Printf.printf "%s (%d members%s)%s\n" r.ri_room_id
              r.ri_member_count alive vis)
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
               if m.rm_alias = m.rm_session_id then
                 Printf.printf "  %s\n" m.rm_alias
               else
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

let room_group =
  Cmdliner.Cmd.group
    ~default:rooms_list_cmd
    (Cmdliner.Cmd.info "room" ~doc:"Alias for rooms.")
    [ rooms_list; rooms_join; rooms_leave; rooms_send; rooms_history; rooms_invite; rooms_members; rooms_visibility ]

(* --- relay subcommands (shell-out to Python) -------------------------------- *)

let relay_serve_cmd =
  let listen =
    Cmdliner.Arg.(value & opt (some string) None & info [ "listen" ] ~docv:"HOST:PORT" ~doc:"Address to listen on (default: 127.0.0.1:7331).")
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:"Bearer token for authentication.")
  in
  let token_file =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token-file" ] ~docv:"PATH" ~doc:"Read bearer token from a file.")
  in
  let storage =
    Cmdliner.Arg.(value & opt (some string) None & info [ "storage" ] ~docv:"memory|sqlite" ~doc:"Storage backend (default: memory).")
  in
  let db_path =
    Cmdliner.Arg.(value & opt (some string) None & info [ "db-path" ] ~docv:"PATH" ~doc:"SQLite database path (use with --storage sqlite).")
  in
  let gc_interval =
    Cmdliner.Arg.(value & opt (some int) None & info [ "gc-interval" ] ~docv:"SECONDS" ~doc:"GC interval in seconds (default: 300).")
  in
  let verbose =
    Cmdliner.Arg.(value & flag & info [ "verbose"; "v" ] ~doc:"Enable verbose output.")
  in
  let+ listen = listen
  and+ token = token
  and+ token_file = token_file
  and+ storage = storage
  and+ db_path = db_path
  and+ gc_interval = gc_interval
  and+ verbose = verbose in
  (* Parse listen address (default 127.0.0.1:7331) *)
  let[@ocaml.warning "-26"] host, port = match listen with
    | None -> ("127.0.0.1", 7331)
    | Some v ->
        (match String.split_on_char ':' v with
         | [host; port_str] ->
             (match int_of_string_opt port_str with
              | Some p -> (host, p)
              | None ->
                  Printf.eprintf "error: invalid port in --listen %S\n%!" v;
                  exit 1)
         | _ ->
             Printf.eprintf "error: --listen must be HOST:PORT (%S)\n%!" v;
             exit 1)
  in
  (* Resolve token: prefer direct value, fall back to file *)
  let token = match token with
    | Some t -> Some t
    | None ->
        (match token_file with
         | Some f ->
             (try Some (Stdlib.input_line (open_in f)) with
              | Sys_error msg ->
                  Printf.eprintf "error reading token file: %s\n%!" msg;
                  exit 1
              | End_of_file ->
                  Printf.eprintf "error: token file %S is empty\n%!" f;
                  exit 1)
         | None -> None)
  in
  (* Convert gc_interval from int option to float (0.0 = disabled) *)
  let gc_interval = match gc_interval with
    | Some i -> float_of_int i
    | None -> 0.0
  in
  (* Storage check: sqlite falls back to Python, memory/native uses native OCaml relay *)
  match storage with
  | Some "sqlite" ->
      (* Fall back to Python for sqlite storage *)
      (match find_python_script "c2c_relay_server.py" with
       | None ->
           Printf.eprintf "error: cannot find c2c_relay_server.py. Run from inside the c2c git repo.\n%!";
           exit 1
       | Some script ->
           let args = [ "python3"; script ] in
           let args = match db_path with None -> args | Some v -> args @ [ "--db-path"; v ] in
           let args = if verbose then args @ [ "--verbose" ] else args in
           Unix.execvp "python3" (Array.of_list args))
  | _ ->
      (* Python relay for memory storage *)
      (match find_python_script "c2c_relay_server.py" with
       | None ->
           Printf.eprintf "error: cannot find c2c_relay_server.py. Run from inside the c2c git repo.
%!";
           exit 1
       | Some script ->
           let args = [ "python3"; script; "--storage"; "memory" ] in
           let args = match listen with None -> args | Some l -> args @ [ "--listen"; l ] in
           let args = match token with None -> args | Some t -> args @ [ "--token"; t ] in
           let args = if verbose then args @ [ "--verbose" ] else args in
           let args = if gc_interval > 0.0 then args @ [ "--gc-interval"; string_of_float gc_interval ] else args in
           Unix.execvp "python3" (Array.of_list args))

let relay_connect_cmd =
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:"Relay server URL.")
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:"Bearer token.")
  in
  let token_file =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token-file" ] ~docv:"PATH" ~doc:"Read bearer token from a file.")
  in
  let node_id =
    Cmdliner.Arg.(value & opt (some string) None & info [ "node-id" ] ~docv:"ID" ~doc:"Node identifier (default: hostname-githash).")
  in
  let broker_root =
    Cmdliner.Arg.(value & opt (some string) None & info [ "broker-root" ] ~docv:"DIR" ~doc:"Broker root directory.")
  in
  let interval =
    Cmdliner.Arg.(value & opt (some int) None & info [ "interval" ] ~docv:"SECONDS" ~doc:"Poll interval in seconds (default: 30).")
  in
  let once =
    Cmdliner.Arg.(value & flag & info [ "once" ] ~doc:"Run once and exit.")
  in
  let verbose =
    Cmdliner.Arg.(value & flag & info [ "verbose"; "v" ] ~doc:"Enable verbose output.")
  in
  let+ relay_url = relay_url
  and+ token = token
  and+ token_file = token_file
  and+ node_id = node_id
  and+ broker_root = broker_root
  and+ interval = interval
  and+ once = once
  and+ verbose = verbose in
  match find_python_script "c2c_relay_connector.py" with
  | None ->
      Printf.eprintf "error: cannot find c2c_relay_connector.py. Run from inside the c2c git repo.\n%!";
      exit 1
  | Some script ->
      let args = [ "python3"; script ] in
      let args = match relay_url with None -> args | Some v -> args @ [ "--relay-url"; v ] in
      let args = match token with None -> args | Some v -> args @ [ "--token"; v ] in
      let args = match token_file with None -> args | Some v -> args @ [ "--token-file"; v ] in
      let args = match node_id with None -> args | Some v -> args @ [ "--node-id"; v ] in
      let args = match broker_root with None -> args | Some v -> args @ [ "--broker-root"; v ] in
      let args = match interval with None -> args | Some v -> args @ [ "--interval"; string_of_int v ] in
      let args = if once then args @ [ "--once" ] else args in
      let args = if verbose then args @ [ "--verbose" ] else args in
      Unix.execvp "python3" (Array.of_list args)

let relay_setup_cmd =
  let url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "url" ] ~docv:"URL" ~doc:"Relay server URL.")
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:"Bearer token.")
  in
  let token_file =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token-file" ] ~docv:"PATH" ~doc:"Read bearer token from a file.")
  in
  let node_id =
    Cmdliner.Arg.(value & opt (some string) None & info [ "node-id" ] ~docv:"ID" ~doc:"Node identifier.")
  in
  let show =
    Cmdliner.Arg.(value & flag & info [ "show" ] ~doc:"Show current relay configuration.")
  in
  let+ url = url
  and+ token = token
  and+ token_file = token_file
  and+ node_id = node_id
  and+ show = show in
  match find_python_script "c2c_relay_config.py" with
  | None ->
      Printf.eprintf "error: cannot find c2c_relay_config.py. Run from inside the c2c git repo.\n%!";
      exit 1
  | Some script ->
      let args = [ "python3"; script ] in
      let args = match url with None -> args | Some v -> args @ [ "--url"; v ] in
      let args = match token with None -> args | Some v -> args @ [ "--token"; v ] in
      let args = match token_file with None -> args | Some v -> args @ [ "--token-file"; v ] in
      let args = match node_id with None -> args | Some v -> args @ [ "--node-id"; v ] in
      let args = if show then args @ [ "--show" ] else args in
      Unix.execvp "python3" (Array.of_list args)

let relay_status_cmd =
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:"Relay server URL.")
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:"Bearer token.")
  in
  let+ relay_url = relay_url
  and+ token = token in
  match find_python_script "c2c_relay_status.py" with
  | None ->
      Printf.eprintf "error: cannot find c2c_relay_status.py. Run from inside the c2c git repo.\n%!";
      exit 1
  | Some script ->
      let args = [ "python3"; script; "status" ] in
      let args = match relay_url with None -> args | Some v -> args @ [ "--relay-url"; v ] in
      let args = match token with None -> args | Some v -> args @ [ "--token"; v ] in
      Unix.execvp "python3" (Array.of_list args)

let relay_list_cmd =
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:"Relay server URL.")
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:"Bearer token.")
  in
  let dead =
    Cmdliner.Arg.(value & flag & info [ "dead" ] ~doc:"Include dead sessions.")
  in
  let+ relay_url = relay_url
  and+ token = token
  and+ dead = dead in
  match find_python_script "c2c_relay_status.py" with
  | None ->
      Printf.eprintf "error: cannot find c2c_relay_status.py. Run from inside the c2c git repo.\n%!";
      exit 1
  | Some script ->
      let args = [ "python3"; script; "list" ] in
      let args = match relay_url with None -> args | Some v -> args @ [ "--relay-url"; v ] in
      let args = match token with None -> args | Some v -> args @ [ "--token"; v ] in
      let args = if dead then args @ [ "--dead" ] else args in
      Unix.execvp "python3" (Array.of_list args)

let relay_rooms_cmd =
  let subcmd =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"list|join|leave|send|history" ~doc:"Rooms subcommand.")
  in
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:"Relay server URL.")
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:"Bearer token.")
  in
  let+ subcmd = subcmd
  and+ relay_url = relay_url
  and+ token = token in
  match find_python_script "c2c_relay_rooms.py" with
  | None ->
      Printf.eprintf "error: cannot find c2c_relay_rooms.py. Run from inside the c2c git repo.\n%!";
      exit 1
  | Some script ->
      let args = [ "python3"; script; subcmd ] in
      let args = match relay_url with None -> args | Some v -> args @ [ "--relay-url"; v ] in
      let args = match token with None -> args | Some v -> args @ [ "--token"; v ] in
      Unix.execvp "python3" (Array.of_list args)

let relay_gc_cmd =
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:"Relay server URL.")
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:"Bearer token.")
  in
  let interval =
    Cmdliner.Arg.(value & opt (some int) None & info [ "interval" ] ~docv:"SECONDS" ~doc:"GC interval in seconds.")
  in
  let once =
    Cmdliner.Arg.(value & flag & info [ "once" ] ~doc:"Run once and exit.")
  in
  let verbose =
    Cmdliner.Arg.(value & flag & info [ "verbose"; "v" ] ~doc:"Enable verbose output.")
  in
  let+ relay_url = relay_url
  and+ token = token
  and+ interval = interval
  and+ once = once
  and+ verbose = verbose in
  match find_python_script "c2c_relay_gc.py" with
  | None ->
      Printf.eprintf "error: cannot find c2c_relay_gc.py. Run from inside the c2c git repo.\n%!";
      exit 1
  | Some script ->
      let args = [ "python3"; script ] in
      let args = match relay_url with None -> args | Some v -> args @ [ "--relay-url"; v ] in
      let args = match token with None -> args | Some v -> args @ [ "--token"; v ] in
      let args = match interval with None -> args | Some v -> args @ [ "--interval"; string_of_int v ] in
      let args = if once then args @ [ "--once" ] else args in
      let args = if verbose then args @ [ "--verbose" ] else args in
      Unix.execvp "python3" (Array.of_list args)

let relay_serve = Cmdliner.Cmd.v (Cmdliner.Cmd.info "serve" ~doc:"Start the relay server.") relay_serve_cmd
let relay_connect = Cmdliner.Cmd.v (Cmdliner.Cmd.info "connect" ~doc:"Run the relay connector.") relay_connect_cmd
let relay_setup = Cmdliner.Cmd.v (Cmdliner.Cmd.info "setup" ~doc:"Configure relay connection.") relay_setup_cmd
let relay_status = Cmdliner.Cmd.v (Cmdliner.Cmd.info "status" ~doc:"Show relay health.") relay_status_cmd
let relay_list = Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List relay peers.") relay_list_cmd
let relay_rooms = Cmdliner.Cmd.v (Cmdliner.Cmd.info "rooms" ~doc:"Manage relay rooms.") relay_rooms_cmd
let relay_gc = Cmdliner.Cmd.v (Cmdliner.Cmd.info "gc" ~doc:"Run relay garbage collection.") relay_gc_cmd

let relay_group =
  Cmdliner.Cmd.group
    ~default:relay_status_cmd
    (Cmdliner.Cmd.info "relay" ~doc:"Cross-machine relay: serve, connect, setup, status, list, rooms, gc.")
    [ relay_serve; relay_connect; relay_setup; relay_status; relay_list; relay_rooms; relay_gc ]

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


(* --- subcommand: install -------------------------------------------------- *)

let install_cmd =
  let dest =
    Cmdliner.Arg.(value & opt (some string) None & info [ "dest"; "d" ] ~docv:"DIR" ~doc:"Install destination (default: ~/.local/bin).")
  in
  let mcp_server =
    Cmdliner.Arg.(value & flag & info [ "mcp-server" ] ~doc:"Also install the c2c MCP server binary as ~/.local/bin/c2c-mcp-server.")
  in
  let+ json = json_flag
  and+ dest_opt = dest
  and+ with_mcp_server = mcp_server in
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
        if not (Sys.file_exists dest_dir && Sys.is_directory dest_dir) then (
          let parent = Filename.dirname dest_dir in
          if not (Sys.file_exists parent && Sys.is_directory parent) then Unix.mkdir parent 0o755;
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
        let extras =
          if with_mcp_server then
            match find_ocaml_server_path () with
            | None -> [ Error "could not find c2c_mcp_server.exe to install" ]
            | Some server_src ->
                let mcp_dest = dest_dir // "c2c-mcp-server" in
                try
                  let ic = open_in_bin server_src in
                  let oc = open_out_bin (mcp_dest ^ ".tmp") in
                  Fun.protect ~finally:(fun () -> close_in ic; close_out oc) (fun () ->
                    let buf = Bytes.create 65536 in
                    let rec copy () =
                      let n = input ic buf 0 (Bytes.length buf) in
                      if n > 0 then (output oc buf 0 n; copy ())
                    in
                    copy ());
                  Unix.chmod (mcp_dest ^ ".tmp") 0o755;
                  Unix.rename (mcp_dest ^ ".tmp") mcp_dest;
                  [ Ok mcp_dest ]
                with Sys_error msg -> [ Error msg ]
          else []
        in
        Ok (dest_path, extras)
      with
      | Unix.Unix_error (code, func, _arg) ->
          Error (Printf.sprintf "%s: %s" func (Unix.error_message code))
      | Sys_error msg -> Error msg
    in
    (match result with
     | Ok (dest_path, extras) ->
         (match output_mode with
          | Json ->
              let items = [ ("ok", `Bool true); ("c2c", `String dest_path) ] in
              let items =
                let extra_json = List.map (fun x -> match x with Ok p -> `String p | Error m -> `String ("error: " ^ m)) extras in
                if extra_json = [] then items else items @ [ ("mcp_server", `List extra_json) ]
              in
              print_json (`Assoc items)
          | Human ->
              Printf.printf "installed c2c to %s\n" dest_path;
              List.iter (function Ok p -> Printf.printf "installed c2c-mcp-server to %s\n" p | Error m -> Printf.eprintf "error: %s\n%!" m) extras)
     | Error msg ->
         (match output_mode with
          | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String msg) ])
          | Human ->
              Printf.eprintf "error: %s\n%!" msg;
              exit 1))

let install = Cmdliner.Cmd.v (Cmdliner.Cmd.info "install" ~doc:"Install c2c binary to ~/.local/bin.") install_cmd

(* --- subcommand: init ---------------------------------------------------- *)

let init_cmd =
  let room_id =
    Cmdliner.Arg.(value & pos ~rev:true 0 (some string) None & info [] ~docv:"ROOM" ~doc:"Optional room to create/join.")
  in
  let+ json = json_flag
  and+ room_id_opt = room_id in
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in
  let regs = C2c_mcp.Broker.list_registrations broker in
  let alive_count =
    List.filter C2c_mcp.Broker.registration_is_alive regs |> List.length
  in
  let output_mode = if json then Json else Human in
  (match output_mode with
   | Json ->
       let peer_aliases = List.sort String.compare (List.map (fun r -> r.C2c_mcp.alias) regs) in
       print_json (`Assoc
         [ ("broker_root", `String root)
         ; ("broker_root_exists", `Bool (Sys.file_exists root && Sys.is_directory root))
         ; ("peer_count", `Int (List.length regs))
         ; ("alive_count", `Int alive_count)
         ; ("peers", `List (List.map (fun a -> `String a) peer_aliases))
         ])
   | Human ->
       Printf.printf "broker root: %s\n" root;
       Printf.printf "peer count:  %d (%d alive)\n" (List.length regs) alive_count;
       if regs <> [] then (
         let aliases = List.sort String.compare (List.map (fun r -> r.C2c_mcp.alias) regs) in
         Printf.printf "peers:       %s\n" (String.concat ", " aliases);
       ) else
         Printf.printf "peers:       (none)\n";
       Printf.printf "\nNext steps:\n";
       Printf.printf "  c2c register          — register as a peer\n";
       Printf.printf "  c2c send ALIAS MSG    — send a message\n";
       Printf.printf "  c2c poll-inbox        — check your inbox\n";
       Printf.printf "  c2c send-all MSG       — broadcast to all peers\n";
       Printf.printf "  c2c rooms join ROOM    — join a chat room\n";
       ());
  (* Optionally join a room *)
  match room_id_opt with
  | None -> ()
  | Some room ->
      let session_id = resolve_session_id () in
      let alias = resolve_alias broker in
      (try
         let (_ : C2c_mcp.room_member list) = C2c_mcp.Broker.join_room broker ~session_id ~alias ~room_id:room in
         match output_mode with
         | Json -> print_json (`Assoc [ ("joined_room", `String room) ])
         | Human -> Printf.printf "joined room: %s\n" room
       with Invalid_argument msg ->
         match output_mode with
         | Json -> print_json (`Assoc [ ("error", `String msg) ])
         | Human -> Printf.eprintf "error: %s\n%!" msg)

let init = Cmdliner.Cmd.v (Cmdliner.Cmd.info "init" ~doc:"Bootstrap the c2c broker and print status.") init_cmd

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
  Buffer.add_string buf (Printf.sprintf "args = [\"exec\", \"--\", \"%s\"]\n" server_path);
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
      ; ("args", `List [ `String "exec"; `String "--"; `String server_path ])
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
              ; ("command", `List [ `String "opam"; `String "exec"; `String "--"; `String server_path ])
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

(* --- setup: Claude PostToolUse hook -------------------------------------- *)

let claude_hook_script = {|
#!/bin/bash
# c2c-inbox-check.sh — PostToolUse hook for c2c auto-delivery in Claude Code
#
# Delegates to c2c-inbox-hook (OCaml binary) which:
#   - Drains the inbox and outputs messages
#   - Self-regulates runtime to prevent Node.js ECHILD race
#
# Required env vars (set by c2c start or the MCP server entry):
#   C2C_MCP_SESSION_ID   — broker session id
#   C2C_MCP_BROKER_ROOT  — absolute path to broker root dir

exec c2c-inbox-hook
|}

let configure_claude_hook () =
  let home = Sys.getenv "HOME" in
  let hooks_dir = home // ".claude" // "hooks" in
  let script_path = hooks_dir // "c2c-inbox-check.sh" in
  let settings_path = home // ".claude" // "settings.json" in
  (try Unix.mkdir hooks_dir 0o755 with Unix.Unix_error _ -> ());
  let oc = open_out script_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc claude_hook_script);
  Unix.chmod script_path 0o755;
  let settings =
    if Sys.file_exists settings_path then json_read_file settings_path
    else `Assoc []
  in
  let hook_entry =
    `Assoc [ ("type", `String "command"); ("command", `String script_path) ]
  in
  let settings = match settings with
    | `Assoc fields ->
        let hooks = match List.assoc_opt "hooks" fields with
          | Some (`Assoc h) -> h
          | _ -> []
        in
        let post_tool_use = match List.assoc_opt "PostToolUse" hooks with
          | Some (`List g) -> g
          | _ -> []
        in
        let target_group, other_groups =
          List.partition (fun g -> match g with
            | `Assoc m -> (match List.assoc_opt "matcher" m with Some (`String ".*") -> true | _ -> false)
            | _ -> false) post_tool_use
        in
        let target_group = match target_group with
          | (`Assoc m) :: _ ->
              let existing_hooks = match List.assoc_opt "hooks" m with
                | Some (`List h) -> h
                | _ -> []
              in
              let has_hook = List.exists (fun h -> match h with
                | `Assoc n -> (match List.assoc_opt "command" n with Some (`String p) -> p = script_path | _ -> false)
                | _ -> false) existing_hooks
              in
              if has_hook then `Assoc m
              else `Assoc (m @ [ ("hooks", `List (existing_hooks @ [ hook_entry ])) ])
          | _ ->
              `Assoc [ ("matcher", `String ".*"); ("hooks", `List [ hook_entry ]) ]
        in
        let hooks = List.filter (fun (k, _) -> k <> "PostToolUse") hooks in
        let hooks = hooks @ [ ("PostToolUse", `List (other_groups @ [ target_group ])) ] in
        let fields = List.filter (fun (k, _) -> k <> "hooks") fields in
        `Assoc (fields @ [ ("hooks", `Assoc hooks) ])
    | _ ->
        `Assoc [ ("hooks", `Assoc [ ("PostToolUse", `List [ `Assoc [ ("matcher", `String ".*"); ("hooks", `List [ hook_entry ]) ] ]) ]) ]
  in
  json_write_file settings_path settings

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
           ; ("args", `List [ `String "exec"; `String "--"; `String server_path ])
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
       (* Write PostToolUse inbox hook to ~/.claude/settings.json *)
       let settings_path = Filename.concat (Sys.getenv "HOME") ".claude" // "settings.json" in
       let hook_script = Filename.concat (Sys.getenv "HOME") ".claude" // "hooks" // "c2c-inbox-check.sh" in
       (* Ensure hook script exists *)
       (try
          let dir = Filename.dirname hook_script in
          if not (Sys.file_exists dir) then begin
            let rec mkdir_p d =
              if Sys.file_exists d then () else begin
                mkdir_p (Filename.dirname d);
                Unix.mkdir d 0o755
              end
            in
            mkdir_p dir
          end;
          let hook_content =
            "#!/bin/bash\n\
             # c2c-inbox-check.sh — PostToolUse hook for c2c auto-delivery in Claude Code\n\
             SESSION_ID=\"${C2C_MCP_SESSION_ID:-}\"\n\
             BROKER_ROOT=\"${C2C_MCP_BROKER_ROOT:-}\"\n\
             [ -z \"$SESSION_ID\" ] && exit 0\n\
             [ -z \"$BROKER_ROOT\" ] && exit 0\n\
             INBOX=\"$BROKER_ROOT/$SESSION_ID.inbox.json\"\n\
             [ -f \"$INBOX\" ] || exit 0\n\
             CONTENT=$(<\"$INBOX\")\n\
             TRIMMED=\"${CONTENT//[[:space:]]/}\"\n\
             [ \"$TRIMMED\" = \"[]\" ] || [ -z \"$TRIMMED\" ] && exit 0\n\
             exec timeout 5 c2c-poll-inbox --file-fallback --session-id \"$SESSION_ID\" --broker-root \"$BROKER_ROOT\"\n"
          in
          let oc = open_out hook_script in
          output_string oc hook_content;
          close_out oc;
          Unix.chmod hook_script 0o755
        with Unix.Unix_error _ -> ());
       (* Add PostToolUse hook entry to settings.json *)
       let hook_registered = ref false in
       let settings =
         if Sys.file_exists settings_path then json_read_file settings_path
         else `Assoc []
       in
       let settings = match settings with
         | `Assoc fields ->
             let hooks = match List.assoc_opt "hooks" fields with
               | Some (`Assoc h) -> h
               | _ -> []
             in
             let post_tool_use = match List.assoc_opt "PostToolUse" hooks with
               | Some (`List entries) -> entries
               | _ -> []
             in
             (* Check if our hook is already registered *)
             let already = List.exists (fun entry ->
               match entry with
               | `Assoc e ->
                   (match List.assoc_opt "hooks" e with
                    | Some (`List hs) ->
                        List.exists (fun h ->
                          match h with
                          | `Assoc h_fields ->
                              (match List.assoc_opt "command" h_fields with
                               | Some (`String cmd) -> cmd = hook_script
                               | _ -> false)
                          | _ -> false) hs
                    | _ -> false)
               | _ -> false
             ) post_tool_use in
             hook_registered := already;
             if not already then begin
               let new_entry = `Assoc [ ("matcher", `String ".*"); ("hooks", `List [ `Assoc [ ("type", `String "command"); ("command", `String hook_script) ] ]) ] in
               let new_post = post_tool_use @ [ new_entry ] in
               let new_hooks = List.filter (fun (k, _) -> k <> "PostToolUse") hooks @ [ ("PostToolUse", `List new_post) ] in
               let new_fields = List.filter (fun (k, _) -> k <> "hooks") fields @ [ ("hooks", `Assoc new_hooks) ] in
               `Assoc new_fields
             end else
               `Assoc fields
         | _ -> `Assoc []
       in
       if not !hook_registered then json_write_file settings_path settings;
       let hook_status = if !hook_registered then "already registered" else "registered" in
       (match output_mode with
        | Json ->
            print_json (`Assoc
              [ ("ok", `Bool true)
              ; ("client", `String "claude")
              ; ("alias", `String alias_val)
              ; ("broker_root", `String root)
              ; ("config", `String claude_json)
              ; ("hook_status", `String hook_status)
              ])
        | Human ->
            Printf.printf "Configured Claude Code for c2c.\n";
            Printf.printf "  alias:       %s\n" alias_val;
            Printf.printf "  broker root: %s\n" root;
            Printf.printf "  config:      %s\n" claude_json;
            Printf.printf "  hook:        %s\n" hook_status;
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

let mcp = Cmdliner.Cmd.v (Cmdliner.Cmd.info "mcp" ~doc:"Alias for serve (runs the MCP server).") serve_cmd

(* --- subcommand: refresh-peer ---------------------------------------------- *)

let refresh_peer_run json target pid_opt session_id_opt dry_run =
  let output_mode = if json then Json else Human in
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in
  let start_time = match pid_opt with
    | Some pid ->
        if not (Sys.file_exists ("/proc/" ^ string_of_int pid)) then begin
          (match output_mode with
           | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String (Printf.sprintf "PID %d is not alive" pid)) ])
           | Human -> Printf.eprintf "error: PID %d is not alive. Refusing to update.\n%!" pid);
          exit 1
        end;
        C2c_mcp.Broker.read_pid_start_time pid
    | None -> None
  in
  C2c_mcp.Broker.with_registry_lock broker (fun () ->
    let regs = C2c_mcp.Broker.list_registrations broker in
    let match_result = List.find_opt (fun (r : C2c_mcp.registration) -> r.alias = target) regs in
    let matched_by, matched_reg = match match_result with
      | Some r -> ("alias", r)
      | None ->
          (match List.find_opt (fun (r : C2c_mcp.registration) -> r.session_id = target) regs with
           | Some r -> ("session_id", r)
           | None ->
               (match output_mode with
                | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String (Printf.sprintf "No registration found for '%s'" target)) ])
                | Human -> Printf.eprintf "error: No registration found for '%s'.\n%!" target);
               exit 1)
    in
    let old_pid = matched_reg.pid in
    if pid_opt = None then begin
      if C2c_mcp.Broker.registration_is_alive matched_reg then
        match output_mode with
        | Json -> print_json (`Assoc
            [ ("alias", `String matched_reg.alias); ("matched_by", `String matched_by)
            ; ("status", `String "already_alive")
            ; ("pid", match old_pid with None -> `Null | Some p -> `Int p) ])
        | Human ->
            Printf.printf "Registration for '%s' is already alive (pid=%s). No change needed.\n"
              matched_reg.alias (match old_pid with None -> "None" | Some p -> string_of_int p)
      else begin
        (match output_mode with
         | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String "Dead PID. Provide --pid.") ])
         | Human -> Printf.eprintf "error: Dead PID. Provide --pid <live-pid> to refresh.\n%!");
        exit 1
      end
    end else begin
      let new_regs = List.map (fun (r : C2c_mcp.registration) ->
        if r.session_id = matched_reg.session_id then
          { r with pid = pid_opt; pid_start_time = start_time }
        else r
      ) regs in
      if dry_run then
        match output_mode with
        | Json -> print_json (`Assoc
            [ ("alias", `String matched_reg.alias); ("matched_by", `String matched_by)
            ; ("status", `String "dry_run")
            ; ("old_pid", match old_pid with None -> `Null | Some p -> `Int p)
            ; ("new_pid", `Int (Option.get pid_opt))
            ; ("new_pid_start_time", match start_time with None -> `Null | Some t -> `Int t) ])
        | Human ->
            Printf.printf "[dry-run] Would update '%s': pid %s -> %d\n"
              matched_reg.alias
              (match old_pid with None -> "None" | Some p -> string_of_int p)
              (Option.get pid_opt)
      else begin
        C2c_mcp.Broker.save_registrations broker new_regs;
        match output_mode with
        | Json -> print_json (`Assoc
            [ ("ok", `Bool true); ("alias", `String matched_reg.alias)
            ; ("matched_by", `String matched_by); ("status", `String "updated")
            ; ("old_pid", match old_pid with None -> `Null | Some p -> `Int p)
            ; ("new_pid", `Int (Option.get pid_opt))
            ; ("new_pid_start_time", match start_time with None -> `Null | Some t -> `Int t) ])
        | Human ->
            Printf.printf "Updated '%s': pid %s -> %d\n"
              matched_reg.alias
              (match old_pid with None -> "None" | Some p -> string_of_int p)
              (Option.get pid_opt)
      end
    end)

let refresh_peer_cmd =
  let target =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ALIAS_OR_SESSION_ID" ~doc:"Alias or session ID of the peer to refresh.")
  in
  let pid_opt =
    Cmdliner.Arg.(value & opt (some int) None & info [ "pid" ] ~docv:"PID" ~doc:"New live PID to point the registration at.")
  in
  let session_id_opt =
    Cmdliner.Arg.(value & opt (some string) None & info [ "session-id" ] ~docv:"ID" ~doc:"Correct session_id to write (fixes drift).")
  in
  let dry_run =
    Cmdliner.Arg.(value & flag & info [ "dry-run" ] ~doc:"Show what would change without writing.")
  in
  let+ json = json_flag
  and+ target = target
  and+ pid_opt = pid_opt
  and+ session_id_opt = session_id_opt
  and+ dry_run = dry_run in
  refresh_peer_run json target pid_opt session_id_opt dry_run

let refresh_peer =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "refresh-peer" ~doc:"Refresh a stale broker registration to a new live PID.")
    refresh_peer_cmd

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
  let alias =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias" ] ~docv:"ALIAS" ~doc:"Custom alias (defaults to instance name).")
  in
  let bin =
    Cmdliner.Arg.(value & opt (some string) None & info [ "bin" ] ~docv:"PATH" ~doc:"Custom binary path or name to launch.")
  in
  let session_id =
    Cmdliner.Arg.(value & opt (some string) None & info [ "session-id" ] ~docv:"UUID" ~doc:"Explicit session UUID (overrides auto-generated).")
  in
  let+ client = client
  and+ name_opt = name
  and+ alias_opt = alias
  and+ bin_opt = bin
  and+ session_id_opt = session_id in
  let name = Option.value name_opt ~default:(C2c_start.default_name client) in
  exit (C2c_start.cmd_start ~client ~name ~extra_args:[] ?binary_override:bin_opt ?alias_override:alias_opt ?session_id_override:session_id_opt ())

let start = Cmdliner.Cmd.v (Cmdliner.Cmd.info "start" ~doc:"Start a managed c2c instance.") start_cmd

(* --- subcommand: stop ----------------------------------------------------- *)


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

let restart_cmd =
  let name =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc:"Instance name to restart.")
  in
  let+ name = name in
  exit (C2c_start.cmd_restart name)

let restart = Cmdliner.Cmd.v (Cmdliner.Cmd.info "restart" ~doc:"Restart a managed c2c instance.") restart_cmd

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
                    $(b,send-all), $(b,sweep), $(b,sweep-dryrun), $(b,history), \
                    $(b,health), $(b,status), $(b,verify), $(b,register), \
                    $(b,refresh-peer), $(b,tail-log), $(b,my-rooms), $(b,dead-letter), \
                    $(b,prune-rooms), $(b,smoke-test), $(b,init), $(b,install), \
                    $(b,setup), $(b,serve), $(b,mcp), $(b,start), $(b,stop), \
                    $(b,restart), $(b,instances)"
               ; `P "$(b,rooms) — manage N:N chat rooms"
               ; `P "$(b,relay) — cross-machine relay: serve, connect, setup, status, list, rooms, gc"
               ])
          [ send; list; whoami; poll_inbox; peek_inbox; send_all; sweep
          ; sweep_dryrun; history; health; status; verify; register; refresh_peer
          ; tail_log; my_rooms; dead_letter; prune_rooms; smoke_test; init; install; setup
          ; serve; mcp; start; stop; restart; instances; rooms_group; room_group; relay_group ]))
