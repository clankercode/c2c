(* c2c CLI — human-friendly command-line interface to the c2c broker.
   When invoked with no arguments, shows help.
   Otherwise dispatches to CLI subcommands. *)

let ( // ) = Filename.concat
open Cmdliner.Term.Syntax
open C2c_mcp

(* Resolve the Claude config dir.
   Prefers CLAUDE_CONFIG_DIR if set, otherwise resolves ~/.claude as a symlink
   (so profile dirs like ~/.claude-mm/ work via the symlink). *)
let resolve_claude_dir () =
  match Sys.getenv_opt "CLAUDE_CONFIG_DIR" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ ->
      let dot_claude = Filename.concat (Sys.getenv "HOME") ".claude" in
      (try
         let rec resolve_link p max_depth =
           if max_depth <= 0 then p
           else
             let stat = Unix.lstat p in
             if stat.Unix.st_kind = Unix.S_LNK then
               let target = Unix.readlink p in
               let resolved = if Filename.is_relative target then
                                Filename.concat (Filename.dirname p) target
                              else target in
               resolve_link resolved (max_depth - 1)
             else p
         in
         resolve_link dot_claude 10
       with _ -> dot_claude)

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

let git_shorthash () =
  match
    Unix.open_process_in "git rev-parse --short HEAD 2>/dev/null"
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
      if line <> "" && int_of_string_opt line = None then Some line else None
  | exception _ -> None

let version_string () =
  let base = "0.8.0" in
  let t = Unix.gmtime (Unix.gettimeofday ()) in
  let ts = Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (t.Unix.tm_year + 1900) (t.Unix.tm_mon + 1) t.Unix.tm_mday t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec in
  match git_shorthash () with
  | Some h -> Printf.sprintf "%s %s %s" base h ts
  | None -> Printf.sprintf "%s %s" base ts

let find_python_script script =
  match git_repo_toplevel () with
  | Some dir ->
      let path = dir // script in
      if Sys.file_exists path then Some path else None
  | None -> None

let xdg_state_home () =
  match Sys.getenv_opt "XDG_STATE_HOME" with
  | Some v when String.trim v <> "" -> String.trim v
  | _ ->
      (match Sys.getenv_opt "HOME" with
       | Some h when String.trim h <> "" -> String.trim h // ".local" // "state"
       | _ -> "/tmp")

let fallback_broker_root () = xdg_state_home () // "c2c" // "default" // "mcp"

(* Pure path resolution — no side effects. The broker creates the directory
   lazily on first use via [Broker.ensure_root]. Callers that need the
   directory to exist on disk (e.g. to write auxiliary files at setup time)
   should create it themselves. *)
let resolve_broker_root () =
  let abs_path p =
    if Filename.is_relative p then Sys.getcwd () // p else p
  in
  match broker_root_from_env () with
  | Some dir -> abs_path dir
  | None -> (
      match git_common_dir () with
      | Some git_dir -> abs_path git_dir // "c2c" // "mcp"
      | None -> fallback_broker_root ())

(* --- session / alias resolution ------------------------------------------- *)

let env_session_id () =
  match Sys.getenv_opt "C2C_MCP_SESSION_ID" with
  | Some v when String.trim v <> "" -> Some (String.trim v)
  | _ -> None

let env_auto_alias () =
  match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
  | Some v when String.trim v <> "" -> Some (String.trim v)
  | _ -> None

let resolve_alias ?(override : string option = None) broker =
  match override with
  | Some a when String.trim a <> "" -> String.trim a
  | _ ->
  match env_session_id () with
  | None -> (
      match env_auto_alias () with
      | Some a -> a
      | None ->
          Printf.eprintf
            "error: cannot determine your alias. Set C2C_MCP_AUTO_REGISTER_ALIAS \
             or C2C_MCP_SESSION_ID.\n\
             hint: Are you running this from inside the coding agent? Have you run `c2c install <client>` for your client?\n%!";
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
  let from_override =
    Cmdliner.Arg.(value & opt (some string) None & info [ "from"; "F" ] ~docv:"ALIAS" ~doc:"Override sender alias. Useful for operators/tests running outside an agent session; equivalent to setting C2C_MCP_AUTO_REGISTER_ALIAS.")
  in
  let+ json = json_flag
  and+ to_alias = to_alias
  and+ message = message
  and+ from_override = from_override in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let from_alias = resolve_alias ~override:from_override broker in
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
  let from_override =
    Cmdliner.Arg.(value & opt (some string) None & info [ "from"; "F" ] ~docv:"ALIAS" ~doc:"Override sender alias. Useful for operators/tests running outside an agent session.")
  in
  let+ json = json_flag
  and+ exclude = exclude
  and+ message = message
  and+ from_override = from_override in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let from_alias = resolve_alias ~override:from_override broker in
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

let check_supervisor_config () =
  let env_sup =
    match Sys.getenv_opt "C2C_PERMISSION_SUPERVISOR" with
    | Some v when String.trim v <> "" -> Some v
    | _ -> (match Sys.getenv_opt "C2C_SUPERVISORS" with Some v when String.trim v <> "" -> Some v | _ -> None)
  in
  match env_sup with
  | Some v -> (`Green, Printf.sprintf "supervisor: %s (from env)" v)
  | None ->
      let sidecar = Filename.concat (Sys.getcwd ()) ".opencode/c2c-plugin.json" in
      let sidecar_sup =
        if Sys.file_exists sidecar then
          try
            let ic = open_in sidecar in
            let data = Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
              let n = in_channel_length ic in really_input_string ic n) in
            let j = Yojson.Safe.from_string data in
            let sup = Yojson.Safe.Util.(j |> member "supervisors") in
            let single = Yojson.Safe.Util.(j |> member "supervisor") in
            (match sup, single with
             | `List items, _ ->
                 let names = List.filter_map (function `String s -> Some s | _ -> None) items in
                 if names <> [] then Some (String.concat ", " names) else None
             | _, `String s when s <> "" -> Some s
             | _ -> None)
          with _ -> None
        else None
      in
      (match sidecar_sup with
       | Some v -> (`Green, Printf.sprintf "supervisor: %s (from sidecar)" v)
       | None -> (`Yellow, "supervisor: coordinator1 (default — run: c2c init --supervisor <alias> or c2c repo set supervisor <alias>)"))

let check_relay_http () =
  let url = match Sys.getenv_opt "C2C_RELAY_URL" with Some v when v <> "" -> v | _ -> "https://relay.c2c.im" in
  try
    let client = C2c_mcp.Relay.Relay_client.make ~timeout:5.0 url in
    let result = Lwt_main.run (C2c_mcp.Relay.Relay_client.health client) in
    let version = Yojson.Safe.Util.(result |> member "version" |> to_string_option |> Option.value ~default:"?") in
    let git_hash = Yojson.Safe.Util.(result |> member "git_hash" |> to_string_option |> Option.value ~default:"?") in
    let auth_mode = Yojson.Safe.Util.(result |> member "auth_mode" |> to_string_option |> Option.value ~default:"unknown") in
    let ok = Yojson.Safe.Util.(result |> member "ok") = `Bool true in
    if ok then
      let auth_str = match auth_mode with
        | "dev" -> " ⚠ dev mode (no auth)"
        | "prod" -> " prod mode"
        | _ -> ""  (* field absent in older relay versions — suppress *)
      in
      (`Green, Printf.sprintf "relay: reachable — %s @ %s%s (%s)" version git_hash auth_str url)
    else (`Red, Printf.sprintf "relay: error response from %s" url)
  with exn ->
    (`Red, Printf.sprintf "relay: unreachable (%s)" (Printexc.to_string exn))

let check_plugin_installs () =
  let home = try Sys.getenv "HOME" with Not_found -> "" in
  let results = ref [] in
  let add r = results := r :: !results in

  (* Claude Code: PostToolUse hook in ~/.claude/settings.json *)
  let settings_path = home // ".claude" // "settings.json" in
  (if Sys.file_exists settings_path then
     try
       let ic = open_in settings_path in
       let data = Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
         let n = in_channel_length ic in really_input_string ic n) in
       let j = Yojson.Safe.from_string data in
       let hooks_str = Yojson.Safe.to_string Yojson.Safe.Util.(j |> member "hooks") in
       if String.length hooks_str > 2 && (let needle = "c2c" in
         let nl = String.length needle and ll = String.length hooks_str in
         let found = ref false in
         for i = 0 to ll - nl do
           if String.sub hooks_str i nl = needle then found := true
         done; !found)
       then add (`Green, "claude-code: PostToolUse hook configured")
       else add (`Yellow, "claude-code: no c2c hook (run: c2c install claude)")
     with _ -> add (`Gray, "claude-code: could not read settings.json")
   else add (`Gray, "claude-code: settings.json not found"));

  (* OpenCode: project-level or global plugin *)
  let project_plugin = (Sys.getcwd ()) // ".opencode" // "plugins" // "c2c.ts" in
  let global_plugin = home // ".config" // "opencode" // "plugins" // "c2c.ts" in
  let global_size = try (Unix.stat global_plugin).Unix.st_size with Unix.Unix_error _ -> 0 in
  (if Sys.file_exists project_plugin then
     add (`Green, "opencode: plugin installed (project-level)")
   else if Sys.file_exists global_plugin && global_size >= 1024 then
     add (`Green, "opencode: plugin installed (global)")
   else if Sys.file_exists global_plugin then
     add (`Yellow, Printf.sprintf "opencode: global plugin is a stub (%d bytes) — run: c2c install opencode from c2c repo" global_size)
   else
     add (`Yellow, "opencode: plugin not installed (run: c2c install opencode)"));

  List.rev !results

(* Scan for running deprecated PTY-based wake daemons.
   Returns a list of (script_name, pids, fix_hint) for any that are running. *)
let check_deprecated_daemons () :
    (string * int list * string) list =
  let patterns =
    [ ( "c2c_claude_wake_daemon.py"
      , "deprecated: use /loop 4m in Claude Code instead" )
    ; ( "c2c_opencode_wake_daemon.py"
      , "deprecated: TypeScript plugin handles delivery; kill this daemon" )
    ; ( "c2c_kimi_wake_daemon.py"
      , "deprecated: use Wire bridge (c2c wire-daemon start) instead" )
    ; ( "c2c_crush_wake_daemon.py"
      , "deprecated: Crush PTY wake is unreliable; no replacement" )
    ]
  in
  List.filter_map
    (fun (script, hint) ->
       (* Require python in the command to avoid matching pgrep/shell wrappers
          that contain the script name as part of an eval or snapshot string. *)
       let pattern = "python.*" ^ script in
       let cmd =
         Printf.sprintf "pgrep -a -f %s 2>/dev/null" (Filename.quote pattern)
       in
       let ic = Unix.open_process_in cmd in
       let lines = ref [] in
       (try
          while true do
            lines := input_line ic :: !lines
          done
        with End_of_file -> ());
       ignore (Unix.close_process_in ic);
       (* Filter: only keep lines where the process executable is python,
          not shell wrappers (zsh/bash eval) that contain the script name
          as part of a snapshot or pgrep invocation string. *)
       let is_python_proc line =
         let parts = String.split_on_char ' ' (String.trim line) in
         match parts with
         | _ :: cmd :: _ ->
             let base = Filename.basename cmd in
             let lc = String.lowercase_ascii base in
             String.length lc >= 6
             && String.sub lc 0 6 = "python"
         | _ -> false
       in
       let pids =
         List.filter_map
           (fun line ->
              if not (is_python_proc line) then None
              else
                let line = String.trim line in
                match String.split_on_char ' ' line with
                | pid_str :: _ -> (
                    match int_of_string_opt pid_str with
                    | Some pid -> Some pid
                    | None -> None)
                | [] -> None)
           !lines
       in
       if pids = [] then None else Some (script, pids, hint))
    patterns

(* PTY-inject capability check: managed kimi/codex/opencode deliver daemons
   use pidfd_getfd, which needs CAP_SYS_PTRACE when yama ptrace_scope >= 1.
   This surfaces the "forgot to setcap python3" footgun in `c2c health`. *)
let check_pty_inject_capability () : [ `Ok | `Missing_cap of string | `Unknown ] =
  let py =
    let ic = Unix.open_process_in "command -v python3 2>/dev/null" in
    let line = try input_line ic with End_of_file -> "" in
    ignore (Unix.close_process_in ic);
    if String.trim line = "" then "python3" else String.trim line
  in
  let yama_ok =
    try
      let ic = open_in "/proc/sys/kernel/yama/ptrace_scope" in
      let v = Fun.protect ~finally:(fun () -> close_in ic) (fun () -> String.trim (input_line ic)) in
      v = "0"
    with _ -> false
  in
  if yama_ok then `Ok
  else
    let cmd = Printf.sprintf "getcap %s 2>/dev/null" (Filename.quote py) in
    let ic = Unix.open_process_in cmd in
    let line = try input_line ic with End_of_file -> "" in
    ignore (Unix.close_process_in ic);
    let has_cap =
      let needle = "cap_sys_ptrace" in
      let nl = String.length needle and ll = String.length line in
      let rec loop i =
        if i + nl > ll then false
        else if String.sub line i nl = needle then true
        else loop (i + 1)
      in
      loop 0
    in
    if line = "" then `Missing_cap py
    else if has_cap then `Ok
    else `Missing_cap py

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
  let pty_cap = check_pty_inject_capability () in
  let pty_cap_str = match pty_cap with
    | `Ok -> "ok"
    | `Missing_cap py -> Printf.sprintf "missing — `sudo setcap cap_sys_ptrace=ep %s` (only needed for Codex PTY notify daemon; OpenCode + Kimi use non-PTY delivery)" py
    | `Unknown -> "unknown"
  in
  let stale_daemons = check_deprecated_daemons () in
  let supervisor_check = check_supervisor_config () in
  let relay_check = check_relay_http () in
  let plugin_checks = check_plugin_installs () in
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      let stale_json =
        `List
          (List.map
             (fun (script, pids, hint) ->
                `Assoc
                  [ ("script", `String script)
                  ; ("pids", `List (List.map (fun p -> `Int p) pids))
                  ; ("fix", `String hint)
                  ])
             stale_daemons)
      in
      let color_str = function `Green -> "green" | `Yellow -> "yellow" | `Red -> "red" | `Gray -> "gray" in
      let plugin_json = `List (List.map (fun (c, msg) -> `Assoc [("status", `String (color_str c)); ("message", `String msg)]) plugin_checks) in
      let (sup_col, sup_msg) = supervisor_check in
      let (rel_col, rel_msg) = relay_check in
      print_json
        (`Assoc
          [ ("broker_root", `String root)
          ; ("root_exists", `Bool root_exists)
          ; ("registry_exists", `Bool registry_exists)
          ; ("dead_letter_exists", `Bool dead_letter_exists)
          ; ("registrations", `Int (List.length regs))
          ; ("alive", `Int alive_count)
          ; ("rooms", `Int (List.length rooms))
          ; ("pty_inject_cap", `String (match pty_cap with `Ok -> "ok" | `Missing_cap _ -> "missing" | `Unknown -> "unknown"))
          ; ("stale_deprecated_daemons", stale_json)
          ; ("supervisor", `Assoc [("status", `String (color_str sup_col)); ("message", `String sup_msg)])
          ; ("relay", `Assoc [("status", `String (color_str rel_col)); ("message", `String rel_msg)])
          ; ("plugins", plugin_json)
          ])
  | Human ->
      let icon = function `Green -> "✓" | `Yellow -> "⚠" | `Red -> "✗" | `Gray -> "–" in
      Printf.printf "broker root:    %s\n" root;
      Printf.printf "root exists:    %s\n" (string_of_bool root_exists);
      Printf.printf "registry:       %s\n" (string_of_bool registry_exists);
      Printf.printf "dead-letter:    %s\n" (string_of_bool dead_letter_exists);
      Printf.printf "registrations:  %d (%d alive)\n"
        (List.length regs) alive_count;
      Printf.printf "rooms:          %d\n" (List.length rooms);
      Printf.printf "pty-inject cap: %s\n" pty_cap_str;
      let (sup_col, sup_msg) = supervisor_check in
      Printf.printf "%s %s\n" (icon sup_col) sup_msg;
      let (rel_col, rel_msg) = relay_check in
      Printf.printf "%s %s\n" (icon rel_col) rel_msg;
      List.iter (fun (c, msg) -> Printf.printf "%s %s\n" (icon c) msg) plugin_checks;
      if stale_daemons = [] then
        Printf.printf "stale daemons:  none\n"
      else begin
        Printf.printf "stale daemons:  %d deprecated process(es) running!\n"
          (List.length stale_daemons);
        List.iter
          (fun (script, pids, hint) ->
             let pid_str =
               String.concat ", " (List.map string_of_int pids)
             in
             Printf.printf "  ⚠  %s (pid %s)\n" script pid_str;
             Printf.printf "     fix: %s\n" hint;
             Printf.printf "     kill: kill %s\n" pid_str)
          stale_daemons
      end

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
            Printf.eprintf
              "error: no alias specified and C2C_MCP_AUTO_REGISTER_ALIAS not set.\n\
               hint: Are you running this from inside the coding agent? Have you run `c2c install <client>` for your client?\n\
               Pass --alias ALIAS to register explicitly.\n%!";
            exit 1)
  in
  let session_id =
    match session_id_opt with
    | Some s -> s
    | None -> (
        match env_session_id () with
        | Some s -> s
        | None ->
            Printf.eprintf
              "error: no session ID specified and C2C_MCP_SESSION_ID not set.\n\
               hint: Are you running this from inside the coding agent? Have you run `c2c install <client>` for your client?\n\
               Pass --session-id ID to specify explicitly.\n%!";
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
  let from_override =
    Cmdliner.Arg.(value & opt (some string) None & info [ "from"; "F" ] ~docv:"ALIAS" ~doc:"Override sender alias. Useful for operators/tests running outside an agent session.")
  in
  let+ json = json_flag
  and+ room_id = room_id
  and+ message = message
  and+ from_override = from_override in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let from_alias = resolve_alias ~override:from_override broker in
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
  let history_limit =
    Cmdliner.Arg.(value & opt int 20 & info [ "history-limit" ] ~docv:"N"
      ~doc:"Recent messages to show after joining (default 20, max 200, 0 to skip).")
  in
  let+ json = json_flag
  and+ room_id = room_id
  and+ history_limit = history_limit in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let alias = resolve_alias broker in
  let session_id = resolve_session_id () in
  let output_mode = if json then Json else Human in
  (try
     let members =
       C2c_mcp.Broker.join_room broker ~room_id ~alias ~session_id
     in
     let backfill =
       if history_limit <= 0 then []
       else C2c_mcp.Broker.read_room_history broker ~room_id
              ~limit:(min history_limit 200) ()
     in
     match output_mode with
     | Json ->
         print_json
           (`Assoc
             [ ("room_id", `String room_id)
             ; ("members", `List (List.map (fun (m : C2c_mcp.room_member) ->
                   `Assoc [("alias", `String m.rm_alias); ("session_id", `String m.rm_session_id)])
                 members))
             ; ("history", `List (List.map (fun (m : C2c_mcp.room_message) ->
                   `Assoc [("ts", `Float m.rm_ts); ("from_alias", `String m.rm_from_alias);
                           ("content", `String m.rm_content)])
                 backfill))
             ])
     | Human ->
         Printf.printf "Joined room %s (%d members)\n" room_id (List.length members);
         List.iter (fun (m : C2c_mcp.room_member) -> Printf.printf "  %s\n" m.rm_alias) members;
         if backfill <> [] then begin
           Printf.printf "\nRecent history (%d msgs):\n" (List.length backfill);
           List.iter (fun (m : C2c_mcp.room_message) ->
             let t = Unix.gmtime m.rm_ts in
             Printf.printf "[%02d:%02d] <%s> %s\n"
               t.tm_hour t.tm_min m.rm_from_alias m.rm_content) backfill
         end
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

let rooms_delete_cmd =
  let room_id =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ROOM" ~doc:"Room ID to delete (must have zero members).")
  in
  let+ json = json_flag
  and+ room_id = room_id in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let output_mode = if json then Json else Human in
  (try
     C2c_mcp.Broker.delete_room broker ~room_id;
     match output_mode with
     | Json ->
         print_json
           (`Assoc [ ("room_id", `String room_id); ("deleted", `Bool true) ])
     | Human ->
         Printf.printf "Deleted room %s\n" room_id
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

let parse_since_str s =
  let s = String.trim s in
  let len = String.length s in
  if len = 0 then 0.0
  else
    let last = s.[len - 1] in
    let num_part = String.sub s 0 (len - 1) in
    match last with
    | 'h' -> (try Unix.gettimeofday () -. float_of_string num_part *. 3600. with _ -> 0.0)
    | 'd' -> (try Unix.gettimeofday () -. float_of_string num_part *. 86400. with _ -> 0.0)
    | 'm' when len > 1 && s.[len-2] >= '0' && s.[len-2] <= '9' ->
        (try Unix.gettimeofday () -. float_of_string num_part *. 60. with _ -> 0.0)
    | _ -> (try float_of_string s with _ ->
        (* Try ISO 8601: YYYY-MM-DDTHH:MM:SSZ *)
        try
          Scanf.sscanf s "%d-%d-%dT%d:%d:%d"
            (fun yr mo dy hr mi se ->
               let t = { Unix.tm_year = yr - 1900; tm_mon = mo - 1; tm_mday = dy;
                         tm_hour = hr; tm_min = mi; tm_sec = se;
                         tm_wday = 0; tm_yday = 0; tm_isdst = false } in
               fst (Unix.mktime t))
        with _ -> 0.0)

let rooms_history_cmd =
  let room_id =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ROOM" ~doc:"Room ID.")
  in
  let limit =
    Cmdliner.Arg.(value & opt int 50 & info [ "limit"; "l" ] ~docv:"N" ~doc:"Max messages to return.")
  in
  let since =
    Cmdliner.Arg.(value & opt (some string) None & info [ "since" ] ~docv:"SINCE"
      ~doc:"Return only messages at or after this time. Accepts: Unix timestamp (float), relative (1h, 24h, 7d, 30m), or ISO 8601 (2026-04-20T18:00:00Z).")
  in
  let+ json = json_flag
  and+ room_id = room_id
  and+ limit = limit
  and+ since = since in
  let since_ts = match since with None -> 0.0 | Some s -> parse_since_str s in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let output_mode = if json then Json else Human in
  (try
     let messages =
       C2c_mcp.Broker.read_room_history broker ~room_id ~limit ~since:since_ts ()
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

let rooms_tail_cmd =
  let room_id =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ROOM" ~doc:"Room ID.")
  in
  let follow =
    Cmdliner.Arg.(value & flag & info [ "follow"; "f" ] ~doc:"Follow: print new messages as they arrive (like tail -f). Default: true.")
  in
  let no_follow =
    Cmdliner.Arg.(value & flag & info [ "no-follow"; "n" ] ~doc:"Print last N lines and exit (disables follow).")
  in
  let lines =
    Cmdliner.Arg.(value & opt int 20 & info [ "lines"; "l" ] ~docv:"N" ~doc:"Number of historical lines to show before following.")
  in
  let since =
    Cmdliner.Arg.(value & opt (some string) None & info [ "since" ] ~docv:"SINCE"
      ~doc:"Show only messages since this time (same format as room history --since).")
  in
  let+ room_id = room_id
  and+ follow = follow
  and+ no_follow = no_follow
  and+ lines = lines
  and+ since = since in
  let since_ts = match since with None -> 0.0 | Some s -> parse_since_str s in
  let do_follow = (not no_follow) || follow in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let path = C2c_mcp.Broker.room_history_path broker ~room_id in
  if not (Sys.file_exists path) && not do_follow then begin
    Printf.eprintf "room %s has no history\n%!" room_id; exit 0
  end;
  let format_msg line =
    try
      let json = Yojson.Safe.from_string line in
      let open Yojson.Safe.Util in
      let ts = json |> member "ts" |> to_number in
      if ts < since_ts then ()
      else begin
        let from_alias = json |> member "from_alias" |> to_string in
        let content = json |> member "content" |> to_string in
        let t = Unix.gmtime ts in
        Printf.printf "[%02d:%02d:%02d] %s: %s\n%!" t.tm_hour t.tm_min t.tm_sec from_alias content
      end
    with _ -> ()
  in
  (* Print historical lines *)
  if Sys.file_exists path then begin
    let messages = C2c_mcp.Broker.read_room_history broker ~room_id ~limit:lines ~since:since_ts () in
    List.iter (fun (m : C2c_mcp.room_message) ->
      let t = Unix.gmtime m.rm_ts in
      Printf.printf "[%02d:%02d:%02d] %s: %s\n%!" t.tm_hour t.tm_min t.tm_sec m.rm_from_alias m.rm_content
    ) messages
  end;
  if not do_follow then ()
  else begin
    (* Follow: stat-poll the file for new bytes *)
    let size = ref (try (Unix.stat path).Unix.st_size with Unix.Unix_error _ -> 0) in
    while true do
      Unix.sleepf 0.5;
      let new_size = try (Unix.stat path).Unix.st_size with Unix.Unix_error _ -> 0 in
      if new_size > !size then begin
        let ic = open_in path in
        (try Unix.lseek (Unix.descr_of_in_channel ic) !size Unix.SEEK_SET |> ignore
         with _ -> ());
        (try while true do format_msg (input_line ic) done
         with End_of_file -> close_in_noerr ic);
        size := new_size
      end
    done
  end

let rooms_list = Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List all rooms.") rooms_list_cmd
let rooms_join = Cmdliner.Cmd.v (Cmdliner.Cmd.info "join" ~doc:"Join a room.") rooms_join_cmd
let rooms_leave = Cmdliner.Cmd.v (Cmdliner.Cmd.info "leave" ~doc:"Leave a room.") rooms_leave_cmd
let rooms_delete = Cmdliner.Cmd.v (Cmdliner.Cmd.info "delete" ~doc:"Delete an empty room.") rooms_delete_cmd
let rooms_send = Cmdliner.Cmd.v (Cmdliner.Cmd.info "send" ~doc:"Send a message to a room.") rooms_send_cmd
let rooms_history = Cmdliner.Cmd.v (Cmdliner.Cmd.info "history" ~doc:"Show room message history.") rooms_history_cmd
let rooms_tail = Cmdliner.Cmd.v (Cmdliner.Cmd.info "tail" ~doc:"Tail room history; follow new messages as they arrive.") rooms_tail_cmd
let rooms_invite = Cmdliner.Cmd.v (Cmdliner.Cmd.info "invite" ~doc:"Invite an alias to a room.") rooms_invite_cmd
let rooms_members = Cmdliner.Cmd.v (Cmdliner.Cmd.info "members" ~doc:"List room members.") rooms_members_cmd
let rooms_visibility = Cmdliner.Cmd.v (Cmdliner.Cmd.info "visibility" ~doc:"Get or set room visibility.") rooms_visibility_cmd

let rooms_group =
  Cmdliner.Cmd.group
    ~default:rooms_list_cmd
    (Cmdliner.Cmd.info "rooms" ~doc:"Manage persistent N:N rooms.")
    [ rooms_list; rooms_join; rooms_leave; rooms_delete; rooms_send; rooms_history; rooms_tail; rooms_invite; rooms_members; rooms_visibility ]

let room_group =
  Cmdliner.Cmd.group
    ~default:rooms_list_cmd
    (Cmdliner.Cmd.info "room" ~doc:"Alias for rooms.")
    [ rooms_list; rooms_join; rooms_leave; rooms_send; rooms_history; rooms_tail; rooms_invite; rooms_members; rooms_visibility ]

(* --- subcommand: monitor (inotify-based inbox watcher) --------------------- *)

(* Read an inbox JSON file, returning the parsed message list. *)
let read_inbox_file path =
  try
    let ic = open_in path in
    let content = Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
      let buf = Buffer.create 512 in
      (try while true do Buffer.add_channel buf ic 1 done with End_of_file -> ());
      Buffer.contents buf)
    in
    (match Yojson.Safe.from_string content with
     | `List msgs -> msgs
     | _ -> [])
  with _ -> []

(* Extract a string field from a JSON assoc or return a default. *)
let jstr fields key def =
  match List.assoc_opt key fields with Some (`String s) -> s | _ -> def

(* Truncate a string to max_len, appending "…" if clipped. *)
let truncate s max_len =
  let s = String.trim s in
  if String.length s > max_len then String.sub s 0 max_len ^ "…" else s

(* Current time as [HH:MM:SS] *)
let now_hms () =
  let t = Unix.localtime (Unix.gettimeofday ()) in
  Printf.sprintf "[%02d:%02d:%02d]" t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec

(* Determine if a to_alias value is a room fanout (contains '#') *)
let parse_to_alias s =
  match String.split_on_char '#' s with
  | [_alias; room] -> `Room room
  | _ -> `Direct s

(* Short-window dedup for room fanouts. One room message lands in N peer
   archives; each archive append emits. Keyed on (from_alias, to_alias,
   content) — if we saw the exact same triple within the last 30s, skip.
   Max 1024 entries, oldest evicted on overflow. *)
let dedup_seen : (string * string * string, float) Hashtbl.t = Hashtbl.create 64
let dedup_window_s = 30.0

let dedup_check ~from ~to_raw ~content =
  let key = (from, to_raw, content) in
  let now = Unix.gettimeofday () in
  (* Opportunistic GC when table gets large *)
  if Hashtbl.length dedup_seen > 1024 then begin
    let stale = Hashtbl.fold (fun k ts acc ->
      if now -. ts > dedup_window_s then k :: acc else acc) dedup_seen [] in
    List.iter (Hashtbl.remove dedup_seen) stale
  end;
  match Hashtbl.find_opt dedup_seen key with
  | Some ts when now -. ts < dedup_window_s -> false
  | _ -> Hashtbl.replace dedup_seen key now; true

(* Emit one notification line per unique sender, collapsing bursts. *)
let emit_messages ~my_alias ~all ~full_body msgs =
  (* Group messages by from_alias *)
  let by_sender = Hashtbl.create 4 in
  List.iter (fun msg ->
    match msg with
    | `Assoc fields ->
        let from = jstr fields "from_alias" "?" in
        let existing = try Hashtbl.find by_sender from with Not_found -> [] in
        Hashtbl.replace by_sender from (existing @ [fields])
    | _ -> ()
  ) msgs;
  Hashtbl.iter (fun from sender_msgs ->
    let n = List.length sender_msgs in
    let first = List.hd sender_msgs in
    let to_raw = jstr first "to_alias" "" in
    let is_mine = match my_alias with
      | None -> true
      | Some me -> to_raw = me || String.length to_raw > String.length me + 1
                   && String.sub to_raw 0 (String.length me) = me
    in
    let body = jstr first "content" "" in
    (* Normalize room fanouts: each peer's archive tags to_alias with their
       own alias prefix (coder1#swarm-lounge vs planner1#swarm-lounge) so
       dedup sees them as distinct. Strip alias, keep just #<room>. *)
    let dedup_to = match parse_to_alias to_raw with
      | `Room room -> "#" ^ room
      | `Direct d -> d
    in
    let keep = dedup_check ~from ~to_raw:dedup_to ~content:body in
    if keep && (all || is_mine) then begin
      let icon = if is_mine then "📬" else "💬" in
      let dest = match parse_to_alias to_raw with
        | `Room room -> "@" ^ room
        | `Direct d -> if is_mine then "you" else d
      in
      let subject =
        if n = 1 then
          if full_body then Printf.sprintf "\"%s\"" body
          else Printf.sprintf "\"%s\"" (truncate body 80)
        else
          Printf.sprintf "(%d msgs) \"%s\"" n (truncate body 60)
      in
      Printf.printf "%s %s  %s→%s  %s\n%!"
        (now_hms ()) icon from dest subject
    end
  ) by_sender

let monitor_cmd =
  let open Cmdliner in
  let open Cmdliner.Term in
  let broker_root_opt =
    Arg.(value & opt (some string) None & info ["broker-root";"root"] ~docv:"DIR"
           ~doc:"Broker root dir (default: auto-resolve via env/git).")
  in
  let alias_opt =
    Arg.(value & opt (some string) None & info ["alias";"a"] ~docv:"ALIAS"
           ~doc:"My alias (default: C2C_MCP_SESSION_ID). Only messages addressed to \
                 this alias are shown by default.")
  in
  let all_flag =
    Arg.(value & flag & info ["all"]
           ~doc:"Also show messages addressed to other peers (situational awareness).")
  in
  let drains_flag =
    Arg.(value & flag & info ["drains"]
           ~doc:"Show drain events (when a peer polls their inbox to empty).")
  in
  let sweeps_flag =
    Arg.(value & flag & info ["sweeps"]
           ~doc:"Show sweep/delete events.")
  in
  let full_body_flag =
    Arg.(value & flag & info ["full-body";"body"]
           ~doc:"Emit full message content instead of an 80-char subject snippet.")
  in
  let from_opt =
    Arg.(value & opt (some string) None & info ["from"] ~docv:"ALIAS"
           ~doc:"Only show messages from this sender alias.")
  in
  let json_flag =
    Arg.(value & flag & info ["json"]
           ~doc:"Emit JSON objects instead of human-readable lines.")
  in
  let archive_flag =
    Arg.(value & flag & info ["archive"]
           ~doc:"Watch append-only archive (archive/*.jsonl) instead of live inboxes. \
                 Avoids the race where the PostToolUse hook drains the inbox before \
                 the monitor can peek. Every drained message is recorded here.")
  in
  let include_self_flag =
    Arg.(value & flag & info ["include-self"]
           ~doc:"Include messages sent by you. Off by default — your own broadcasts \
                 and DMs echo back through archive/inbox events and are noise.")
  in
  const (fun broker_root_arg alias_arg all drains sweeps full_body from_filter json archive include_self ->
    let broker_root =
      match broker_root_arg with
      | Some r -> r
      | None ->
          (match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
           | Some r -> r
           | None -> (try resolve_broker_root () with _ ->
               Printf.eprintf "c2c monitor: cannot resolve broker root \
                 (set C2C_MCP_BROKER_ROOT or run from inside the repo)\n%!";
               exit 1))
    in
    let my_alias =
      match alias_arg with
      | Some a -> Some a
      | None -> Sys.getenv_opt "C2C_MCP_SESSION_ID"
    in
    (* Archive mode watches <broker_root>/archive/*.jsonl (append-only).
       Each drained message is a full JSON object on its own line. We track
       per-file read offsets so we only emit newly-appended lines. This avoids
       the race where the PostToolUse hook drains the live inbox before our
       inotify event fires on <root>/*.inbox.json. *)
    let watch_dir =
      if archive then Filename.concat broker_root "archive" else broker_root
    in
    if archive && not (Sys.file_exists watch_dir) then begin
      (try Unix.mkdir watch_dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
    end;
    (* Per-file read offsets for archive mode. Init to current size so we
       don't re-emit historical entries on startup. *)
    let archive_offsets : (string, int) Hashtbl.t = Hashtbl.create 16 in
    if archive && Sys.file_exists watch_dir then begin
      Array.iter (fun fname ->
        let n = String.length fname in
        if n > 6 && String.sub fname (n - 6) 6 = ".jsonl" then
          let path = Filename.concat watch_dir fname in
          try
            let st = Unix.stat path in
            Hashtbl.replace archive_offsets path st.Unix.st_size
          with _ -> ()
      ) (Sys.readdir watch_dir)
    end;
    let read_new_archive_entries path =
      let prev = try Hashtbl.find archive_offsets path with Not_found -> 0 in
      try
        let st = Unix.stat path in
        let sz = st.Unix.st_size in
        if sz <= prev then []
        else
          let fd = Unix.openfile path [Unix.O_RDONLY] 0 in
          Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
            let _ = Unix.lseek fd prev Unix.SEEK_SET in
            let buf = Bytes.create (sz - prev) in
            let rec read_all off rem =
              if rem <= 0 then () else
              let r = Unix.read fd buf off rem in
              if r = 0 then () else read_all (off + r) (rem - r)
            in
            read_all 0 (sz - prev);
            Hashtbl.replace archive_offsets path sz;
            let text = Bytes.unsafe_to_string buf in
            let lines = String.split_on_char '\n' text in
            List.filter_map (fun ln ->
              let ln = String.trim ln in
              if ln = "" then None
              else try Some (Yojson.Safe.from_string ln) with _ -> None
            ) lines)
      with _ -> []
    in
    let cmd = Printf.sprintf
      "inotifywait -m -q -e close_write,modify,delete --format '%%e %%f' %s"
      (Filename.quote watch_dir)
    in
    let ic = Unix.open_process_in cmd in
    Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic)) (fun () ->
      try while true do
        (* If our parent died (reparented to init/PID 1), we are an orphan —
           exit rather than accumulate as a zombie monitor process. *)
        (if Unix.getppid () = 1 then exit 0);
        let line = input_line ic in
        let parts = String.split_on_char ' ' (String.trim line) in
        (match parts with
         | event :: filename :: _ when archive ->
             let n = String.length filename in
             let is_jsonl = n > 6 && String.sub filename (n - 6) 6 = ".jsonl" in
             if is_jsonl then begin
               let sid = String.sub filename 0 (n - 6) in
               let path = Filename.concat watch_dir filename in
               let entries = read_new_archive_entries path in
               (* Apply --from filter *)
               let entries = match from_filter with
                 | None -> entries
                 | Some f -> List.filter (fun m -> match m with
                     | `Assoc fields -> jstr fields "from_alias" "" = f
                     | _ -> false) entries
               in
               (* Drop self-sent unless --include-self *)
               let entries =
                 if include_self then entries
                 else match my_alias with
                   | None -> entries
                   | Some me -> List.filter (fun m -> match m with
                       | `Assoc fields -> jstr fields "from_alias" "" <> me
                       | _ -> true) entries
               in
               (match entries with
                | [] -> ()
                | msgs ->
                    if json then begin
                      let is_mine = match my_alias with
                        | None -> true | Some me -> sid = me in
                      if all || is_mine then
                        List.iter (fun m ->
                          let m_with_ts = match m with
                            | `Assoc fields ->
                                let ts = Printf.sprintf "%.3f" (Unix.gettimeofday ()) in
                                `Assoc (("monitor_ts", `String ts) :: fields)
                            | _ -> m
                          in
                          print_string (Yojson.Safe.to_string m_with_ts);
                          print_newline ()
                        ) msgs
                    end else
                      emit_messages ~my_alias ~all ~full_body msgs)
             end;
             ignore event
         | event :: filename :: _ ->
             let n = String.length filename in
             let is_inbox = n > 11 && String.sub filename (n - 11) 11 = ".inbox.json" in
             let is_lock  = n >= 5  && String.sub filename (n - 5) 5 = ".lock" in
             if is_inbox && not is_lock then begin
               let alias = String.sub filename 0 (n - 11) in
               let event_up = String.uppercase_ascii event in
               let is_delete = String.length event_up >= 6
                               && String.sub event_up 0 6 = "DELETE" in
               if is_delete then begin
                 if sweeps then
                   Printf.printf "%s 🗑️  SWEEP  %s (inbox deleted)\n%!" (now_hms ()) alias
               end else begin
                 let inbox_path = Filename.concat broker_root filename in
                 let msgs = read_inbox_file inbox_path in
                 (* Apply --from filter *)
                 let msgs = match from_filter with
                   | None -> msgs
                   | Some f -> List.filter (fun m -> match m with
                       | `Assoc fields -> jstr fields "from_alias" "" = f
                       | _ -> false) msgs
                 in
                 (* Drop self-sent unless --include-self *)
                 let msgs =
                   if include_self then msgs
                   else match my_alias with
                     | None -> msgs
                     | Some me -> List.filter (fun m -> match m with
                         | `Assoc fields -> jstr fields "from_alias" "" <> me
                         | _ -> true) msgs
                 in
                 (match msgs with
                  | [] ->
                      if drains then
                        Printf.printf "%s 📤  DRAIN  %s (inbox cleared)\n%!" (now_hms ()) alias
                  | msgs ->
                      if json then begin
                        let is_mine = match my_alias with
                          | None -> true | Some me -> alias = me in
                        if all || is_mine then
                          List.iter (fun m ->
                            let m_with_ts = match m with
                              | `Assoc fields ->
                                  let ts = Printf.sprintf "%.3f" (Unix.gettimeofday ()) in
                                  `Assoc (("monitor_ts", `String ts) :: fields)
                              | _ -> m
                            in
                            print_string (Yojson.Safe.to_string m_with_ts);
                            print_newline ()
                          ) msgs
                      end else
                        emit_messages ~my_alias ~all ~full_body msgs)
               end
             end
         | _ -> ()
        )
      done with End_of_file -> ())
  ) $ broker_root_opt $ alias_opt $ all_flag $ drains_flag $ sweeps_flag
    $ full_body_flag $ from_opt $ json_flag $ archive_flag $ include_self_flag

let monitor =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "monitor"
       ~doc:"Watch broker inboxes and emit formatted event notifications."
       ~man:[ `S "DESCRIPTION"
            ; `P "Watches the broker inbox directory with $(b,inotifywait) and emits \
                  one formatted line per new message (or event). Designed for Claude Code's \
                  Monitor tool — each output line becomes the notification summary."
            ; `P "Default behaviour: only show messages addressed to your alias \
                  ($(b,C2C_MCP_SESSION_ID)). New messages only — drains and sweeps \
                  suppressed unless $(b,--drains)/$(b,--sweeps) are set."
            ; `P "Burst deduplication: multiple messages from the same sender in one \
                  inbox write are collapsed to a single line with a count."
            ; `S "OUTPUT FORMAT"
            ; `P "[HH:MM:SS] ICON  TYPE  from→to  \"subject…\""
            ; `P "ICON: 📬 = addressed to you, 💬 = peer traffic (--all), \
                  📤 = drain (--drains), 🗑️ = sweep (--sweeps)"
            ; `S "EXAMPLES"
            ; `P "$(b,c2c monitor)  — watch your own inbox (default)"
            ; `P "$(b,c2c monitor --all)  — broad swarm monitor"
            ; `P "$(b,c2c monitor --all --drains --sweeps)  — everything"
            ; `P "$(b,c2c monitor --from coder1)  — only messages from coder1"
            ; `P "$(b,c2c monitor --full-body)  — include complete message body"
            ; `P "$(b,c2c monitor --json)  — JSON output for programmatic parsing"
            ; `P "$(b,c2c monitor --archive --all)  — watch append-only archive; \
                  no race with PostToolUse hook drains. Recommended for Claude Code."
            ; `P "In Claude Code: Monitor({command: \"c2c monitor --archive --all\", persistent: true})"
            ])
    monitor_cmd

(* --- subcommand: hook (PostToolUse inbox hook) ----------------------------- *)

let min_hook_runtime_ms = 100.0

let sleep_to_min_runtime start_time =
  (* Sleep so total runtime is at least min_hook_runtime_ms. Prevents Node.js
     ECHILD race: fast-exiting hooks are reaped by the kernel before Claude
     Code's waitpid(), which then fails with ECHILD. *)
  let elapsed_ms = (Unix.gettimeofday () -. start_time) *. 1000.0 in
  let sleep_s = max 0.0 ((min_hook_runtime_ms -. elapsed_ms) /. 1000.0) in
  if sleep_s > 0.0 then Unix.sleepf sleep_s

let hook_cmd =
  (* No arguments - reads env vars C2C_MCP_SESSION_ID and C2C_MCP_BROKER_ROOT *)
  let open Cmdliner.Term in
  const (fun () ->
    let start_time = Unix.gettimeofday () in
    let session_id =
      try Sys.getenv "C2C_MCP_SESSION_ID" with Not_found -> ""
    in
    let broker_root =
      try Sys.getenv "C2C_MCP_BROKER_ROOT" with Not_found -> ""
    in
    if session_id = "" || broker_root = "" then begin
      sleep_to_min_runtime start_time;
      exit 0
    end;
    try
      let broker = C2c_mcp.Broker.create ~root:broker_root in
      let messages = C2c_mcp.Broker.drain_inbox broker ~session_id in
      (match messages with
       | [] -> ()
       | _ ->
         let buf = Buffer.create 256 in
         List.iter
           (fun (m : C2c_mcp.message) ->
             Buffer.add_string buf
               (Printf.sprintf "<c2c event=\"message\" from=\"%s\" alias=\"%s\" action_after=\"continue\">%s</c2c>\n"
                  m.from_alias m.to_alias m.content))
           messages;
         let json : Yojson.Safe.t =
           `Assoc [
             ("hookSpecificOutput", `Assoc [
               ("hookEventName", `String "PostToolUse");
               ("additionalContext", `String (Buffer.contents buf));
             ])
           ]
         in
         print_string (Yojson.Safe.to_string json);
         print_newline ());
      sleep_to_min_runtime start_time;
      exit 0
    with e ->
      prerr_endline (Printexc.to_string e);
      sleep_to_min_runtime start_time;
      exit 1) $ const ()

let hook = Cmdliner.Cmd.v (Cmdliner.Cmd.info "hook" ~doc:"PostToolUse hook: drain inbox and emit messages.") hook_cmd

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
  let tls_cert =
    Cmdliner.Arg.(value & opt (some string) None & info [ "tls-cert" ] ~docv:"PATH" ~doc:"PEM certificate file for TLS (enables HTTPS).")
  in
  let tls_key =
    Cmdliner.Arg.(value & opt (some string) None & info [ "tls-key" ] ~docv:"PATH" ~doc:"PEM private-key file for TLS (required with --tls-cert).")
  in
  let allowed_identities =
    Cmdliner.Arg.(value & opt (some string) None & info [ "allowed-identities" ] ~docv:"PATH"
      ~doc:"JSON file mapping {alias: identity_pk_b64} (L3/5). Listed aliases require a matching signed register; unlisted aliases stay first-mover-wins.")
  in
  let persist_dir =
    Cmdliner.Arg.(value & opt (some string) None & info [ "persist-dir" ] ~docv:"DIR"
      ~doc:"Directory for persistent room history storage (or C2C_RELAY_PERSIST_DIR). Room messages are written to <dir>/rooms/<room_id>/history.jsonl and loaded on startup.")
  in
  let+ listen = listen
  and+ token = token
  and+ token_file = token_file
  and+ storage = storage
  and+ db_path = db_path
  and+ gc_interval = gc_interval
  and+ verbose = verbose
  and+ tls_cert = tls_cert
  and+ tls_key = tls_key
  and+ allowed_identities = allowed_identities
  and+ persist_dir = persist_dir in
  (* Parse listen address (default 127.0.0.1:7331) *)
  let host, port = match listen with
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
      (* Native OCaml relay server *)
      let tls_cfg =
        match tls_cert, tls_key with
        | Some c, Some k -> Some (`Cert_key (c, k))
        | None, None -> None
        | Some _, None ->
            Printf.eprintf "error: --tls-cert requires --tls-key\n%!"; exit 1
        | None, Some _ ->
            Printf.eprintf "error: --tls-key requires --tls-cert\n%!"; exit 1
      in
      Printf.printf "storage: memory\n%!";
      let allowlist = match allowed_identities with
        | None -> []
        | Some path ->
          (try
            let json = Yojson.Safe.from_file path in
            match json with
            | `Assoc pairs ->
              List.map (fun (alias, v) -> match v with
                | `String pk_b64 -> (alias, pk_b64)
                | _ ->
                  Printf.eprintf "error: --allowed-identities entry for %S must be a string\n%!" alias;
                  exit 1) pairs
            | _ ->
              Printf.eprintf "error: --allowed-identities file must be a JSON object { alias: pk_b64, ... }\n%!";
              exit 1
          with
          | Sys_error msg ->
            Printf.eprintf "error reading --allowed-identities: %s\n%!" msg; exit 1
          | Yojson.Json_error msg ->
            Printf.eprintf "error parsing --allowed-identities: %s\n%!" msg; exit 1)
      in
      let persist_dir = match persist_dir with
        | Some d -> Some d
        | None -> Sys.getenv_opt "C2C_RELAY_PERSIST_DIR"
      in
      Version.banner ~role:"relay-server" ~git_hash:(Option.value (git_shorthash ()) ~default:"unknown");
      Printf.eprintf "  listen=%s:%d\n%!" host port;
      (match persist_dir with
       | Some d -> Printf.eprintf "  persist-dir=%s\n%!" d
       | None -> Printf.eprintf "  persist-dir=none (in-memory only)\n%!");
      Lwt_main.run (Relay.Relay_server.start_server ~host ~port ~token ~verbose ~gc_interval ?tls:tls_cfg ~allowlist ?persist_dir ())

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
  (* Native OCaml relay config management. Mirrors c2c_relay_config.py:
     priority = $C2C_RELAY_CONFIG > $C2C_MCP_BROKER_ROOT/relay.json >
     ~/.config/c2c/relay.json. Fields: url, token, node_id. *)
  let config_path () =
    match Sys.getenv_opt "C2C_RELAY_CONFIG" with
    | Some p when p <> "" -> p
    | _ ->
        (match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
         | Some d when d <> "" -> Filename.concat d "relay.json"
         | _ ->
             let home = try Sys.getenv "HOME" with Not_found -> "." in
             Filename.concat home ".config/c2c/relay.json")
  in
  let read_all path =
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
      really_input_string ic (in_channel_length ic))
  in
  let load path =
    match try Some (read_all path) with _ -> None with
    | None -> `Assoc []
    | Some s ->
        (try Yojson.Safe.from_string s with _ -> `Assoc [])
  in
  let rec mkdir_p dir =
    if dir = "/" || dir = "." || dir = "" then ()
    else if Sys.file_exists dir then ()
    else begin
      mkdir_p (Filename.dirname dir);
      try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  let save path json =
    mkdir_p (Filename.dirname path);
    let oc = open_out path in
    Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
      output_string oc (Yojson.Safe.pretty_to_string json);
      output_char oc '\n')
  in
  let path = config_path () in
  if show then begin
    let cfg = load path in
    print_endline (Yojson.Safe.pretty_to_string cfg);
    exit 0
  end;
  let token_final =
    match token with
    | Some _ as v -> v
    | None ->
        (match token_file with
         | Some f -> (try Some (String.trim (read_all f)) with _ -> None)
         | None -> None)
  in
  (* Merge: keep existing fields, override with provided ones. *)
  let existing = match load path with `Assoc l -> l | _ -> [] in
  let set_field fields key = function
    | None -> fields
    | Some v ->
        (key, `String v) :: List.filter (fun (k, _) -> k <> key) fields
  in
  let merged =
    existing
    |> (fun f -> set_field f "url" url)
    |> (fun f -> set_field f "token" token_final)
    |> (fun f -> set_field f "node_id" node_id)
  in
  save path (`Assoc merged);
  Printf.printf "wrote %s\n" path;
  exit 0

let resolve_relay_url opt =
  match opt with
  | Some v -> Some v
  | None -> (try Some (Sys.getenv "C2C_RELAY_URL") with Not_found -> None)

let resolve_relay_token opt =
  match opt with
  | Some v -> Some v
  | None -> (try Some (Sys.getenv "C2C_RELAY_TOKEN") with Not_found -> None)

let relay_status_cmd =
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:"Relay server URL (or C2C_RELAY_URL).")
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:"Bearer token (or C2C_RELAY_TOKEN).")
  in
  let+ relay_url = relay_url
  and+ token = token in
  match resolve_relay_url relay_url with
  | None ->
      Printf.eprintf "error: --relay-url required (or set C2C_RELAY_URL).\n%!";
      exit 1
  | Some url ->
      let client = C2c_mcp.Relay.Relay_client.make ?token:(resolve_relay_token token) url in
      let result = Lwt_main.run (C2c_mcp.Relay.Relay_client.health client) in
      print_endline (Yojson.Safe.pretty_to_string result);
      (match result with
       | `Assoc fields ->
           (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
       | _ -> exit 1)

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
  match resolve_relay_url relay_url with
  | None ->
      Printf.eprintf "error: --relay-url required (or set C2C_RELAY_URL).\n%!";
      exit 1
  | Some url ->
      let client = C2c_mcp.Relay.Relay_client.make ?token:(resolve_relay_token token) url in
      let result = Lwt_main.run (C2c_mcp.Relay.Relay_client.list_peers client ~include_dead:dead ()) in
      print_endline (Yojson.Safe.pretty_to_string result);
      (match result with
       | `Assoc fields ->
           (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
       | _ -> exit 1)

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
  let room =
    Cmdliner.Arg.(value & opt (some string) None & info [ "room" ] ~docv:"ROOM" ~doc:"Room id (required for history).")
  in
  let limit =
    Cmdliner.Arg.(value & opt int 50 & info [ "limit" ] ~docv:"N" ~doc:"Max messages for history (default 50).")
  in
  let alias =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias" ] ~docv:"ALIAS" ~doc:"Alias (required for join/leave/send).")
  in
  let words =
    Cmdliner.Arg.(value & pos_right 0 string [] & info [] ~docv:"WORDS" ~doc:"Message body for 'send' (joined with spaces).")
  in
  let+ subcmd = subcmd
  and+ relay_url = relay_url
  and+ token = token
  and+ room = room
  and+ limit = limit
  and+ alias = alias
  and+ words = words in
  let run_alias_op op_name client_fn =
    match resolve_relay_url relay_url, room, alias with
    | None, _, _ ->
        Printf.eprintf "error: --relay-url required (or set C2C_RELAY_URL).\n%!";
        exit 1
    | _, None, _ ->
        Printf.eprintf "error: --room required for 'rooms %s'.\n%!" op_name;
        exit 1
    | _, _, None ->
        Printf.eprintf "error: --alias required for 'rooms %s'.\n%!" op_name;
        exit 1
    | Some url, Some room_id, Some alias ->
        let client = C2c_mcp.Relay.Relay_client.make ?token:(resolve_relay_token token) url in
        let result = Lwt_main.run (client_fn client ~alias ~room_id) in
        print_endline (Yojson.Safe.pretty_to_string result);
        (match result with
         | `Assoc fields ->
             (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
         | _ -> exit 1)
  in
  match subcmd with
  | "join" -> run_alias_op "join" C2c_mcp.Relay.Relay_client.join_room
  | "leave" -> run_alias_op "leave" C2c_mcp.Relay.Relay_client.leave_room
  | "send" ->
      (match resolve_relay_url relay_url, room, alias, words with
       | None, _, _, _ ->
           Printf.eprintf "error: --relay-url required (or set C2C_RELAY_URL).\n%!";
           exit 1
       | _, None, _, _ ->
           Printf.eprintf "error: --room required for 'rooms send'.\n%!";
           exit 1
       | _, _, None, _ ->
           Printf.eprintf "error: --alias required for 'rooms send'.\n%!";
           exit 1
       | _, _, _, [] ->
           Printf.eprintf "error: message body required for 'rooms send'.\n%!";
           exit 1
       | Some url, Some room_id, Some from_alias, ws ->
           let content = String.concat " " ws in
           let client = C2c_mcp.Relay.Relay_client.make ?token:(resolve_relay_token token) url in
           (* L4/4: sign the send with the local identity when available.
              Falls back to legacy unsigned path if no identity is on disk
              (spec soft-rollout). *)
           let result =
             match Relay_identity.load () with
             | Ok id ->
                 let envelope =
                   Relay_signed_ops.sign_send_room id
                     ~room_id ~from_alias ~content
                 in
                 Lwt_main.run
                   (C2c_mcp.Relay.Relay_client.send_room_signed client
                      ~from_alias ~room_id ~content ~envelope ())
             | Error _ ->
                 Lwt_main.run
                   (C2c_mcp.Relay.Relay_client.send_room client
                      ~from_alias ~room_id ~content ())
           in
           print_endline (Yojson.Safe.pretty_to_string result);
           (match result with
            | `Assoc fields ->
                (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
            | _ -> exit 1))
  | "history" ->
      (match resolve_relay_url relay_url, room with
       | None, _ ->
           Printf.eprintf "error: --relay-url required (or set C2C_RELAY_URL).\n%!";
           exit 1
       | _, None ->
           Printf.eprintf "error: --room required for 'rooms history'.\n%!";
           exit 1
       | Some url, Some room_id ->
           let client = C2c_mcp.Relay.Relay_client.make ?token:(resolve_relay_token token) url in
           let result = Lwt_main.run (C2c_mcp.Relay.Relay_client.room_history client ~room_id ~limit ()) in
           (* L4/3 client verify: annotate each history entry with sig_ok. *)
           let annotate entry =
             match entry with
             | `Assoc fs ->
                 (match List.assoc_opt "envelope" fs with
                  | Some env ->
                      let get_s k = match List.assoc_opt k fs with
                        | Some (`String s) -> Some s | _ -> None in
                      (match get_s "room_id", get_s "from_alias", get_s "content" with
                       | Some r, Some fa, Some c ->
                           let ok = match Relay_signed_ops.verify_history_envelope
                             ~room_id:r ~from_alias:fa ~content:c env with
                             | Ok () -> `Bool true
                             | Error _ -> `Bool false in
                           `Assoc (("sig_ok", ok) :: fs)
                       | _ -> `Assoc (("sig_ok", `Null) :: fs))
                  | None -> `Assoc (("sig_ok", `Null) :: fs))
             | other -> other
           in
           let annotated = match result with
             | `Assoc fs ->
                 let fs' = List.map (fun (k, v) ->
                   if k = "history" then
                     match v with
                     | `List items -> (k, `List (List.map annotate items))
                     | other -> (k, other)
                   else (k, v)) fs in
                 `Assoc fs'
             | other -> other
           in
           print_endline (Yojson.Safe.pretty_to_string annotated);
           (match annotated with
            | `Assoc fields ->
                (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
            | _ -> exit 1))
  | "list" ->
      (match resolve_relay_url relay_url with
       | None ->
           Printf.eprintf "error: --relay-url required (or set C2C_RELAY_URL).\n%!";
           exit 1
       | Some url ->
           let client = C2c_mcp.Relay.Relay_client.make ?token:(resolve_relay_token token) url in
           let result = Lwt_main.run (C2c_mcp.Relay.Relay_client.list_rooms client) in
           print_endline (Yojson.Safe.pretty_to_string result);
           (match result with
            | `Assoc fields ->
                (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
            | _ -> exit 1))
  | _ ->
      (* join / leave / send / history still require CLI args not plumbed here
         — fall back to Python until we grow them on the OCaml side. *)
      (match find_python_script "c2c_relay_rooms.py" with
       | None ->
           Printf.eprintf "error: cannot find c2c_relay_rooms.py. Run from inside the c2c git repo.\n%!";
           exit 1
       | Some script ->
           let args = [ "python3"; script; subcmd ] in
           let args = match relay_url with None -> args | Some v -> args @ [ "--relay-url"; v ] in
           let args = match token with None -> args | Some v -> args @ [ "--token"; v ] in
           Unix.execvp "python3" (Array.of_list args))

(* c2c relay register — bind Ed25519 identity on the relay (§8.2) *)
let relay_register_cmd =
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:"Relay server URL.")
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:"Bearer token.")
  in
  let alias =
    Cmdliner.Arg.(required & opt (some string) None & info [ "alias" ] ~docv:"ALIAS" ~doc:"Alias to register.")
  in
  let+ relay_url = relay_url and+ token = token and+ alias = alias in
  match resolve_relay_url relay_url with
  | None ->
      Printf.eprintf "error: --relay-url required (or set C2C_RELAY_URL).\n%!";
      exit 1
  | Some url ->
      let client = C2c_mcp.Relay.Relay_client.make ?token:(resolve_relay_token token) url in
      let node_id = Printf.sprintf "cli-%s" alias in
      let session_id = node_id in
      let result = (match Relay_identity.load () with
        | Ok id ->
            let p = Relay_signed_ops.sign_register id ~alias ~relay_url:url in
            Lwt_main.run (C2c_mcp.Relay.Relay_client.register_signed client
              ~node_id ~session_id ~alias ~client_type:"cli"
              ~identity_pk_b64:p.Relay_signed_ops.identity_pk_b64
              ~sig_b64:p.Relay_signed_ops.sig_b64
              ~nonce:p.Relay_signed_ops.nonce
              ~ts:p.Relay_signed_ops.ts ())
        | Error _ ->
            Lwt_main.run (C2c_mcp.Relay.Relay_client.register client
              ~node_id ~session_id ~alias ~client_type:"cli" ~identity_pk:"" ()))
      in
      print_endline (Yojson.Safe.pretty_to_string result);
      (match result with
       | `Assoc fields ->
           (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
       | _ -> exit 1)

(* c2c relay dm — cross-host direct messages (§8.3) *)
let relay_dm_cmd =
  let subcmd =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"send|poll" ~doc:"DM subcommand: send or poll.")
  in
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:"Relay server URL.")
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:"Bearer token.")
  in
  let alias =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias" ] ~docv:"ALIAS" ~doc:"Your alias (required for poll).")
  in
  let words =
    Cmdliner.Arg.(value & pos_right 0 string [] & info [] ~docv:"WORDS" ~doc:"For send: <to-alias> <message...>")
  in
  let+ subcmd = subcmd and+ relay_url = relay_url and+ token = token
  and+ alias = alias and+ words = words in
  match resolve_relay_url relay_url with
  | None ->
      Printf.eprintf "error: --relay-url required (or set C2C_RELAY_URL).\n%!";
      exit 1
  | Some url ->
      let client = C2c_mcp.Relay.Relay_client.make ?token:(resolve_relay_token token) url in
      (match subcmd with
       | "send" ->
           (match words with
            | [] | [_] ->
                Printf.eprintf "error: usage: dm send <to-alias> <message...>\n%!";
                exit 1
            | to_alias :: msg_words ->
                let from_alias = match alias with
                  | Some a -> a
                  | None ->
                      Printf.eprintf "error: --alias required for dm send\n%!";
                      exit 1
                in
                let content = String.concat " " msg_words in
                let body_str = Yojson.Safe.to_string (`Assoc [
                  ("from_alias", `String from_alias);
                  ("to_alias", `String to_alias);
                  ("content", `String content);
                ]) in
                let result = (match Relay_identity.load () with
                  | Ok id ->
                      let auth = Relay_signed_ops.sign_request id ~alias:from_alias
                        ~meth:"POST" ~path:"/send" ~body_str () in
                      Lwt_main.run (C2c_mcp.Relay.Relay_client.send_signed client
                        ~from_alias ~to_alias ~content ~auth_header:auth ())
                  | Error _ ->
                      Lwt_main.run (C2c_mcp.Relay.Relay_client.send client
                        ~from_alias ~to_alias ~content ())) in
                print_endline (Yojson.Safe.pretty_to_string result);
                (match result with
                 | `Assoc fields ->
                     (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
                 | _ -> exit 1))
       | "poll" ->
           let from_alias = match alias with
             | Some a -> a
             | None ->
                 Printf.eprintf "error: --alias required for dm poll\n%!";
                 exit 1
           in
           let node_id = Printf.sprintf "cli-%s" from_alias in
           let result = Lwt_main.run (C2c_mcp.Relay.Relay_client.poll_inbox client
             ~node_id ~session_id:node_id) in
           print_endline (Yojson.Safe.pretty_to_string result);
           (match result with
            | `Assoc fields ->
                (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
            | _ -> exit 1)
       | other ->
           Printf.eprintf "error: unknown dm subcommand: %s\n%!" other;
           exit 1)

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
  match resolve_relay_url relay_url with
  | None ->
      Printf.eprintf "error: --relay-url required (or set C2C_RELAY_URL).\n%!";
      exit 1
  | Some url ->
      let client = C2c_mcp.Relay.Relay_client.make ?token:(resolve_relay_token token) url in
      let run_once () =
        let open Lwt.Infix in
        C2c_mcp.Relay.Relay_client.gc client >>= fun result ->
        if verbose || once then print_endline (Yojson.Safe.pretty_to_string result);
        let ok = match result with
          | `Assoc fields ->
              (match List.assoc_opt "ok" fields with Some (`Bool true) -> true | _ -> false)
          | _ -> false
        in
        Lwt.return ok
      in
      if once then begin
        let ok = Lwt_main.run (run_once ()) in
        exit (if ok then 0 else 1)
      end else begin
        let sleep_s = match interval with Some s -> float_of_int s | None -> 30.0 in
        let rec loop () =
          let open Lwt.Infix in
          run_once () >>= fun _ -> Lwt_unix.sleep sleep_s >>= loop
        in
        Lwt_main.run (loop ())
      end

(* --- relay identity (Layer 3 slice 6) ------------------------------------- *)
(* Wraps Relay_identity (ocaml/relay_identity.ml) with init/show/fingerprint
   subcommands for managing ~/.config/c2c/identity.json. See
   docs/c2c-research/relay-peer-identity-spec.md §8. *)

let relay_identity_init_cmd =
  let alias_hint =
    Cmdliner.Arg.(value & opt string "" & info [ "alias-hint" ] ~docv:"HINT"
      ~doc:"Informational alias label stored in identity.json (not authoritative).")
  in
  let path =
    Cmdliner.Arg.(value & opt (some string) None & info [ "path" ] ~docv:"PATH"
      ~doc:"Override identity file path (default: ~/.config/c2c/identity.json).")
  in
  let force =
    Cmdliner.Arg.(value & flag & info [ "force" ]
      ~doc:"Overwrite an existing identity file without prompting.")
  in
  let json = Cmdliner.Arg.(value & flag & info [ "json" ] ~doc:"Emit JSON output.") in
  let+ alias_hint = alias_hint
  and+ path = path
  and+ force = force
  and+ json = json in
  let target = match path with Some p -> p | None -> Relay_identity.default_path () in
  if (not force) && Sys.file_exists target then begin
    if json then
      print_endline (Printf.sprintf
        {|{"ok":false,"error":"identity exists","path":%S,"hint":"pass --force to overwrite"}|}
        target)
    else
      Printf.eprintf
        "error: %s already exists. Pass --force to overwrite.\n%!" target;
    exit 1
  end;
  let id = Relay_identity.generate ~alias_hint () in
  match Relay_identity.save ~path:target id with
  | Error msg ->
      if json then
        print_endline (Printf.sprintf
          {|{"ok":false,"error":%S}|} msg)
      else
        Printf.eprintf "error: %s\n%!" msg;
      exit 1
  | Ok () ->
      if json then
        print_endline (Yojson.Safe.to_string
          (`Assoc [
            "ok", `Bool true;
            "path", `String target;
            "fingerprint", `String id.fingerprint;
            "alias_hint", `String id.alias_hint;
            "created_at", `String id.created_at;
          ]))
      else begin
        Printf.printf "identity written to %s\n" target;
        Printf.printf "  fingerprint: %s\n" id.fingerprint;
        if id.alias_hint <> "" then
          Printf.printf "  alias_hint:  %s\n" id.alias_hint;
        Printf.printf "  created_at:  %s\n" id.created_at
      end

let relay_identity_show_cmd =
  let path =
    Cmdliner.Arg.(value & opt (some string) None & info [ "path" ] ~docv:"PATH"
      ~doc:"Override identity file path (default: ~/.config/c2c/identity.json).")
  in
  let json = Cmdliner.Arg.(value & flag & info [ "json" ] ~doc:"Emit JSON output.") in
  let+ path = path
  and+ json = json in
  let target = match path with Some p -> p | None -> Relay_identity.default_path () in
  match Relay_identity.load ~path:target () with
  | Error msg ->
      if json then
        print_endline (Printf.sprintf {|{"ok":false,"error":%S}|} msg)
      else
        Printf.eprintf "error: %s\n%!" msg;
      exit 1
  | Ok id ->
      if json then
        (* Never emit the private_key on show — only public metadata. *)
        print_endline (Yojson.Safe.to_string
          (`Assoc [
            "ok", `Bool true;
            "path", `String target;
            "fingerprint", `String id.fingerprint;
            "alias_hint", `String id.alias_hint;
            "created_at", `String id.created_at;
            "alg", `String id.alg;
            "version", `Int id.version;
          ]))
      else begin
        Printf.printf "path:        %s\n" target;
        Printf.printf "fingerprint: %s\n" id.fingerprint;
        Printf.printf "alg:         %s\n" id.alg;
        if id.alias_hint <> "" then
          Printf.printf "alias_hint:  %s\n" id.alias_hint;
        Printf.printf "created_at:  %s\n" id.created_at
      end

let relay_identity_fingerprint_cmd =
  let path =
    Cmdliner.Arg.(value & opt (some string) None & info [ "path" ] ~docv:"PATH"
      ~doc:"Override identity file path (default: ~/.config/c2c/identity.json).")
  in
  let+ path = path in
  let target = match path with Some p -> p | None -> Relay_identity.default_path () in
  match Relay_identity.load ~path:target () with
  | Error msg -> Printf.eprintf "error: %s\n%!" msg; exit 1
  | Ok id -> print_endline id.fingerprint

let relay_identity_init =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "init" ~doc:"Generate a new Ed25519 identity keypair.")
    relay_identity_init_cmd

let relay_identity_show =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "show" ~doc:"Print identity metadata (fingerprint, alias_hint, created_at).")
    relay_identity_show_cmd

let relay_identity_fingerprint =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "fingerprint" ~doc:"Print just the SHA256 fingerprint, one line.")
    relay_identity_fingerprint_cmd

let relay_identity =
  Cmdliner.Cmd.group
    ~default:relay_identity_show_cmd
    (Cmdliner.Cmd.info "identity"
      ~doc:"Manage the local Ed25519 identity used for peer authentication.")
    [ relay_identity_init; relay_identity_show; relay_identity_fingerprint ]

let relay_serve = Cmdliner.Cmd.v (Cmdliner.Cmd.info "serve" ~doc:"Start the relay server.") relay_serve_cmd
let relay_connect = Cmdliner.Cmd.v (Cmdliner.Cmd.info "connect" ~doc:"Run the relay connector.") relay_connect_cmd
let relay_setup = Cmdliner.Cmd.v (Cmdliner.Cmd.info "setup" ~doc:"Configure relay connection.") relay_setup_cmd
let relay_status = Cmdliner.Cmd.v (Cmdliner.Cmd.info "status" ~doc:"Show relay health.") relay_status_cmd
let relay_list = Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List relay peers.") relay_list_cmd
let relay_rooms = Cmdliner.Cmd.v (Cmdliner.Cmd.info "rooms" ~doc:"Manage relay rooms.") relay_rooms_cmd
let relay_gc = Cmdliner.Cmd.v (Cmdliner.Cmd.info "gc" ~doc:"Run relay garbage collection.") relay_gc_cmd
let relay_register = Cmdliner.Cmd.v (Cmdliner.Cmd.info "register" ~doc:"Register Ed25519 identity on the relay.") relay_register_cmd
let relay_dm = Cmdliner.Cmd.v (Cmdliner.Cmd.info "dm" ~doc:"Send or receive cross-host direct messages.") relay_dm_cmd

let relay_group =
  Cmdliner.Cmd.group
    ~default:relay_status_cmd
    (Cmdliner.Cmd.info "relay" ~doc:"Cross-machine relay: serve, connect, setup, status, list, rooms, gc, identity, register, dm.")
    [ relay_serve; relay_connect; relay_setup; relay_status; relay_list; relay_rooms; relay_gc; relay_identity; relay_register; relay_dm ]

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

(* --- subcommand: setcap --------------------------------------------------- *)

let setcap_cmd =
  let apply =
    Cmdliner.Arg.(value & flag & info [ "apply" ]
                    ~doc:"Exec `sudo setcap cap_sys_ptrace=ep <interp>` (needs tty + sudo).")
  in
  let json =
    Cmdliner.Arg.(value & flag & info [ "json" ] ~doc:"Machine-readable output.")
  in
  let+ apply = apply
  and+ json = json in
  match find_python_script "c2c_setcap.py" with
  | None ->
      Printf.eprintf "error: cannot find c2c_setcap.py. Run from inside the c2c git repo.\n%!";
      exit 1
  | Some script ->
      let args = [ "python3"; script ] in
      let args = if apply then args @ [ "--apply" ] else args in
      let args = if json then args @ [ "--json" ] else args in
      Unix.execvp "python3" (Array.of_list args)

let setcap = Cmdliner.Cmd.v (Cmdliner.Cmd.info "setcap"
                               ~doc:"Grant CAP_SYS_PTRACE to the c2c Python interpreter (only needed for Codex PTY notify daemon; OpenCode + Kimi use non-PTY delivery).")
               setcap_cmd

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


(* --- install: self (copy binary to ~/.local/bin) ------------------------- *)

let do_install_self ~output_mode ~dest_opt ~with_mcp_server =
  let dest_dir =
    match dest_opt with
    | Some d -> d
    | None ->
        let home = Sys.getenv "HOME" in
        home // ".local" // "bin"
  in
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

(* --- subcommand: init — defined after do_install_client below ----------- *)

(* --- subcommand: setup --------------------------------------------------- *)

let alias_words = [| "aalto"; "aimu"; "aivi"; "alder"; "alm"; "alto"; "anvi"; "arvu"; "aska"; "aster"; "auru"; "briar"; "brio"; "cedar"; "clover"; "corin"; "drift"; "eira"; "elmi"; "ember"; "fenna"; "fennel"; "ferni"; "fjord"; "glade"; "harbor"; "havu"; "hearth"; "helio"; "heron"; "hilla"; "hovi"; "ilma"; "ilmi"; "isvi"; "jara"; "jori"; "junna"; "kaari"; "kajo"; "kalla"; "karu"; "keiju"; "kelo"; "kesa"; "ketu"; "kielo"; "kiru"; "kiva"; "kivi"; "koru"; "kuura"; "laine"; "laku"; "lehto"; "leimu"; "lemu"; "linna"; "lintu"; "lumi"; "lumo"; "lyra"; "marli"; "meadow"; "meru"; "miru"; "mire"; "moro"; "muoto"; "naava"; "nallo"; "niva"; "nori"; "nova"; "nuppu"; "nyra"; "oak"; "oiva"; "olmu"; "ondu"; "orvi"; "otava"; "paju"; "palo"; "pebble"; "pihla"; "pilvi"; "puro"; "quill"; "rain"; "reed"; "revna"; "rilla"; "river"; "roan"; "roihu"; "rook"; "rowan"; "runna"; "sage"; "saima"; "sarka"; "selka"; "silo"; "sirra"; "sola"; "solmu"; "sora"; "sprig"; "starling"; "sula"; "suvi"; "taika"; "tala"; "tavi"; "tilia"; "tovi"; "tuuli"; "tyyni"; "ulma"; "usva"; "valo"; "veru"; "velu"; "vesi"; "viima"; "vireo"; "vuono"; "willow"; "yarrow"; "yola" |]

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
  let suffix = C2c_start.generate_alias () in
  Printf.sprintf "%s-%s" client suffix

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
  let dir_name = Filename.basename (
    let n = String.length target_dir in
    if n > 1 && target_dir.[n-1] = '/' then String.sub target_dir 0 (n-1)
    else target_dir) in
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
  (* Find plugin source: prefer CWD-relative (c2c dev repo), fall back to global install path. *)
  let home = try Sys.getenv "HOME" with Not_found -> "" in
  let global_plugin_path = home // ".config" // "opencode" // "plugins" // "c2c.ts" in
  let copy_file ~src ~dst =
    let ic = open_in_bin src in
    let oc = open_out_bin (dst ^ ".tmp") in
    Fun.protect ~finally:(fun () -> close_in ic; close_out oc) (fun () ->
      let buf = Bytes.create 65536 in
      let rec loop () =
        let n = input ic buf 0 (Bytes.length buf) in
        if n > 0 then (output oc buf 0 n; loop ())
      in
      loop ());
    Unix.rename (dst ^ ".tmp") dst
  in
  let file_size path =
    try (Unix.stat path).Unix.st_size with Unix.Unix_error _ -> 0
  in
  let local_plugin = ".opencode" // "plugins" // "c2c.ts" in
  let plugin_src =
    if Sys.file_exists local_plugin then Some local_plugin
    else if Sys.file_exists global_plugin_path && file_size global_plugin_path >= 1024 then
      Some global_plugin_path
    else None
  in
  let plugin_note =
    match plugin_src with
    | None ->
        Printf.sprintf "plugin not found — run: c2c install opencode (from c2c repo, or copy .opencode/plugins/c2c.ts to %s)" global_plugin_path
    | Some src ->
        let plugins_dir = config_dir // "plugins" in
        (try Unix.mkdir plugins_dir 0o755 with Unix.Unix_error _ -> ());
        let dest = plugins_dir // "c2c.ts" in
        (try
           copy_file ~src ~dst:dest;
           (* When source is local (real plugin from c2c repo), always update the
              global plugin so ~/.config/opencode/plugins/c2c.ts gets the real
              content with self-detect defer logic. Idempotent if already correct. *)
           let global_note =
             if src = local_plugin then begin
               (try
                  let gdir = Filename.dirname global_plugin_path in
                  (try Unix.mkdir gdir 0o755 with Unix.Unix_error _ -> ());
                  copy_file ~src ~dst:global_plugin_path;
                  " + global updated"
                with _ -> " (global update failed)")
             end else ""
           in
           Printf.sprintf "plugin installed to %s%s" dest global_note
         with _ -> "plugin copy failed")
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
# Calls 'c2c hook' which drains the inbox and outputs messages.
# c2c hook self-regulates runtime to prevent Node.js ECHILD race.
#
# IMPORTANT: do NOT use `exec c2c hook`. Claude Code's Node.js hook runner
# tracks the initially-spawned bash PID, and when bash exec's to the c2c
# binary the runner's waitpid() bookkeeping gets confused and surfaces
# `ECHILD: unknown error, waitpid` on every tool call. Running c2c as a
# bash subprocess and exiting bash normally fixes it.
#
# Required env vars (set by c2c start or the MCP server entry):
#   C2C_MCP_SESSION_ID   — broker session id
#   C2C_MCP_BROKER_ROOT  — absolute path to broker root dir

if command -v c2c >/dev/null 2>&1; then
    c2c hook
    exit 0
fi
# c2c binary missing: sleep ~50ms to avoid fast-exit ECHILD, then exit cleanly.
sleep 0.05
exit 0
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
            | `Assoc m -> (match List.assoc_opt "matcher" m with
              | Some (`String ".*") -> true
              | Some (`String "^(?!mcp__).*") -> true
              | _ -> false)
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
              let new_hooks = if has_hook then existing_hooks else existing_hooks @ [ hook_entry ] in
              let m_without_matcher_or_hooks =
                List.filter (fun (k, _) -> k <> "matcher" && k <> "hooks") m
              in
              `Assoc (("matcher", `String "^(?!mcp__).*")
                      :: m_without_matcher_or_hooks
                      @ [ ("hooks", `List new_hooks) ])
          | _ ->
              `Assoc [ ("matcher", `String "^(?!mcp__).*"); ("hooks", `List [ hook_entry ]) ]
        in
        let hooks = List.filter (fun (k, _) -> k <> "PostToolUse") hooks in
        let hooks = hooks @ [ ("PostToolUse", `List (other_groups @ [ target_group ])) ] in
        let fields = List.filter (fun (k, _) -> k <> "hooks") fields in
        `Assoc (fields @ [ ("hooks", `Assoc hooks) ])
    | _ ->
        `Assoc [ ("hooks", `Assoc [ ("PostToolUse", `List [ `Assoc [ ("matcher", `String "^(?!mcp__).*"); ("hooks", `List [ hook_entry ]) ] ]) ]) ]
  in
  json_write_file settings_path settings

(* --- PATH detection helper, shared by install dispatchers --------------- *)

let which_binary name =
  match Sys.getenv_opt "PATH" with
  | None -> None
  | Some path ->
      let sep = if Sys.win32 then ';' else ':' in
      let dirs = String.split_on_char sep path in
      List.find_map (fun d ->
        if d = "" then None
        else
          let candidate = d // name in
          if Sys.file_exists candidate then Some candidate else None) dirs

(* --- install: claude (MCP server + PostToolUse hook) ---------------------- *)

let setup_claude ~output_mode ~root ~alias_val ~alias_opt ~server_path ~mcp_command ~force ~channel_delivery =
  let claude_dir = resolve_claude_dir () in
  let claude_json = Filename.concat claude_dir ".claude.json" in
  let config =
    if Sys.file_exists claude_json then json_read_file claude_json
    else `Assoc []
  in
  let env_pairs =
    [ ("C2C_MCP_BROKER_ROOT", `String root)
    ; ("C2C_MCP_AUTO_REGISTER_ALIAS", `String alias_val)
    ; ("C2C_MCP_AUTO_JOIN_ROOMS", `String "swarm-lounge")
    ] @ (if channel_delivery then [ ("C2C_MCP_CHANNEL_DELIVERY", `String "1") ] else [])
  in
  let mcp_entry =
    `Assoc
      [ ("command", `String mcp_command)
      ; ("args", `List (if mcp_command = "c2c-mcp-server" then [] else [ `String "exec"; `String "--"; `String server_path ]))
      ; ("env", `Assoc env_pairs)
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
  let settings_path = Filename.concat claude_dir "settings.json" in
  let hook_script = Filename.concat claude_dir "hooks" // "c2c-inbox-check.sh" in
  let script_changed = ref false in
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
     let hook_content = claude_hook_script in
     let existing =
       if Sys.file_exists hook_script then
         try
           let ic = open_in hook_script in
           Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
             really_input_string ic (in_channel_length ic))
         with _ -> ""
       else ""
     in
     if existing <> hook_content then script_changed := true;
     let oc = open_out hook_script in
     output_string oc hook_content;
     close_out oc;
     Unix.chmod hook_script 0o755
   with Unix.Unix_error _ -> ());
  let hook_registered = ref false in
  let settings_changed = ref false in
  let target_matcher = "^(?!mcp__).*" in
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
        let entry_has_hook entry =
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
        in
        let already = List.exists entry_has_hook post_tool_use in
        hook_registered := already;
        let upgraded_post = List.map (fun entry ->
          if entry_has_hook entry then
            match entry with
            | `Assoc e ->
                let current_matcher = match List.assoc_opt "matcher" e with
                  | Some (`String s) -> Some s
                  | _ -> None
                in
                if current_matcher = Some target_matcher then entry
                else begin
                  settings_changed := true;
                  let rest = List.filter (fun (k, _) -> k <> "matcher") e in
                  `Assoc (("matcher", `String target_matcher) :: rest)
                end
            | _ -> entry
          else entry
        ) post_tool_use in
        if not already then begin
          settings_changed := true;
          let new_entry = `Assoc [ ("matcher", `String target_matcher); ("hooks", `List [ `Assoc [ ("type", `String "command"); ("command", `String hook_script) ] ]) ] in
          let new_post = upgraded_post @ [ new_entry ] in
          let new_hooks = List.filter (fun (k, _) -> k <> "PostToolUse") hooks @ [ ("PostToolUse", `List new_post) ] in
          let new_fields = List.filter (fun (k, _) -> k <> "hooks") fields @ [ ("hooks", `Assoc new_hooks) ] in
          `Assoc new_fields
        end else if !settings_changed then begin
          let new_hooks = List.filter (fun (k, _) -> k <> "PostToolUse") hooks @ [ ("PostToolUse", `List upgraded_post) ] in
          let new_fields = List.filter (fun (k, _) -> k <> "hooks") fields @ [ ("hooks", `Assoc new_hooks) ] in
          `Assoc new_fields
        end else
          `Assoc fields
    | _ -> `Assoc []
  in
  if !settings_changed then json_write_file settings_path settings;
  let hook_status =
    if !hook_registered && not !settings_changed && not !script_changed then "already registered"
    else if !hook_registered && !script_changed && not !settings_changed then "script updated"
    else if !hook_registered then "matcher upgraded"
    else "registered"
  in
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
       let hook_dir = Filename.concat claude_dir "hooks" in
       let hook_script = Filename.concat hook_dir "c2c-inbox-check.sh" in
       let mark = "x" in
       Printf.printf "Configured Claude Code for c2c:\n";
       Printf.printf "  - [%s] MCP server:     %s/.claude.json\n" mark claude_dir;
       Printf.printf "  - [%s] PostToolUse hook: %s/settings.json\n" mark claude_dir;
       Printf.printf "  - [%s] Inbox hook script: %s\n" mark hook_script;
       Printf.printf "\n  alias:       %s\n" alias_val;
       Printf.printf "  broker root: %s\n" root;
       if !hook_registered && not !settings_changed && not !script_changed then
         Printf.printf "\n  (hook was already registered — no changes made)\n"
       else if !hook_registered && !script_changed && not !settings_changed then
         Printf.printf "\n  (hook already registered; script body updated at %s)\n" hook_script
       else if !hook_registered then
         Printf.printf "\n  (hook already registered; upgraded matcher to %s)\n" target_matcher
       else
         Printf.printf "\nRestart Claude Code to pick up the new MCP server.\n";
       let alias_str = match alias_opt with Some a -> " -a " ^ a | None -> "" in
       let force_str = if force then " --force" else "" in
       Printf.printf "\nTo use a custom profile directory:\n";
       Printf.printf "  CLAUDE_CONFIG_DIR=/path/to/profile c2c install claude%s%s\n" alias_str force_str)

(* --- install: crush (JSON) --- *)

let setup_crush ~output_mode ~root ~alias_val ~server_path =
  let config_path = Filename.concat (Sys.getenv "HOME") (".config" // "crush" // "crush.json") in
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
  (try
     let rec mkdir_p d =
       if Sys.file_exists d then () else begin
         mkdir_p (Filename.dirname d);
         Unix.mkdir d 0o755
       end
     in
     mkdir_p (Filename.dirname config_path)
   with Unix.Unix_error _ -> ());
  json_write_file config_path config;
  match output_mode with
  | Json ->
      print_json (`Assoc
        [ ("ok", `Bool true)
        ; ("client", `String "crush")
        ; ("alias", `String alias_val)
        ; ("broker_root", `String root)
        ; ("config", `String config_path)
        ])
  | Human ->
      Printf.printf "Configured Crush for c2c (experimental).\n";
      Printf.printf "  alias:       %s\n" alias_val;
      Printf.printf "  broker root: %s\n" root;
      Printf.printf "  config:      %s\n" config_path;
      Printf.printf "  server:      %s\n" server_path

(* --- install: shared dispatcher (used by `c2c install <client>` and TUI) --- *)

let resolve_mcp_server_paths ~output_mode =
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
    if Filename.is_relative server_path then Sys.getcwd () // server_path
    else server_path
  in
  let mcp_command = match which_binary "c2c-mcp-server" with
    | Some _ -> "c2c-mcp-server"
    | None -> server_path
  in
  (server_path, mcp_command)

let do_install_client ?(channel_delivery=false) ~output_mode ~client ~alias_opt ~broker_root_opt ~target_dir_opt ~force () =
  let root =
    match broker_root_opt with
    | Some r -> r
    | None -> resolve_broker_root ()
  in
  let alias_val =
    match alias_opt with
    | Some a -> a
    | None ->
        let a = default_alias_for_client client in
        Printf.eprintf "[c2c setup] no --alias given; auto-picked alias=%s. Pass --alias NAME to override.\n%!" a;
        a
  in
  let (server_path, mcp_command) = resolve_mcp_server_paths ~output_mode in
  match String.lowercase_ascii client with
  | "claude" -> setup_claude ~output_mode ~root ~alias_val ~alias_opt ~server_path ~mcp_command ~force ~channel_delivery
  | "codex" -> setup_codex ~output_mode ~root ~alias_val ~server_path
  | "kimi" -> setup_kimi ~output_mode ~root ~alias_val ~server_path
  | "opencode" -> setup_opencode ~output_mode ~root ~alias_val ~server_path ~target_dir_opt
  | "crush" -> setup_crush ~output_mode ~root ~alias_val ~server_path
  | _ ->
      (match output_mode with
       | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String (Printf.sprintf "unknown client '%s'. Use: claude, codex, kimi, opencode, crush" client)) ])
       | Human ->
           Printf.eprintf "error: unknown client '%s'. Use: claude, codex, kimi, opencode, crush\n%!" client;
           exit 1)

(* --- install: detection + TUI --------------------------------------------- *)

let known_clients = [ "claude"; "codex"; "opencode"; "kimi"; "crush" ]

let self_installed_path () =
  let home = try Sys.getenv "HOME" with Not_found -> "" in
  let p = home // ".local" // "bin" // "c2c" in
  if Sys.file_exists p then Some p else None

let client_configured client =
  let home = try Sys.getenv "HOME" with Not_found -> "" in
  match String.lowercase_ascii client with
  | "claude" ->
      let p = home // ".claude.json" in
      if not (Sys.file_exists p) then false
      else
        (try
           match json_read_file p with
           | `Assoc fields ->
               (match List.assoc_opt "mcpServers" fields with
                | Some (`Assoc m) -> List.mem_assoc "c2c" m
                | _ -> false)
           | _ -> false
         with _ -> false)
  | "codex" ->
      let p = home // ".codex" // "config.toml" in
      if not (Sys.file_exists p) then false
      else
        (try
           let ic = open_in p in
           let s =
             Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
               really_input_string ic (in_channel_length ic))
           in
           let needle = "[mcp_servers.c2c]" in
           let nl = String.length needle and hl = String.length s in
           let rec loop i =
             i <= hl - nl
             && (String.sub s i nl = needle || loop (i + 1))
           in
           loop 0
         with _ -> false)
  | "kimi" ->
      let p = home // ".kimi" // "mcp.json" in
      if not (Sys.file_exists p) then false
      else
        (try
           match json_read_file p with
           | `Assoc fields ->
               (match List.assoc_opt "mcpServers" fields with
                | Some (`Assoc m) -> List.mem_assoc "c2c" m
                | _ -> false)
           | _ -> false
         with _ -> false)
  | "opencode" ->
      let p = Sys.getcwd () // ".opencode" // "opencode.json" in
      if not (Sys.file_exists p) then false
      else
        (try
           match json_read_file p with
           | `Assoc fields ->
               (match List.assoc_opt "mcp" fields with
                | Some (`Assoc m) -> List.mem_assoc "c2c" m
                | _ -> false)
           | _ -> false
         with _ -> false)
  | "crush" ->
      let p = home // ".config" // "crush" // "crush.json" in
      if not (Sys.file_exists p) then false
      else
        (try
           match json_read_file p with
           | `Assoc fields ->
               (match List.assoc_opt "mcpServers" fields with
                | Some (`Assoc m) -> List.mem_assoc "c2c" m
                | _ -> false)
           | _ -> false
         with _ -> false)
  | _ -> false

(* [detect_installation ()] returns the detection snapshot:
   (self_installed, [(client, binary_on_path, configured)]) *)
let detect_installation () =
  let self = self_installed_path () <> None in
  let clients = List.map (fun c ->
    (c, which_binary c <> None, client_configured c)
  ) known_clients in
  (self, clients)

let prompt_yn ?(default_yes = true) q =
  Printf.printf "%s " q;
  let suffix = if default_yes then "[Y/n]: " else "[y/N]: " in
  print_string suffix;
  let () = try flush stdout with _ -> () in
  match (try Some (input_line stdin) with End_of_file -> None) with
  | None -> default_yes
  | Some s ->
      let t = String.lowercase_ascii (String.trim s) in
      if t = "" then default_yes
      else (t.[0] = 'y')

let prompt_channel_delivery () =
  Printf.printf
    "\n  Enable experimental channel-delivery (C2C_MCP_CHANNEL_DELIVERY=1)?\n\
    \    When Claude Code declares support for experimental.claude/channel,\n\
    \    the broker auto-injects inbound messages into the transcript without\n\
    \    polling. Standard Claude Code doesn't declare this capability, so\n\
    \    today it's a no-op — but if a future build enables it, auto-injection\n\
    \    would fire unprompted. Security-conscious users may prefer to leave\n\
    \    it off and rely on the PostToolUse hook + poll_inbox instead.\n";
  prompt_yn ~default_yes:false "  Enable channel delivery?"

let run_install_tui ~alias_opt ~broker_root_opt =
  let (self, clients) = detect_installation () in
  Printf.printf "c2c installer\n";
  Printf.printf "─────────────\n\n";
  Printf.printf "Here's the plan — press [Enter] to proceed with defaults.\n\n";
  let self_default = not self in
  let client_defaults = List.map (fun (c, on_path, configured) ->
    let do_it = on_path && not configured in
    (c, on_path, configured, do_it)
  ) clients in
  let mark b = if b then "[x]" else "[ ]" in
  let self_suffix =
    if self then "→ ~/.local/bin/c2c (already present)"
    else "→ install to ~/.local/bin/c2c"
  in
  Printf.printf "  %s %-22s %s\n" (mark self_default) "install c2c binary" self_suffix;
  List.iter (fun (c, on_path, configured, do_it) ->
    let label = Printf.sprintf "configure %s" c in
    let suffix =
      if not on_path then "→ not on PATH, skipping"
      else if configured then "→ already configured"
      else "→ detected"
    in
    Printf.printf "  %s %-22s %s\n" (mark do_it) label suffix
  ) client_defaults;
  Printf.printf "\nPress [Enter] to proceed, [c] to customize, [n] to abort: ";
  let () = try flush stdout with _ -> () in
  let choice =
    match (try Some (input_line stdin) with End_of_file -> None) with
    | None -> ""
    | Some s -> String.lowercase_ascii (String.trim s)
  in
  let (do_self, do_clients) =
    if choice = "n" || choice = "no" || choice = "abort" then begin
      Printf.printf "Aborted.\n";
      exit 0
    end
    else if choice = "c" || choice = "customize" then begin
      Printf.printf "\nCustomize:\n";
      let s =
        if self then
          prompt_yn ~default_yes:false "  Reinstall c2c binary?"
        else prompt_yn "  Install c2c binary?"
      in
      let cs = List.map (fun (c, on_path, configured, _default) ->
        if not on_path then (c, false)
        else
          let q =
            if configured
            then Printf.sprintf "  Reconfigure %s?" c
            else Printf.sprintf "  Configure %s?" c
          in
          let default = not configured in
          (c, prompt_yn ~default_yes:default q)
      ) client_defaults in
      (s, cs)
    end
    else
      let cs = List.map (fun (c, _, _, do_it) -> (c, do_it)) client_defaults in
      (self_default, cs)
  in
  let any_action = do_self || List.exists (fun (_, do_it) -> do_it) do_clients in
  if not any_action then
    Printf.printf "\nNothing to do.\n"
  else begin
    Printf.printf "\n";
    if do_self then begin
      Printf.printf "→ Installing c2c binary...\n";
      do_install_self ~output_mode:Human ~dest_opt:None ~with_mcp_server:false
    end;
    List.iter (fun (c, do_it) ->
      if do_it then begin
        Printf.printf "\n→ Configuring %s...\n" c;
        let channel_delivery =
          if c = "claude" then prompt_channel_delivery () else false
        in
        do_install_client ~channel_delivery ~output_mode:Human ~client:c ~alias_opt
          ~broker_root_opt ~target_dir_opt:None ~force:false ()
      end
    ) do_clients;
    Printf.printf "\nDone.\n"
  end

(* --- install: Cmdliner wiring --------------------------------------------- *)

let install_common_args () =
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
  (alias, broker_root, target_dir, force)

let install_self_subcmd =
  let dest =
    Cmdliner.Arg.(value & opt (some string) None & info [ "dest"; "d" ] ~docv:"DIR" ~doc:"Install destination (default: ~/.local/bin).")
  in
  let mcp_server =
    Cmdliner.Arg.(value & flag & info [ "mcp-server" ] ~doc:"Also install the c2c MCP server binary as ~/.local/bin/c2c-mcp-server.")
  in
  let term =
    let+ json = json_flag
    and+ dest_opt = dest
    and+ with_mcp_server = mcp_server in
    let output_mode = if json then Json else Human in
    do_install_self ~output_mode ~dest_opt ~with_mcp_server
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "self"
       ~doc:"Install the running c2c binary to ~/.local/bin.")
    term

let install_client_subcmd client =
  let (alias, broker_root, target_dir, force) = install_common_args () in
  let term =
    let+ json = json_flag
    and+ alias_opt = alias
    and+ broker_root_opt = broker_root
    and+ target_dir_opt = target_dir
    and+ force = force in
    let output_mode = if json then Json else Human in
    let channel_delivery =
      if client = "claude" && output_mode = Human then prompt_channel_delivery () else false
    in
    do_install_client ~channel_delivery ~output_mode ~client ~alias_opt ~broker_root_opt ~target_dir_opt ~force ()
  in
  let doc = Printf.sprintf "Configure %s for c2c messaging." client in
  Cmdliner.Cmd.v (Cmdliner.Cmd.info client ~doc) term

let install_all_subcmd =
  let (alias, broker_root, _target_dir, _force) = install_common_args () in
  let term =
    let+ json = json_flag
    and+ alias_opt = alias
    and+ broker_root_opt = broker_root in
    let output_mode = if json then Json else Human in
    let (self, clients) = detect_installation () in
    if not self then begin
      if output_mode = Human then Printf.printf "→ Installing c2c binary...\n";
      do_install_self ~output_mode ~dest_opt:None ~with_mcp_server:false
    end;
    List.iter (fun (c, on_path, configured) ->
      if on_path && not configured then begin
        if output_mode = Human then Printf.printf "\n→ Configuring %s...\n" c;
        do_install_client ~output_mode ~client:c ~alias_opt ~broker_root_opt
          ~target_dir_opt:None ~force:false ()
      end
    ) clients;
    if output_mode = Human then Printf.printf "\nDone.\n"
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "all"
       ~doc:"Install c2c binary and auto-configure every detected client (scriptable, no prompts).")
    term

let install_default_term =
  let (alias, broker_root, _target_dir, _force) = install_common_args () in
  let+ alias_opt = alias
  and+ broker_root_opt = broker_root in
  run_install_tui ~alias_opt ~broker_root_opt

(* --- repo config helpers (also used by init_cmd + repo subcommand) ------- *)

let repo_config_path () =
  Filename.concat (Sys.getcwd ()) ".c2c" // "repo.json"

let load_repo_config () =
  let path = repo_config_path () in
  if not (Sys.file_exists path) then `Assoc []
  else
    (try Yojson.Safe.from_file path
     with _ -> `Assoc [])

let save_repo_config json =
  let path = repo_config_path () in
  let dir = Filename.dirname path in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error _ -> ());
  json_write_file path json

let valid_strategies = [ "first-alive"; "round-robin"; "broadcast" ]

(* --- subcommand: init ---------------------------------------------------- *)

let detect_client () =
  (match Sys.getenv_opt "C2C_MCP_SESSION_ID" with
   | Some sid ->
       let clients = [ "opencode"; "claude"; "codex"; "kimi"; "crush" ] in
       List.find_opt (fun c ->
         let cl = String.length c in
         String.length sid >= cl && String.sub sid 0 cl = c) clients
   | None -> None)
  |> (function
      | Some _ as v -> v
      | None ->
          let has_bin name =
            let path = try Sys.getenv "PATH" with Not_found -> "" in
            List.exists (fun d -> Sys.file_exists (d // name))
              (String.split_on_char ':' path)
          in
          List.find_opt has_bin [ "opencode"; "claude"; "codex"; "kimi" ])

let init_cmd =
  let open Cmdliner in
  let client_opt =
    Arg.(value & opt (some string) None & info ["client"; "c"] ~docv:"CLIENT"
           ~doc:"Client to configure: claude, opencode, codex, kimi. Auto-detected when omitted.")
  in
  let alias_opt_arg =
    Arg.(value & opt (some string) None & info ["alias"; "a"] ~docv:"ALIAS"
           ~doc:"Alias to register under. Auto-generated when omitted.")
  in
  let room_arg =
    Arg.(value & opt string "swarm-lounge" & info ["room"; "r"] ~docv:"ROOM"
           ~doc:"Room to join on init (default: swarm-lounge). Pass empty string to skip.")
  in
  let no_setup =
    Arg.(value & flag & info ["no-setup"]
           ~doc:"Skip client MCP setup; only register and join room.")
  in
  let supervisor_arg =
    Arg.(value & opt (some string) None & info ["supervisor"; "S"] ~docv:"ALIAS[,ALIAS2,...]"
           ~doc:"Permission supervisor alias(es). Written to .c2c/repo.json. Equivalent to c2c repo set supervisor.")
  in
  let supervisor_strategy_arg =
    Arg.(value & opt (some string) None & info ["supervisor-strategy"] ~docv:"STRATEGY"
           ~doc:"Supervisor dispatch strategy: first-alive (default), round-robin, broadcast.")
  in
  let+ json = json_flag
  and+ client_opt = client_opt
  and+ alias_opt = alias_opt_arg
  and+ room = room_arg
  and+ no_setup = no_setup
  and+ supervisor_opt = supervisor_arg
  and+ supervisor_strategy_opt = supervisor_strategy_arg in
  let output_mode = if json then Json else Human in
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in

  let client_resolved =
    match client_opt with
    | Some c -> Some c
    | None -> detect_client ()
  in

  let setup_result =
    if no_setup then `Skipped
    else match client_resolved with
      | None ->
          (match output_mode with
           | Human ->
               Printf.printf "No client detected. Specify one with --client:\n";
               Printf.printf "  c2c init --client opencode\n";
               Printf.printf "  c2c init --client claude\n";
               Printf.printf "  c2c init --client codex\n"
           | Json -> ());
          `No_client
      | Some client ->
          (try
             do_install_client ~output_mode ~client ~alias_opt ~broker_root_opt:(Some root) ~target_dir_opt:None ~force:false ();
             `Ok client
           with e -> `Error (Printexc.to_string e))
  in

  let session_id =
    match Sys.getenv_opt "C2C_MCP_SESSION_ID" with
    | Some s when String.trim s <> "" -> s
    | _ -> generate_session_id ()
  in
  let alias =
    match alias_opt with
    | Some a -> a
    | None ->
        let a = match client_resolved with
          | Some c -> default_alias_for_client c
          | None -> generate_alias ()
        in
        Printf.eprintf "[c2c register] no --alias given; auto-picked alias=%s. Pass --alias NAME to override.\n%!" a;
        a
  in
  (* Ensure Ed25519 identity exists — idempotent, safe to run always. *)
  let _identity_init_rc = Sys.command "c2c relay identity init 2>/dev/null" in
  ignore _identity_init_rc;

  C2c_mcp.Broker.register broker ~session_id ~alias ~pid:None ~pid_start_time:None;

  let room_result =
    if String.trim room = "" then `Skipped
    else
      (try
         let (_ : C2c_mcp.room_member list) =
           C2c_mcp.Broker.join_room broker ~session_id ~alias ~room_id:room
         in
         `Joined room
       with Invalid_argument msg -> `Error msg)
  in

  let supervisor_result =
    match supervisor_opt with
    | None -> `Skipped
    | Some sup_str ->
        let aliases = List.filter (fun s -> s <> "") (String.split_on_char ',' sup_str) in
        if aliases = [] then `Error "empty supervisor list"
        else begin
          (match supervisor_strategy_opt with
           | Some s when not (List.mem s valid_strategies) ->
               Printf.eprintf "error: unknown strategy '%s'. Use: %s\n%!"
                 s (String.concat ", " valid_strategies);
               exit 1
           | _ -> ());
          let config = load_repo_config () in
          let fields = match config with `Assoc f -> f | _ -> [] in
          let supervisor_val = `List (List.map (fun a -> `String a) aliases) in
          let fields' = ref
            (("supervisors", supervisor_val)
             :: List.filter (fun (k, _) -> k <> "supervisors" && k <> "permission_supervisors"
                                           && k <> "supervisor_strategy") fields)
          in
          (match supervisor_strategy_opt with
           | Some s -> fields' := ("supervisor_strategy", `String s) :: !fields'
           | None -> ());
          save_repo_config (`Assoc !fields');
          `Set (aliases, supervisor_strategy_opt)
        end
  in

  (match output_mode with
   | Json ->
       let setup_json = match setup_result with
         | `Ok c -> `String (Printf.sprintf "configured %s" c)
         | `Skipped -> `String "skipped"
         | `No_client -> `String "no client detected"
         | `Error e -> `String (Printf.sprintf "error: %s" e)
       in
       let room_json = match room_result with
         | `Joined r -> `String r
         | `Skipped -> `Null
         | `Error e -> `String (Printf.sprintf "error: %s" e)
       in
       let supervisor_json = match supervisor_result with
         | `Set (aliases, strat) ->
             `Assoc ([ ("ok", `Bool true); ("aliases", `List (List.map (fun a -> `String a) aliases)) ]
                     @ (match strat with Some s -> [("strategy", `String s)] | None -> []))
         | `Skipped -> `Null
         | `Error e -> `Assoc [("ok", `Bool false); ("error", `String e)]
       in
       print_json (`Assoc
         [ ("ok", `Bool true)
         ; ("session_id", `String session_id)
         ; ("alias", `String alias)
         ; ("broker_root", `String root)
         ; ("setup", setup_json)
         ; ("room", room_json)
         ; ("supervisor", supervisor_json)
         ])
   | Human ->
       Printf.printf "\nc2c init complete!\n";
       Printf.printf "  session:  %s\n" session_id;
       Printf.printf "  alias:    %s\n" alias;
       Printf.printf "  broker:   %s\n" root;
       (match setup_result with
        | `Ok c -> Printf.printf "  setup:    %s configured\n" c
        | `Skipped -> ()
        | `No_client -> Printf.printf "  setup:    skipped (no client detected)\n"
        | `Error e -> Printf.printf "  setup:    error — %s\n" e);
       (match room_result with
        | `Joined r -> Printf.printf "  room:     joined #%s\n" r
        | `Skipped -> ()
        | `Error e -> Printf.printf "  room:     error joining — %s\n" e);
       (match supervisor_result with
        | `Set (aliases, strat) ->
            Printf.printf "  supervisor: %s%s\n" (String.concat ", " aliases)
              (match strat with Some s -> Printf.sprintf " (strategy: %s)" s | None -> "")
        | `Skipped -> ()
        | `Error e -> Printf.printf "  supervisor: error — %s\n" e);
       Printf.printf "\nYou're ready! Try:\n";
       Printf.printf "  c2c list              — see peers\n";
       Printf.printf "  c2c send ALIAS MSG    — send a message\n";
       Printf.printf "  c2c poll-inbox        — check your inbox\n";
       Printf.printf "  c2c send-room %s MSG  — chat in the room\n" room)

let init =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "init"
       ~doc:"One-command project onboarding: configure client MCP, register, join swarm-lounge."
       ~man:[ `S "DESCRIPTION"
            ; `P "$(b,c2c init) configures the current AI client for c2c messaging, registers \
                  the session, and joins swarm-lounge. Run once per project."
            ; `P "Auto-detects the client from $(b,C2C_MCP_SESSION_ID) or installed binaries. \
                  Override with $(b,--client)."
            ; `S "EXAMPLES"
            ; `P "$(b,c2c init)  — auto-detect client, configure, register, join swarm-lounge"
            ; `P "$(b,c2c init --client opencode --alias my-bot)  — explicit client and alias"
            ; `P "$(b,c2c init --no-setup --room project-room)  — skip MCP setup, join custom room"
            ; `P "$(b,c2c init --supervisor coordinator1)  — set permission supervisor"
            ; `P "$(b,c2c init --supervisor coordinator1,planner1 --supervisor-strategy round-robin)  — multi-supervisor"
            ])
    init_cmd

let install =
  let info = Cmdliner.Cmd.info "install"
    ~doc:"Install c2c — binary and/or client integrations."
    ~man:
      [ `S "DESCRIPTION"
      ; `P "With no subcommand, $(b,c2c install) runs an interactive TUI that \
            detects which clients are on PATH and offers to configure each. \
            Press $(b,Enter) to accept the defaults (install c2c binary + \
            configure every detected client that isn't already set up), \
            $(b,c) to customize, or $(b,n) to abort."
      ; `P "Use the subcommands for scriptable (non-interactive) installs: \
            $(b,c2c install self) installs only the binary; \
            $(b,c2c install claude|codex|opencode|kimi|crush) configures one \
            client; $(b,c2c install all) does the same as the TUI's default \
            path without prompting."
      ]
  in
  Cmdliner.Cmd.group ~default:install_default_term info
    ([ install_self_subcmd
     ; install_all_subcmd
     ]
     @ List.map install_client_subcmd known_clients)

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

(* --- subcommand: diag ----------------------------------------------------- *)

let diag_cmd =
  let name_arg =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc:"Instance name.")
  in
  let lines_arg =
    Cmdliner.Arg.(value & opt int 50 & info [ "lines"; "n" ] ~docv:"N" ~doc:"Number of stderr tail lines (default: 50).")
  in
  let+ name = name_arg
  and+ lines = lines_arg in
  let inst_dir = instances_dir () // name in
  if not (Sys.file_exists inst_dir) then begin
    Printf.eprintf "error: no instance dir for '%s'. Was it ever started?\n%!" name;
    exit 1
  end;
  (* Print last death record if any *)
  let broker_root = resolve_broker_root () in
  let deaths_path = broker_root // "deaths.jsonl" in
  let last_death =
    if Sys.file_exists deaths_path then
      (try
        let ic = open_in deaths_path in
        let last = ref None in
        (try while true do
          let line = String.trim (input_line ic) in
          if line <> "" then begin
            match Yojson.Safe.from_string line with
            | `Assoc fields ->
                (match List.assoc_opt "name" fields with
                 | Some (`String n) when n = name -> last := Some fields
                 | _ -> ())
            | _ -> ()
          end
        done with End_of_file -> ());
        close_in ic;
        !last
      with _ -> None)
    else None
  in
  (match last_death with
   | None -> ()
   | Some fields ->
       let exit_code = match List.assoc_opt "exit_code" fields with Some (`Int n) -> n | _ -> -1 in
       let duration_s = match List.assoc_opt "duration_s" fields with Some (`Float f) -> f | _ -> 0.0 in
       let ts = match List.assoc_opt "ts" fields with Some (`Float f) -> f | _ -> 0.0 in
       let t = Unix.gmtime ts in
       let ts_str = Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
         (t.Unix.tm_year + 1900) (t.Unix.tm_mon + 1) t.Unix.tm_mday
         t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec in
       Printf.printf "last death: exit=%d  duration=%.1fs  at=%s\n" exit_code duration_s ts_str);
  (* Print stderr.log tail *)
  let log_path = inst_dir // "stderr.log" in
  if not (Sys.file_exists log_path) then
    Printf.printf "no stderr.log (instance may not have produced any stderr)\n"
  else begin
    Printf.printf "\n--- stderr.log (last %d lines) ---\n" lines;
    let ic = open_in log_path in
    let all_lines = ref [] in
    (try while true do
      all_lines := input_line ic :: !all_lines
    done with End_of_file -> ());
    close_in ic;
    let all = List.rev !all_lines in
    let n = List.length all in
    let skip = max 0 (n - lines) in
    let rec drop i lst = match lst with [] -> [] | _ :: t -> if i > 0 then drop (i-1) t else lst in
    List.iter (fun l -> print_endline l) (drop skip all)
  end

let diag = Cmdliner.Cmd.v (Cmdliner.Cmd.info "diag" ~doc:"Show diagnostic info (last death + stderr tail) for a managed instance.") diag_cmd

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
  let one_hr_cache =
    Cmdliner.Arg.(value & flag & info [ "1hr-cache" ] ~doc:"Set ENABLE_PROMPT_CACHING_1H=1 (claude only; default off — 1h cache writes cost 2x, only worth it if you hit the cache).")
  in
  let+ client = client
  and+ name_opt = name
  and+ alias_opt = alias
  and+ bin_opt = bin
  and+ session_id_opt = session_id
  and+ one_hr_cache = one_hr_cache in
  let name = match name_opt with
    | Some n -> n
    | None ->
        let n = C2c_start.default_name client in
        Printf.eprintf "[c2c start] no -n given; auto-picked name=%s. Pass -n NAME to override.\n%!" n;
        n
  in
  exit (C2c_start.cmd_start ~client ~name ~extra_args:[] ?binary_override:bin_opt ?alias_override:alias_opt ?session_id_override:session_id_opt ~one_hr_cache ())

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
    end else "not running"
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

let restart_self_cmd =
  let name =
    Cmdliner.Arg.(value & pos 0 (some string) None & info [] ~docv:"NAME" ~doc:"Instance name (default: \\$C2C_MCP_SESSION_ID).")
  in
  let+ name = name in
  exit (C2c_start.cmd_restart_self ?name ())

let restart_self = Cmdliner.Cmd.v (Cmdliner.Cmd.info "restart-self" ~doc:"Signal our own managed inner client so the outer loop relaunches it. Intended for agents to reload themselves after a binary update; name falls back to \\$C2C_MCP_SESSION_ID.") restart_self_cmd

(* --- help subcommand ------------------------------------------------------- *)

(* `c2c help [COMMAND...]` is a plain-English alias for `c2c [COMMAND...] --help`.
   Re-exec ourselves with `--help` appended so we get Cmdliner's full rendering
   (man-page layout, pager, and the sanitize_help_env fix) without having to
   reach into Cmdliner internals. *)
let help_cmd =
  let args =
    Cmdliner.Arg.(
      value & pos_all string []
      & info [] ~docv:"COMMAND"
          ~doc:"Subcommand path to show help for. With no args, shows top-level help.")
  in
  let+ args = args in
  let self = if Array.length Sys.argv > 0 then Sys.argv.(0) else "c2c" in
  let new_argv = Array.of_list (self :: args @ [ "--help" ]) in
  (try Unix.execvp self new_argv
   with Unix.Unix_error (err, _, _) ->
     prerr_endline ("c2c help: " ^ Unix.error_message err);
     exit 125)

let help =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "help"
       ~doc:"Show help for c2c or a subcommand (alias for --help)."
       ~man:
         [ `S "DESCRIPTION"
         ; `P "Prints the same help as $(b,--help). With no arguments, shows the \
               top-level c2c help. Arguments are treated as a subcommand path, \
               so $(b,c2c help install) is equivalent to $(b,c2c install --help), \
               and $(b,c2c help rooms list) mirrors $(b,c2c rooms list --help)."
         ])
    help_cmd

(* --- keycode parsing for inject ------------------------------------------- *)

(** [inject_keycode s] parses a keycode literal and returns the expanded string.
    Supported keycodes:
      :enter  -> "\r"
      :esc    -> "\x1b"
      :ctrlc  -> "\x03"
      :ctrlz  -> "\x1a"
      :up     -> "\x1b[A"
      :down   -> "\x1b[B"
      :left   -> "\x1b[D"
      :right  -> "\x1b[C"
      :tab    -> "\x09"
      :backspace -> "\x7f"
    Plain text is returned as-is. Unknown :xxx forms cause an error. *)
let inject_keycode (s : string) : string =
  match s with
  | ":enter" -> "\r"
  | ":esc" -> "\x1b"
  | ":ctrlc" -> "\x03"
  | ":ctrlz" -> "\x1a"
  | ":up" -> "\x1b[A"
  | ":down" -> "\x1b[B"
  | ":left" -> "\x1b[D"
  | ":right" -> "\x1b[C"
  | ":tab" -> "\x09"
  | ":backspace" -> "\x7f"
  | other ->
      if String.length other > 0 && other.[0] = ':' then (
        Printf.eprintf "error: unknown keycode %S. Known: :enter, :esc, :ctrlc, :ctrlz, :up, :down, :left, :right, :tab, :backspace\n%!" other;
        exit 1)
      else other

(* --- UUID and timestamp helpers for history injection --- *)

(** Generate a random UUID v4 string. *)
let uuid_v4 () =
  let hex_char n =
    let hex_chars = "0123456789abcdef" in
    hex_chars.[n land 0xf]
  in
  let segment n = String.init n (fun _ -> hex_char (Random.int 16)) in
  let segments = Array.init 5 (fun i ->
    match i with
    | 0 -> segment 8
    | 1 -> segment 4
    | 2 -> "4" ^ segment 3
    | 3 -> String.make 1 "abcdef".[Random.int 6] ^ segment 3
    | 4 -> segment 12
    | _ -> segment 8)  (* should not happen *)
  in
  Printf.sprintf "%s-%s-%s-%s-%s" segments.(0) segments.(1) segments.(2) segments.(3) segments.(4)

(** Return current UTC timestamp as ISO 8601 string. *)
let timestamp_utc () =
  let t = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (t.Unix.tm_year + 1900) (t.Unix.tm_mon + 1) t.Unix.tm_mday
    t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec

(** Slugify a path for Claude project directory naming.
    "/home/xertrov/foo" -> "-home-xertrov-foo" *)
let slugify_path (path : string) : string =
  String.map (fun c -> if c = '/' then '-' else c) path

(* --- session resolution for inject (pure OCaml) --- *)

(** Read a session JSON file and return session data as an assoc list.
    Returns None if the file doesn't exist or is invalid JSON. *)
let read_session_json (path : string) : (string * Yojson.Safe.t) list option =
  try
    let json = Yojson.Safe.from_file path in
    Some (Yojson.Safe.Util.to_assoc json)
  with _ -> None

(** Find a session by session_id or PID in a session JSON file.
    Returns Some (sessionId, cwd, pid) if found. *)
let find_session_in_file (path : string) (identifier : string) :
    (string * string * int) option =
  match read_session_json path with
  | None -> None
  | Some fields ->
      let get_string key =
        try Some (List.assoc key fields |> Yojson.Safe.Util.to_string) with _ -> None
      in
      let get_int key =
        try Some (List.assoc key fields |> Yojson.Safe.Util.to_int) with _ -> None
      in
      let session_id = get_string "sessionId" in
      let name = get_string "name" in
      let pid = get_int "pid" in
      let cwd = get_string "cwd" in
      let matches =
        (match session_id with Some s when s = identifier -> true | _ -> false) ||
        (match name with Some n when n = identifier -> true | _ -> false) ||
        (match pid with Some p when string_of_int p = identifier -> true | _ -> false)
      in
      if matches then
        match session_id, cwd, pid with
        | Some sid, Some c, Some p -> Some (sid, c, p)
        | _ -> None
      else None

(** Iterate over session directories looking for a matching session.
    Returns Some (session_id, cwd, pid) if found. *)
let find_session_by_identifier (identifier : string) :
    (string * string * int) option =
  let session_dirs = [
    (Sys.getenv "HOME") ^ "/.claude/sessions";
    (Sys.getenv "HOME") ^ "/.claude-p/sessions";
    (Sys.getenv "HOME") ^ "/.claude-w/sessions";
  ] in
  let rec walk_dirs dirs =
    match dirs with
    | [] -> None
    | dir :: rest ->
        if Sys.is_directory dir then
          let entries =
            try Array.to_list (Sys.readdir dir)
            with Sys_error _ -> []
          in
          let rec check_entries entries =
            match entries with
            | [] -> walk_dirs rest
            | entry :: rest_entries ->
                let path = Filename.concat dir entry in
                (match find_session_in_file path identifier with
                 | Some result -> Some result
                 | None -> check_entries rest_entries)
          in
          check_entries entries
        else walk_dirs rest
  in
  walk_dirs session_dirs

(** Find the transcript path for a session.
    Searches in ~/.claude/projects/ for a file named <session_id>.jsonl.
    Also tries the slugified cwd path. *)
let find_transcript_path (session_id : string) (cwd : string option) : string option =
  let home = Sys.getenv "HOME" in
  let projects_dir = Filename.concat home ".claude/projects" in
  if Sys.is_directory projects_dir then
    let entries =
      try Array.to_list (Sys.readdir projects_dir)
      with Sys_error _ -> []
    in
    let rec check entries =
      match entries with
      | [] -> None
      | entry :: rest ->
          let jsonl_path = Filename.concat projects_dir (Filename.concat entry (session_id ^ ".jsonl")) in
          if Sys.file_exists jsonl_path then Some jsonl_path
          else check rest
    in
    check entries
  else None

(* --- history injection (pure OCaml) --- *)

(** Inject a message by appending a user entry to the session's history.jsonl.
    Returns the transcript path used on success, or None on failure. *)
let inject_via_history (session_id : string) (cwd : string option) (message : string) : string option =
  let transcript_path =
    match cwd with
    | Some c ->
        (* Try slugified cwd path first *)
        let slug = slugify_path c in
        let home = Sys.getenv "HOME" in
        let path = Filename.concat home (Printf.sprintf ".claude/projects/%s/%s.jsonl" slug session_id) in
        if Sys.file_exists path then Some path else None
    | None -> None
  in
  let transcript_path =
    match transcript_path with
    | Some p -> Some p
    | None ->
        (* Try to find by scanning projects dir *)
        find_transcript_path session_id cwd
  in
  match transcript_path with
  | None -> None
  | Some path ->
      let parent_uuid = uuid_v4 () in
      let entry = `Assoc [
        ("parentUuid", `String parent_uuid);
        ("isSidechain", `Bool false);
        ("promptId", `String (uuid_v4 ()));
        ("type", `String "user");
        ("message", `Assoc [
            ("role", `String "user");
            ("content", `String message)
          ]);
        ("uuid", `String (uuid_v4 ()));
        ("timestamp", `String (timestamp_utc ()));
        ("userType", `String "external");
        ("entrypoint", `String "cli");
        ("cwd", `String (Option.value cwd ~default:"/home/xertrov"));
        ("sessionId", `String session_id);
        ("version", `String "2.1.109");
        ("gitBranch", `String "HEAD")
      ] in
      (try
         let oc = open_out_gen [Open_creat; Open_append] 0o644 path in
         Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
           output_string oc (Yojson.Safe.to_string entry ^ "\n"));
         Some path
       with Sys_error _ -> None)

(* --- PTY injection (shell out to pty_inject helper) --- *)

(** Path to the pty_inject helper binary. *)
let pty_inject_path () =
  match Sys.getenv_opt "C2C_PTY_INJECT" with
  | Some p -> p
  | None -> "/home/xertrov/src/meta-agent/apps/ma_adapter_claude/priv/pty_inject"

(** Inject via PTY using the pty_inject helper.
    Writes bracketed paste sequence then Enter after submit_delay seconds. *)
let inject_via_pty (terminal_pid : int) (pts_num : string) (message : string)
    ~(submit_delay : float) : bool =
  let inject_bin = pty_inject_path () in
  if not (Sys.file_exists inject_bin) then (
    Printf.eprintf "error: pty_inject helper not found at %s\n%!" inject_bin;
    false
  ) else
    let cmd = Printf.sprintf "%s %d %s '%s' %.3f"
      inject_bin terminal_pid pts_num
      (String.escaped message) submit_delay
    in
    let rc = Sys.command cmd in
    rc = 0

(* --- PTY helpers (shared by inject and screen) --- *)

(** Extract pts number from a /dev/pts/N path string. *)
let extract_pts (path : string) : string option =
  let prefix = "/dev/pts/" in
  if String.length path > String.length prefix
     && String.sub path 0 (String.length prefix) = prefix
  then
    Some (String.sub path (String.length prefix)
            (String.length path - String.length prefix))
  else None

(** Read the tty symlink target for a given fd of a process. *)
let read_tty_link (pid : int) (fd : string) : string option =
  try
    let path = Printf.sprintf "/proc/%d/fd/%s" pid fd in
    Some (Unix.readlink path)
  with _ -> None

(** Read a file's contents as a string. *)
let read_file (path : string) : string =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    let n = in_channel_length ic in
    really_input_string ic n)

(** Find the pts number for a given PID by checking its stdio fds. *)
let resolve_pts_from_pid (pid : int) : string option =
  List.fold_left (fun acc fd ->
    match acc with
    | Some _ -> acc
    | None ->
        (match read_tty_link pid fd with
         | Some path -> extract_pts path
         | None -> None)
  ) None ["0"; "1"; "2"]

(** Check if a process has a given pts as a master tty-index.
    Returns true if the fdinfo for any fd contains "tty-index:\t<PTS>\n"
    and the fd links to /dev/ptmx. *)
let is_terminal_owner_for_pts (pid : int) (pts_num : string) : bool =
  try
    let fdinfo_dir = Printf.sprintf "/proc/%d/fdinfo" pid in
    if not (Sys.is_directory fdinfo_dir) then false
    else
      let entries = Sys.readdir fdinfo_dir in
      let result = ref false in
      Array.iter (fun entry ->
        if not !result then
          (try
             let fdinfo_path = Filename.concat fdinfo_dir entry in
             let content = read_file fdinfo_path in
             let needle = Printf.sprintf "tty-index:\t%s\n" pts_num in
             if String.length content >= String.length needle
                && String.sub content 0 (String.length needle) = needle
             then
               (try
                  let fd_path = Printf.sprintf "/proc/%d/fd/%s" pid entry in
                  let link = Unix.readlink fd_path in
                  if link = "/dev/ptmx" then result := true
                with _ -> ())
           with _ -> ())
      ) entries;
      !result
  with _ -> false

(** Walk the parent chain of a process looking for one that owns the given pts.
    Returns the terminal owner's PID if found. *)
let find_terminal_owner (session_pid : int) (pts_num : string) : int option =
  let rec walk (pid : int) (seen : int list) =
    if List.mem pid seen then None
    else
      (try
         if is_terminal_owner_for_pts pid pts_num then Some pid
         else
           let ppid =
             try
               let status_path = Printf.sprintf "/proc/%d/status" pid in
               let content = read_file status_path in
               let rec find_ppid lines =
                 match lines with
                 | [] -> None
                 | line :: rest ->
                     if String.length line >= 6
                        && String.sub line 0 6 = "PPid:\t"
                     then
                       (try Some (int_of_string (String.sub line 6 (String.length line - 6)))
                        with _ -> None)
                     else find_ppid rest
               in
               find_ppid (String.split_on_char '\n' content)
             with _ -> None
           in
           match ppid with
           | Some parent when parent > 0 -> walk parent (pid :: seen)
           | _ -> None
      with _ -> None)
  in
  walk session_pid []

(* --- inject target resolution (pure OCaml) --- *)

(** Result of resolving an injection target. *)
type inject_target = {
  terminal_pid : int;  (* 0 if not available (SSH session) *)
  pts_num : string;
  session_id : string option;
  cwd : string option;
  has_terminal_owner : bool;
}

(** Resolve an injection target from claude session identifier, PID, or explicit coords.
    For SSH sessions (no terminal owner), terminal_pid=0 but pts_num is still returned. *)
let resolve_inject_target
    (claude_session : string option)
    (pid : int option)
    (terminal_pid : int option)
    (pts : string option) : inject_target =
  match claude_session, pid, (terminal_pid, pts) with
  | Some session, None, (None, None) -> (
      (* Resolve by session identifier *)
      match find_session_by_identifier session with
      | None ->
          Printf.eprintf "error: session %S not found\n%!" session;
          exit 1
      | Some (session_id, cwd, proc_pid) ->
          let pts_num =
            match resolve_pts_from_pid proc_pid with
            | Some p -> p
            | None -> (
                (* Try with the session id directly as a PID hint *)
                match int_of_string_opt session with
                | Some p when p > 0 ->
                    (match resolve_pts_from_pid p with
                     | Some p -> p
                     | None -> "0")
                | _ -> "0"
              )
          in
          let tp, has_tp =
            match find_terminal_owner proc_pid pts_num with
            | Some t -> (t, true)
            | None -> (0, false)
          in
          { terminal_pid = tp; pts_num; session_id = Some session_id; cwd = Some cwd;
            has_terminal_owner = has_tp }
    )
  | None, Some p, (None, None) -> (
      (* Resolve by PID *)
      match resolve_pts_from_pid p with
      | None ->
          Printf.eprintf "error: pid %d has no /dev/pts on fds 0/1/2\n%!" p;
          exit 1
      | Some pts_num ->
          let tp, has_tp =
            match find_terminal_owner p pts_num with
            | Some t -> (t, true)
            | None -> (0, false)
          in
          { terminal_pid = tp; pts_num; session_id = None; cwd = None;
            has_terminal_owner = has_tp }
    )
  | _, _, (Some tp, Some pn) ->
      (* Explicit coordinates *)
      { terminal_pid = tp; pts_num = pn; session_id = None; cwd = None;
        has_terminal_owner = tp > 0 }
  | _ ->
      Printf.eprintf "error: must specify --claude-session, --pid, or --terminal-pid + --pts\n%!";
      exit 1

(* --- subcommand: inject claude -------------------------------------------- *)

(** Escape a string for XML attribute values. *)
let xml_escape (s : string) : string =
  let b = Buffer.create (String.length s * 2) in
  String.iter (fun c ->
    match c with
    | '&' -> Buffer.add_string b "&amp;"
    | '<' -> Buffer.add_string b "&lt;"
    | '>' -> Buffer.add_string b "&gt;"
    | '"' -> Buffer.add_string b "&quot;"
    | _ -> Buffer.add_char b c
  ) s;
  Buffer.contents b

(** Render a message payload as a <c2c> XML envelope. If [raw] is true,
    returns the message unchanged. *)
let render_payload (message : string) (event : string) (sender : string)
    (alias : string) (raw : bool) : string =
  if raw || String.length message > 0 && message.[0] = '<' then
    message
  else
    let attrs = Printf.sprintf "event=%S from=%S"
      event (xml_escape sender)
    in
    let attrs = if alias <> "" then attrs ^ Printf.sprintf " alias=%S" (xml_escape alias) else attrs in
    let attrs = attrs ^ " source=\"pty\" source_tool=\"c2c_inject\" action_after=\"continue\"" in
    Printf.sprintf "<c2c %s>\n%s\n</c2c>" attrs message

(** The submit delay for Kimi clients (in seconds). *)
let kimi_submit_delay = 1.5

(** Effective submit delay for a given client. Returns the explicit delay or
    the client-specific default. *)
let effective_submit_delay (client : string) (explicit_delay : float option) : float =
  match explicit_delay with
  | Some d -> d
  | None ->
      if client = "kimi" then kimi_submit_delay
      else 0.2

(** Inject command: one-shot message/keycode injection into a Claude/Codex session. *)
let inject_cmd =
  let claude_session =
    Cmdliner.Arg.(value & opt (some string) None &
      info [ "claude-session" ] ~docv:"NAME_OR_ID"
      ~doc:"Target Claude session by name, session ID, or PID.")
  in
  let pid =
    Cmdliner.Arg.(value & opt (some int) None &
      info [ "pid" ] ~docv:"PID"
      ~doc:"Target any process by PID.")
  in
  let terminal_pid =
    Cmdliner.Arg.(value & opt (some int) None &
      info [ "terminal-pid" ] ~docv:"PID"
      ~doc:"Terminal emulator PID (use with --pts).")
  in
  let pts =
    Cmdliner.Arg.(value & opt (some string) None &
      info [ "pts" ] ~docv:"N"
      ~doc:"PTY slave number (required with --terminal-pid).")
  in
  let client =
    Cmdliner.Arg.(value & opt (some string) None &
      info [ "client" ] ~docv:"CLIENT"
      ~doc:"Client label: claude, codex, opencode, kimi, generic (default: generic).")
  in
  let event =
    Cmdliner.Arg.(value & opt (some string) None &
      info [ "event" ] ~docv:"EVENT"
      ~doc:"Event tag (default: message).")
  in
  let sender =
    Cmdliner.Arg.(value & opt (some string) None &
      info [ "from" ] ~docv:"SENDER"
      ~doc:"Sender name (default: c2c-inject).")
  in
  let alias =
    Cmdliner.Arg.(value & opt (some string) None &
      info [ "alias" ] ~docv:"ALIAS"
      ~doc:"Sender alias.")
  in
  let raw =
    Cmdliner.Arg.(value & flag &
      info [ "raw" ]
      ~doc:"Do not wrap message in <c2c> XML envelope.")
  in
  let delay =
    Cmdliner.Arg.(value & opt (some float) None &
      info [ "delay" ] ~docv:"MS"
      ~doc:"Delay between parts in milliseconds (default: 500).")
  in
  let method_ =
    Cmdliner.Arg.(value & opt (some string) None &
      info [ "method" ] ~docv:"METHOD"
      ~doc:"Injection method: pty, history, auto (default: auto).")
  in
  let dry_run =
    Cmdliner.Arg.(value & flag &
      info [ "dry-run" ]
      ~doc:"Show what would be injected without sending.")
  in
  let json =
    Cmdliner.Arg.(value & flag &
      info [ "json" ]
      ~doc:"Output JSON result.")
  in
  let+ claude_session = claude_session
  and+ pid = pid
  and+ terminal_pid = terminal_pid
  and+ pts = pts
  and+ client = client
  and+ event = event
  and+ sender = sender
  and+ alias = alias
  and+ raw = raw
  and+ delay = delay
  and+ method_ = method_
  and+ dry_run = dry_run
  and+ json = json
  and+ msg_tokens = Cmdliner.Arg.(non_empty & pos_all string [] & info [] ~docv:"MESSAGE" ~doc:"Message text or keycode (:enter, :esc, :ctrlc, etc.)")
  in
  (* Parse tokens: keycodes (:enter etc.) and plain text *)
  let parts : (string * string) list =
    List.map (fun token ->
      if String.length token > 0 && token.[0] = ':' then
        (token, inject_keycode token)
      else
        (token, token)
    ) msg_tokens
  in
  let full_text = String.concat " " (List.map snd parts) in
  let event_str = Option.value event ~default:"message" in
  let sender_str = Option.value sender ~default:"c2c-inject" in
  let alias_str = Option.value alias ~default:"" in
  let client_str = Option.value client ~default:"generic" in
  let method_str = Option.value method_ ~default:"auto" in
  let delay_ms = Option.value delay ~default:500.0 in
  let delay_s = delay_ms /. 1000.0 in
  let submit_delay = effective_submit_delay client_str (Some delay_s) in
  let payload = render_payload full_text event_str sender_str alias_str raw in
  if dry_run then (
    let action = "would inject" in
    let method_desc = if method_str <> "auto" then Printf.sprintf " via %s" method_str else "" in
    let text_preview = if String.length full_text > 50 then String.sub full_text 0 50 ^ "..." else full_text in
    print_endline (Printf.sprintf "%s into %s%s: %s" action client_str method_desc text_preview);
    exit 0
  );
  (* Resolve target *)
  let target = resolve_inject_target claude_session pid terminal_pid pts in
  let method_used = ref None in
  (* Try PTY injection if method is pty or auto *)
  if !method_used = None && (method_str = "pty" || method_str = "auto") then
    if target.terminal_pid > 0 then (
      let ok = inject_via_pty target.terminal_pid target.pts_num payload ~submit_delay in
      if ok then method_used := Some "pty"
    );
  (* Try history injection if method is history or auto *)
  if !method_used = None && (method_str = "history" || method_str = "auto") then
    match target.session_id with
    | None ->
        Printf.eprintf "error: history injection requires --claude-session (session ID unknown for --pid/--terminal-pid)\n%!";
        exit 1
    | Some session_id ->
        match inject_via_history session_id target.cwd full_text with
        | None ->
            Printf.eprintf "error: history injection failed (transcript not found)\n%!";
            exit 1
        | Some _path ->
            method_used := Some "history"
  ;
  (match !method_used with
   | None ->
       Printf.eprintf "error: injection failed (tried pty and history)\n%!";
       exit 1
   | Some m ->
       if json then (
         let result = `Assoc [
           ("ok", `Bool true);
           ("client", `String client_str);
           ("method", `String m);
           ("terminal_pid", `Int target.terminal_pid);
           ("pts", `String target.pts_num);
           ("payload", `String (String.sub payload 0 (min (String.length payload) 200)));
           ("dry_run", `Bool false);
           ("submit_delay", `Float submit_delay);
         ] in
         print_endline (Yojson.Safe.pretty_to_string result)
       ) else (
         let text_preview = if String.length full_text > 50 then String.sub full_text 0 50 ^ "..." else full_text in
         print_endline (Printf.sprintf "injected into %s via %s: %s" client_str m text_preview)
       )
  );
  exit 0

let inject = Cmdliner.Cmd.v (Cmdliner.Cmd.info "inject" ~doc:"Inject messages or keycodes into a live session.") inject_cmd

(* --- subcommand group: wire-daemon ---------------------------------------- *)

let wire_daemon_start_cmd =
  let session_id =
    Cmdliner.Arg.(required & opt (some string) None & info ["session-id"] ~docv:"ID"
                    ~doc:"Session ID for the wire daemon (used as pidfile key).")
  in
  let alias =
    Cmdliner.Arg.(value & opt (some string) None & info ["alias"] ~docv:"ALIAS"
                    ~doc:"Alias to register (defaults to session-id).")
  in
  let command =
    Cmdliner.Arg.(value & opt string "kimi" & info ["command"] ~docv:"CMD"
                    ~doc:"kimi binary to invoke (default: kimi).")
  in
  let work_dir =
    Cmdliner.Arg.(value & opt string "." & info ["work-dir"] ~docv:"DIR"
                    ~doc:"Working directory for kimi --wire (default: .).")
  in
  let interval =
    Cmdliner.Arg.(value & opt float 5.0 & info ["interval"] ~docv:"SEC"
                    ~doc:"Seconds between inbox polls (default: 5.0).")
  in
  let+ json = json_flag
  and+ session_id = session_id
  and+ alias_opt = alias
  and+ command = command
  and+ work_dir = work_dir
  and+ interval = interval in
  let alias = Option.value alias_opt ~default:session_id in
  let broker_root = resolve_broker_root () in
  let (st, action) =
    C2c_wire_daemon.start_daemon
      ~session_id ~alias ~broker_root ~command ~work_dir ~interval
  in
  (match action with
   | `Already_running ->
       if json then
         print_json (`Assoc [ ("ok", `Bool true); ("already_running", `Bool true);
                               ("status", C2c_wire_daemon.status_to_json st) ])
       else
         Printf.printf "wire-daemon already running for %s (pid %s)\n"
           session_id (Option.fold ~none:"?" ~some:string_of_int st.pid)
   | `Started ->
       if json then
         print_json (`Assoc [ ("ok", `Bool true); ("started", `Bool true);
                               ("status", C2c_wire_daemon.status_to_json st) ])
       else begin
         if st.running then
           Printf.printf "wire-daemon started for %s (pid %s)\n"
             session_id (Option.fold ~none:"?" ~some:string_of_int st.pid)
         else
           Printf.printf "wire-daemon fork failed for %s\n" session_id
       end)

let wire_daemon_stop_cmd =
  let session_id =
    Cmdliner.Arg.(required & opt (some string) None & info ["session-id"] ~docv:"ID"
                    ~doc:"Session ID of the daemon to stop.")
  in
  let+ json = json_flag
  and+ session_id = session_id in
  let (st, action) = C2c_wire_daemon.stop_daemon session_id in
  (match action with
   | `Not_running ->
       if json then
         print_json (`Assoc [ ("ok", `Bool true); ("not_running", `Bool true) ])
       else
         Printf.printf "wire-daemon not running for %s\n" session_id
   | `Stopped ->
       if json then
         print_json (`Assoc [ ("ok", `Bool true); ("stopped", `Bool true);
                               ("status", C2c_wire_daemon.status_to_json st) ])
       else
         Printf.printf "wire-daemon stopped for %s\n" session_id)

let wire_daemon_status_cmd =
  let session_id =
    Cmdliner.Arg.(required & opt (some string) None & info ["session-id"] ~docv:"ID"
                    ~doc:"Session ID to query.")
  in
  let+ json = json_flag
  and+ session_id = session_id in
  let st = C2c_wire_daemon.get_status session_id in
  if json then
    print_json (C2c_wire_daemon.status_to_json st)
  else begin
    Printf.printf "session_id: %s\n" st.session_id;
    Printf.printf "running:    %s\n" (string_of_bool st.running);
    (match st.pid with
     | Some p -> Printf.printf "pid:        %d\n" p
     | None   -> Printf.printf "pid:        (none)\n");
    Printf.printf "pidfile:    %s\n" st.pidfile;
    (match st.logfile with
     | Some l -> Printf.printf "log:        %s\n" l
     | None   -> ())
  end

let wire_daemon_list_cmd =
  let+ json = json_flag in
  let daemons = C2c_wire_daemon.list_daemons () in
  if json then
    print_json (`List (List.map C2c_wire_daemon.status_to_json daemons))
  else begin
    if daemons = [] then
      Printf.printf "no wire daemons found\n"
    else
      List.iter (fun (st : C2c_wire_daemon.daemon_status) ->
          let pid_str = Option.fold ~none:"(none)" ~some:string_of_int st.pid in
          Printf.printf "%s  pid=%-8s  %s\n"
            st.session_id pid_str
            (if st.running then "running" else "stopped"))
        daemons
  end

let wire_daemon_format_prompt_cmd =
  let json_messages =
    Cmdliner.Arg.(required & opt (some string) None & info [ "json-messages" ] ~docv:"JSON"
      ~doc:"JSON array of {from_alias,to_alias,content} message objects.")
  in
  let+ json_messages = json_messages in
  let msgs_json = Yojson.Safe.from_string json_messages in
  let msgs = match msgs_json with
    | `List items -> List.filter_map (function
        | `Assoc _ as obj ->
            let get_str key = match List.assoc_opt key (match obj with `Assoc f -> f | _ -> []) with
              | Some (`String s) -> s | _ -> "" in
            Some C2c_mcp.{ from_alias = get_str "from_alias"
                          ; to_alias   = get_str "to_alias"
                          ; content    = get_str "content" }
        | _ -> None) items
    | _ -> []
  in
  print_string (C2c_wire_bridge.format_prompt msgs)

let wire_daemon_spool_write_cmd =
  let spool_path_arg =
    Cmdliner.Arg.(required & opt (some string) None & info [ "spool-path" ] ~docv:"PATH"
      ~doc:"Path to spool file.")
  in
  let json_messages =
    Cmdliner.Arg.(required & opt (some string) None & info [ "json-messages" ] ~docv:"JSON"
      ~doc:"JSON array of {from_alias,to_alias,content} message objects.")
  in
  let+ spool_path = spool_path_arg and+ json_messages = json_messages in
  let msgs_json = Yojson.Safe.from_string json_messages in
  let msgs = match msgs_json with
    | `List items -> List.filter_map (function
        | `Assoc _ as obj ->
            let get_str key = match List.assoc_opt key (match obj with `Assoc f -> f | _ -> []) with
              | Some (`String s) -> s | _ -> "" in
            Some C2c_mcp.{ from_alias = get_str "from_alias"
                          ; to_alias   = get_str "to_alias"
                          ; content    = get_str "content" }
        | _ -> None) items
    | _ -> []
  in
  let sp = C2c_wire_bridge.spool_of_path spool_path in
  C2c_wire_bridge.spool_write sp msgs

let wire_daemon_spool_read_cmd =
  let spool_path_arg =
    Cmdliner.Arg.(required & opt (some string) None & info [ "spool-path" ] ~docv:"PATH"
      ~doc:"Path to spool file.")
  in
  let+ spool_path = spool_path_arg in
  let sp = C2c_wire_bridge.spool_of_path spool_path in
  let msgs = C2c_wire_bridge.spool_read sp in
  let items = List.map (fun (m : C2c_mcp.message) ->
      `Assoc [ ("from_alias", `String m.from_alias)
             ; ("to_alias",   `String m.to_alias)
             ; ("content",    `String m.content) ]) msgs in
  print_json (`List items)

let wire_daemon_group =
  Cmdliner.Cmd.group
    (Cmdliner.Cmd.info "wire-daemon"
       ~doc:"Manage Kimi Wire bridge daemon lifecycle (start/stop/status/list).")
    [ Cmdliner.Cmd.v (Cmdliner.Cmd.info "start"  ~doc:"Start a wire-daemon for a session.") wire_daemon_start_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "stop"   ~doc:"Stop a running wire-daemon.") wire_daemon_stop_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "status" ~doc:"Show status of a wire-daemon.") wire_daemon_status_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "list"   ~doc:"List all wire-daemon state files.") wire_daemon_list_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "format-prompt" ~doc:"[diagnostic] Format broker messages as Wire prompt text.") wire_daemon_format_prompt_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "spool-write" ~doc:"[diagnostic] Write messages to a spool file.") wire_daemon_spool_write_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "spool-read"  ~doc:"[diagnostic] Read messages from a spool file as JSON.") wire_daemon_spool_read_cmd
    ]

(* --- subcommand group: repo ------------------------------------------------ *)

let repo_set_supervisor_cmd =
  let aliases_arg =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ALIAS[,ALIAS2,...]"
                    ~doc:"Supervisor alias or comma-separated list.")
  in
  let strategy_arg =
    Cmdliner.Arg.(value & opt (some string) None & info ["strategy"; "s"] ~docv:"STRATEGY"
                    ~doc:"Dispatch strategy: first-alive (default), round-robin, broadcast.")
  in
  let+ aliases_str = aliases_arg
  and+ strategy_opt = strategy_arg
  and+ json = json_flag in
  let aliases = List.filter (fun s -> s <> "") (String.split_on_char ',' aliases_str) in
  if aliases = [] then (
    Printf.eprintf "error: at least one alias required\n%!";
    exit 1
  );
  (match strategy_opt with
   | Some s when not (List.mem s valid_strategies) ->
       Printf.eprintf "error: unknown strategy '%s'. Use: %s\n%!" s (String.concat ", " valid_strategies);
       exit 1
   | _ -> ());
  let config = load_repo_config () in
  let fields = match config with `Assoc f -> f | _ -> [] in
  let supervisor_val = `List (List.map (fun a -> `String a) aliases) in
  let fields' = ref
    (("supervisors", supervisor_val)
     :: List.filter (fun (k, _) -> k <> "supervisors" && k <> "permission_supervisors" && k <> "supervisor_strategy") fields)
  in
  (match strategy_opt with
   | Some s -> fields' := ("supervisor_strategy", `String s) :: !fields'
   | None -> ());
  save_repo_config (`Assoc !fields');
  let output_mode = if json then Json else Human in
  let strategy_str = match strategy_opt with Some s -> s | None -> "first-alive (default)" in
  (match output_mode with
   | Json ->
       let out = [ ("ok", `Bool true); ("supervisors", supervisor_val); ("config", `String (repo_config_path ())) ] in
       let out = match strategy_opt with Some s -> ("supervisor_strategy", `String s) :: out | None -> out in
       print_json (`Assoc out)
   | Human ->
       Printf.printf "Supervisor set: %s\n" (String.concat ", " aliases);
       Printf.printf "Strategy:      %s\n" strategy_str;
       Printf.printf "Config:        %s\n" (repo_config_path ());
       Printf.printf "Override:      C2C_PERMISSION_SUPERVISOR=alias or C2C_SUPERVISORS=a,b\n")

let repo_show_cmd =
  let+ json = json_flag in
  let config = load_repo_config () in
  let output_mode = if json then Json else Human in
  (match output_mode with
   | Json -> print_json config
   | Human ->
       let path = repo_config_path () in
       if not (Sys.file_exists path) then (
         Printf.printf "No repo config (.c2c/repo.json) — using defaults.\n";
         Printf.printf "  Run: c2c repo set supervisor <alias> to configure.\n"
       ) else (
         Printf.printf "Repo config: %s\n" path;
         let fields = match config with `Assoc f -> f | _ -> [] in
         (match List.assoc_opt "supervisors" fields with
          | Some (`List aliases) ->
              let names = List.filter_map (function `String s -> Some s | _ -> None) aliases in
              Printf.printf "  supervisors: %s\n" (String.concat ", " names)
          | _ ->
              Printf.printf "  supervisors: (not set — default: coordinator1)\n");
         let shown = [ "supervisors"; "permission_supervisors" ] in
         List.iter (fun (k, v) ->
           if not (List.mem k shown) then
             let vstr = match v with `String s -> s | _ -> Yojson.Safe.to_string v in
             Printf.printf "  %s: %s\n" k vstr
         ) fields
       ))

let repo_group =
  Cmdliner.Cmd.group
    (Cmdliner.Cmd.info "repo"
       ~doc:"Per-repository c2c configuration (supervisors, defaults).")
    [ Cmdliner.Cmd.group
        (Cmdliner.Cmd.info "set" ~doc:"Set a per-repo config value.")
        [ Cmdliner.Cmd.v
            (Cmdliner.Cmd.info "supervisor"
               ~doc:"Set permission supervisor alias(es) for this repo."
               ~man:[ `S "DESCRIPTION"
                    ; `P "Sets the alias(es) that receive permission.ask notifications \
                          when OpenCode needs approval. Stored in .c2c/repo.json."
                    ; `S "EXAMPLES"
                    ; `P "$(b,c2c repo set supervisor coordinator1)"
                    ; `P "$(b,c2c repo set supervisor coordinator1,planner1)  — round-robin"
                    ])
            repo_set_supervisor_cmd
        ]
    ; Cmdliner.Cmd.v
        (Cmdliner.Cmd.info "show" ~doc:"Show current repo config.")
        repo_show_cmd
    ]

(* --- subcommand: screen ---------------------------------------------------- *)

(** Resolve a pts number from a Claude session identifier using pure OCaml.
    Returns (terminal_pid, pts_num). For SSH sessions where terminal_pid is empty, returns (0, pts_num).
    Uses session JSON files to find the PID, then reads /proc/<pid>/fd/0 for the current pts. *)
let resolve_claude_session (session : string) : (int * string) =
  match find_session_by_identifier session with
  | None ->
      Printf.eprintf "error: session %S not found\n%!" session;
      exit 1
  | Some (session_id, _cwd, proc_pid) ->
      let pts_num =
        match resolve_pts_from_pid proc_pid with
        | Some p -> p
        | None ->
            (* Session found but process has no pts — try using session_id directly as PID hint *)
            (match int_of_string_opt session with
             | Some p when p > 0 ->
                 (match resolve_pts_from_pid p with
                  | Some p -> p
                  | None -> "0")
             | _ -> "0")
      in
      let tp, has_tp =
        match find_terminal_owner proc_pid pts_num with
        | Some t -> (t, true)
        | None -> (0, false)
      in
      (if tp = 0 && has_tp then () else ());  (* suppress unused warning *)
      (tp, pts_num)

(** Resolve (terminal_pid, pts_num) from a raw process PID.
    We read the pts from /proc/<pid>/fd/{0,1,2} then optionally find the terminal owner
    by walking the parent chain and scanning fdinfos.
    Returns (0, pts_num) if terminal owner cannot be found (e.g., SSH sessions). *)
let resolve_pid_target (pid : int) : (int * string) =
  match resolve_pts_from_pid pid with
  | None ->
      Printf.eprintf "error: pid %d has no /dev/pts on fds 0/1/2\n%!" pid;
      exit 1
  | Some pts_num -> (
      match find_terminal_owner pid pts_num with
      | None ->
          (* Terminal owner not found (e.g., SSH session). Still return pts for screen reading. *)
          (0, pts_num)
      | Some tp -> (tp, pts_num)
    )

let screen_cmd =
  let claude_session =
    Cmdliner.Arg.(value & opt (some string) None & info [ "claude-session" ] ~docv:"NAME_OR_ID" ~doc:"Resolve target by Claude session name, session ID, or PID.")
  in
  let pid =
    Cmdliner.Arg.(value & opt (some int) None & info [ "pid" ] ~docv:"PID" ~doc:"Target any process by PID.")
  in
  let terminal_pid =
    Cmdliner.Arg.(value & opt (some int) None & info [ "terminal-pid" ] ~docv:"PID" ~doc:"Terminal emulator PID.")
  in
  let pts =
    Cmdliner.Arg.(value & opt (some string) None & info [ "pts" ] ~docv:"N" ~doc:"PTY slave number (required with --terminal-pid).")
  in
  let+ claude_session = claude_session
  and+ pid = pid
  and+ terminal_pid = terminal_pid
  and+ pts = pts in
  let (_ : int), pts_num =
    match claude_session, pid, (terminal_pid, pts) with
    | Some session, None, (None, None) ->
        (* Resolve via claude_list_sessions.py *)
        resolve_claude_session session
    | None, Some p, (None, None) ->
        (* Resolve via /proc walk *)
        resolve_pid_target p
    | _, _, (Some _tp, Some pn) ->
        (* Explicit coordinates — pts provided directly, terminal_pid not used *)
        (0, pn)
    | _ ->
        Printf.eprintf "error: must specify one of --claude-session, --pid, or --terminal-pid + --pts\n%!";
        exit 1
  in
  let pts_dev = Printf.sprintf "/dev/pts/%s" pts_num in
  if not (Sys.file_exists pts_dev) then (
    Printf.eprintf "error: %s does not exist\n%!" pts_dev;
    exit 1);
  (* Read from the PTY slave — for terminal emulators this gives scrollback buffer.
     For SSH sessions this may block, so we use dd with a short read limit. *)
  let ic = Unix.open_process_in (Printf.sprintf "timeout 1 dd if=%s bs=4096 count=256 2>/dev/null" pts_dev) in
  Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic)) (fun () ->
    let buf = Buffer.create 16384 in
    (try while true do
         let chunk = Bytes.create 4096 in
         let n = input ic chunk 0 4096 in
         if n > 0 then Buffer.add_subbytes buf chunk 0 n else raise End_of_file
       done with End_of_file -> ());
    let content = Buffer.contents buf in
    print_string content;
    if String.length content > 0 && content.[String.length content - 1] <> '\n' then print_newline ()
  )

let screen = Cmdliner.Cmd.v (Cmdliner.Cmd.info "screen" ~doc:"Capture PTY screen content as text.") screen_cmd

(* --- main entry point ----------------------------------------------------- *)

(* Cmdliner renders help through groff/grotty, which emits ANSI SGR escapes,
   then pipes through $MANPAGER (or $PAGER, or `less`). A MANPAGER that runs
   the output through `col -b*` (e.g. "sh -c 'col -bx | bat -l man -p'") strips
   the ESC byte from every SGR sequence but leaves the payload, producing
   visible garbage like "[4mNAME[0m" in the rendered help. Detect that case
   and swap in a safe pager so `c2c <cmd> --help` stays readable regardless
   of the user's shell setup. *)
let sanitize_help_env () =
  let contains_substr haystack needle =
    let nl = String.length needle and hl = String.length haystack in
    nl <= hl
    && (let rec loop i =
          i <= hl - nl
          && (String.sub haystack i nl = needle || loop (i + 1))
        in
        loop 0)
  in
  let esc_stripping v =
    (* `col -b` / `col -bx` drop control chars (including ESC) from input. *)
    contains_substr v "col -b" || contains_substr v "col\t-b"
  in
  let fix var =
    match Sys.getenv_opt var with
    | Some v when esc_stripping v -> Unix.putenv var "less -R"
    | _ -> ()
  in
  fix "MANPAGER";
  fix "PAGER"

(* Enriched landing for bare `c2c` (no subcommand). Shows detection status
   and suggested next commands — doubles as a "where am I?" report. *)
let print_enriched_landing () =
  let version = version_string () in
  let (self, clients) = detect_installation () in
  let self_path = self_installed_path () in
  let broker_root = try resolve_broker_root () with _ -> "(unresolved)" in
  Printf.printf "c2c %s — peer-to-peer messaging for AI agents\n" version;
  let format_binary_status path build_rel_path =
    match path with
    | None -> "not installed"
    | Some p ->
        let p_mtime = try Some (Unix.stat p).Unix.st_mtime with _ -> None in
        let build_path =
          match git_repo_toplevel () with
          | Some root -> Some (root // build_rel_path)
          | None -> None
        in
        let build_mtime =
          match build_path with
          | Some bp when Sys.file_exists bp ->
              (try Some (Unix.stat bp).Unix.st_mtime with _ -> None)
          | _ -> None
        in
        (match p_mtime, build_mtime with
         | Some pt, Some bt when bt > pt +. 1.0 ->
             let age_min = int_of_float ((bt -. pt) /. 60.0) in
             Printf.sprintf "%s  (STALE — newer build %dm ahead; `cp %s %s`)"
               p age_min (Option.value ~default:"?" build_path) p
         | _ -> p)
  in
  Printf.printf "\n";
  Printf.printf "Status\n";
  Printf.printf "  c2c on PATH:      %s\n"
    (format_binary_status self_path "_build/default/ocaml/cli/c2c.exe");
  let mcp_server_path = which_binary "c2c-mcp-server" in
  Printf.printf "  c2c-mcp-server:   %s\n"
    (format_binary_status mcp_server_path
       "_build/default/ocaml/server/c2c_mcp_server.exe");
  Printf.printf "  broker root:      %s\n" broker_root;
  let broker_live =
    try
      let broker = C2c_mcp.Broker.create ~root:broker_root in
      let regs = C2c_mcp.Broker.list_registrations broker in
      let alive =
        List.filter C2c_mcp.Broker.registration_is_alive regs |> List.length
      in
      Some (List.length regs, alive)
    with _ -> None
  in
  (match broker_live with
   | Some (total, alive) ->
       Printf.printf "  peers:            %d registered (%d alive)\n" total alive
   | None ->
       Printf.printf "  peers:            (broker not initialised — try `c2c init`)\n");
  (match check_pty_inject_capability () with
   | `Ok -> ()
   | `Unknown -> ()
   | `Missing_cap py ->
       Printf.printf
         "  pty-inject:       MISSING cap_sys_ptrace — kimi/codex/opencode PTY wake will fail\n";
       Printf.printf
         "                    fix: sudo setcap cap_sys_ptrace=ep %s\n" py);
  Printf.printf "\nClients\n";
  List.iter (fun (c, on_path, configured) ->
    let status =
      match on_path, configured with
      | false, _ -> "not on PATH"
      | true, true -> "configured"
      | true, false -> "on PATH, not configured"
    in
    Printf.printf "  %-10s %s\n" c status
  ) clients;
  let missing_clients =
    List.filter_map (fun (c, on_path, configured) ->
      if on_path && not configured then Some c else None) clients
  in
  let suggestions =
    let buf = Buffer.create 256 in
    if not self then
      Buffer.add_string buf (Printf.sprintf "  c2c install %-16s install the c2c binary to ~/.local/bin\n" "self");
    List.iter (fun c ->
      Buffer.add_string buf (Printf.sprintf "  c2c install %-16s configure %s for c2c\n" c c)
    ) missing_clients;
    Buffer.contents buf
  in
  if suggestions <> "" then begin
    Printf.printf "\nSuggested next steps\n";
    print_string suggestions;
    Printf.printf "  c2c install %-16s interactive installer (TUI)\n" ""
  end else begin
    Printf.printf "\nEverything looks configured. Some useful commands:\n";
    Printf.printf "  %-28s list registered peers\n" "c2c list";
    Printf.printf "  %-28s send a message\n" "c2c send ALIAS MSG";
    Printf.printf "  %-28s read pending messages\n" "c2c poll-inbox";
    Printf.printf "  %-28s list rooms you're in\n" "c2c rooms list"
  end;
  Printf.printf "\nRun `c2c help` or `c2c --help` for the full command list.\n"

let default_term =
  let+ () = Cmdliner.Term.const () in
  print_enriched_landing ()

let () =
  sanitize_help_env ();
  exit
    (Cmdliner.Cmd.eval
       (Cmdliner.Cmd.group ~default:default_term
          (Cmdliner.Cmd.info "c2c"
             ~version:(version_string ())
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
                    $(b,serve), $(b,mcp), $(b,start), $(b,stop), \
                    $(b,restart), $(b,instances), $(b,hook), $(b,inject), \
                    $(b,wire-daemon), $(b,screen), $(b,help)"
               ; `P "$(b,install) — install c2c + client integrations (TUI by default). \
                     Use $(b,c2c install self) for binary-only, \
                     $(b,c2c install claude|codex|opencode|kimi|crush) per-client, \
                     or $(b,c2c install all) for non-interactive full setup."
               ; `P "$(b,rooms) — manage N:N chat rooms"
               ; `P "$(b,relay) — cross-machine relay: serve, connect, setup, status, list, rooms, gc"
               ])
          [ send; list; whoami; poll_inbox; peek_inbox; send_all; sweep
          ; sweep_dryrun; history; health; setcap; status; verify; register; refresh_peer
          ; tail_log; my_rooms; dead_letter; prune_rooms; smoke_test; init; install
          ; serve; mcp; start; stop; restart; restart_self; instances; diag; rooms_group; room_group; relay_group; monitor; hook; inject; wire_daemon_group; repo_group; screen; help ]))
