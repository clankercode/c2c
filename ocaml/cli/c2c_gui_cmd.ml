(* c2c_gui_cmd - GUI launcher and headless batch-smoke subcommand.
   Extracted from c2c.ml as part of the architecture refactoring. *)

open C2c_cli_helpers
open Cmdliner.Term.Syntax
open C2c_mcp
open C2c_utils

let find_gui_binary () =
  (* 1. c2c-gui in PATH *)
  match Sys.getenv_opt "PATH" with
  | Some path_env ->
      let dirs = String.split_on_char ':' path_env in
      (match List.find_opt (fun d -> Sys.file_exists (d // "c2c-gui")) dirs with
      | Some d -> Some (d // "c2c-gui")
      | None ->
          (* 2. Relative to the c2c binary itself (e.g. ~/.local/bin/c2c -> ~/.local/bin/c2c-gui) *)
          let self = Sys.executable_name in
          let sibling = Filename.dirname self // "c2c-gui" in
          if Sys.file_exists sibling then Some sibling else None)
  | None -> None

type gui_batch_check = { name : string; ok : bool; detail : string }

let registration_to_json (r : C2c_mcp.registration) : Yojson.Safe.t =
  let base = [ ("session_id", `String r.session_id); ("alias", `String r.alias) ] in
  let with_pid = match r.pid with Some n -> base @ [("pid", `Int n)] | None -> base in
  let alive_val = match C2c_mcp.Broker.registration_liveness_state r with
    | C2c_mcp.Broker.Alive -> `Bool true
    | C2c_mcp.Broker.Dead -> `Bool false
    | C2c_mcp.Broker.Unknown -> `Null
  in
  let with_alive = with_pid @ [("alive", alive_val)] in
  let with_dnd = if r.dnd then with_alive @ [("dnd", `Bool true)] else with_alive in
  let with_tmux = match r.tmux_location with
    | Some loc -> with_dnd @ [("tmux_location", `String loc)]
    | None -> with_dnd
  in
  let with_cwd = match r.cwd with
    | Some c -> with_tmux @ [("cwd", `String c)]
    | None -> with_tmux
  in
  `Assoc with_cwd

let room_to_json (ri : C2c_mcp.Broker.room_info) : Yojson.Safe.t =
  `Assoc
    [ ("room_id", `String ri.C2c_mcp.Broker.ri_room_id)
    ; ("member_count", `Int ri.C2c_mcp.Broker.ri_member_count)
    ; ("alive_member_count", `Int ri.C2c_mcp.Broker.ri_alive_member_count)
    ; ("members", `List (List.map (fun (m : string) -> `String m) ri.C2c_mcp.Broker.ri_members))
    ]

(** [gui_batch ()] runs a headless smoke test of the c2c broker.
    Validates config loading, CLI/MCP availability, inbox polling,
    render-model build, peer discovery, room listing, and pending permissions.
    Outputs a full swarm snapshot JSON to stderr. Exits 0 on success,
    non-zero on failure. *)
let gui_batch () : unit =
  let broker_root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let checks : gui_batch_check list ref = ref [] in
  let add_check name ok detail =
    checks := { name; ok; detail } :: !checks
  in
  (* Snapshot data *)
  let peers_json : Yojson.Safe.t ref = ref (`List [])
  and rooms_json : Yojson.Safe.t ref = ref (`List [])
  and pending_perms_json : Yojson.Safe.t ref = ref (`List []) in

  (* Check 1: broker root exists and is readable *)
  (try
     let reg_path = Filename.concat broker_root "registry.json" in
     if Sys.file_exists reg_path then add_check "broker_root" true "registry.json found"
     else add_check "broker_root" false "registry.json not found"
   with e ->
     add_check "broker_root" false (Printexc.to_string e));
  (* Check 2: config loading - check .c2c/config.toml in cwd *)
  (try
     let cfg = Filename.concat (Sys.getcwd ()) ".c2c" // "config.toml" in
     if Sys.file_exists cfg then add_check "config_loading" true "config.toml found"
     else add_check "config_loading" false "config.toml not found"
   with e ->
     add_check "config_loading" false (Printexc.to_string e));
  (* Check 3: CLI availability - invoke c2c --version *)
  (try
     let self_bin = Sys.executable_name in
     let ic = Unix.open_process_args_in self_bin [| self_bin; "--version" |] in
     let buf = Bytes.create 256 in
     let rec drain acc =
       match input ic buf 0 256 with
       | 0 -> close_in ic; List.rev acc
       | n -> drain (Bytes.sub buf 0 n :: acc)
     in
     let _output = drain [] |> Bytes.concat (Bytes.create 0) |> Bytes.to_string in
     let status = Unix.close_process_in ic in
     match status with
     | Unix.WEXITED 0 -> add_check "cli_mcp_availability" true "CLI --version succeeded"
     | Unix.WEXITED n -> add_check "cli_mcp_availability" false ("CLI --version exited " ^ string_of_int n)
     | _ -> add_check "cli_mcp_availability" false "CLI --version killed or stopped"
   with e ->
     add_check "cli_mcp_availability" false (Printexc.to_string e));
  (* Check 4: inbox polling - non-destructive read via broker *)
  (try
     let session_id = match C2c_mcp.session_id_from_env () with
       | Some s -> s | None -> "batch-smoke-session" in
     let msgs = C2c_mcp.Broker.read_inbox broker ~session_id in
     add_check "inbox_polling" true (Printf.sprintf "read successfully (%d messages)" (List.length msgs))
   with e ->
     add_check "inbox_polling" false (Printexc.to_string e));
  (* Check 5: render-model build - check gui dist/ and src-tauri/target exist *)
  (try
     let git_dir = match Git_helpers.git_common_dir () with
       | Some d -> d | None -> raise (Failure "no git common dir") in
     let repo_root = Filename.dirname git_dir in
     let gui_dist = repo_root // "gui" // "dist" in
     let gui_tauri = repo_root // "gui" // "src-tauri" // "target" in
     if Sys.file_exists gui_dist || Sys.file_exists gui_tauri
     then add_check "render_model" true "gui assets found"
     else add_check "render_model" false "gui dist/ or src-tauri/target/ not found"
   with e ->
     add_check "render_model" false (Printexc.to_string e));
  (* Check 6: peer discovery - collect peer records *)
  (try
     let regs = C2c_mcp.Broker.list_registrations broker in
     let alive = List.filter (fun r -> C2c_mcp.Broker.registration_liveness_state r = C2c_mcp.Broker.Alive) regs in
     peers_json := `List (List.map registration_to_json regs);
     add_check "peer_discovery" true
       (Printf.sprintf "%d total, %d alive" (List.length regs) (List.length alive))
   with e ->
     add_check "peer_discovery" false (Printexc.to_string e));
  (* Check 7: room list - collect room records *)
  (try
     let rooms = C2c_mcp.Broker.list_rooms broker in
     rooms_json := `List (List.map room_to_json rooms);
     add_check "room_list" true
       (Printf.sprintf "%d rooms" (List.length rooms))
   with e ->
     add_check "room_list" false (Printexc.to_string e));
  (* Check 8: pending permissions - read pending_permissions.json directly *)
  (try
     let path = Filename.concat broker_root "pending_permissions.json" in
     if not (Sys.file_exists path) then begin
       pending_perms_json := `List [];
       add_check "pending_permissions" true "no pending_permissions.json (none active)"
     end else begin
       let json = Yojson.Safe.from_file path in
       let open Yojson.Safe.Util in
       match json with
       | `List items ->
           let now = Unix.gettimeofday () in
           let active =
             List.filter_map
               (fun item ->
                 match item with
                 | `Assoc _ ->
                     (match member "expires_at" item with
                      | `Float f when f > now ->
                          Some (`Assoc
                            [ ("perm_id", member "perm_id" item)
                            ; ("kind", member "kind" item)
                            ; ("requester_alias", member "requester_alias" item)
                            ; ("supervisors", member "supervisors" item)
                            ; ("expires_at", member "expires_at" item)
                            ])
                      | _ -> None)
                 | _ -> None)
               items
           in
           pending_perms_json := `List active;
           add_check "pending_permissions" true
             (Printf.sprintf "%d active pending" (List.length active))
       | _ ->
           pending_perms_json := `List [];
           add_check "pending_permissions" true "pending_permissions.json empty"
     end
   with e ->
     pending_perms_json := `List [];
     add_check "pending_permissions" false (Printexc.to_string e));
  (* Assemble JSON output matching DRAFT-gui-requirements lines 160-162:
     snapshot of current swarm state: peers, rooms, and pending permissions *)
  let all_ok = List.for_all (fun c -> c.ok) !checks in
  let json =
    `Assoc
      [ ("ok", `Bool all_ok)
      ; ("ts", `Float (Unix.gettimeofday ()))
      ; ("snapshot",
          `Assoc
            [ ("peers", !peers_json)
            ; ("rooms", !rooms_json)
            ; ("pending_permissions", !pending_perms_json)
            ])
      ; ("checks", `List (List.map (fun c ->
          `Assoc
            [ ("name", `String c.name)
            ; ("ok", `Bool c.ok)
            ; ("detail", `String c.detail)
            ]) !checks))
      ]
  in
  output_string stderr (Yojson.Safe.to_string json ^ "\n");
  flush stderr;
  exit (if all_ok then 0 else 1)

let gui_cmd : unit Cmdliner.Term.t =
  let detach =
    Cmdliner.Arg.(value & flag & info [ "detach"; "d" ] ~doc:"Detach from terminal (run in background).")
  in
  let batch =
    Cmdliner.Arg.(value & flag & info [ "batch"; "b" ]
      ~doc:"Headless smoke test: verify broker, peers, and rooms. Outputs JSON to stderr and exits.")
  in
  let+ detach = detach
  and+ batch = batch in
  if batch then gui_batch ()
  else
    match find_gui_binary () with
    | None ->
        Printf.eprintf "c2c gui: c2c-gui binary not found.\n";
        Printf.eprintf "  Build it with: cd gui && cargo tauri build\n";
        Printf.eprintf "  Or install the .deb/.rpm from gui/src-tauri/target/release/bundle/\n";
        exit 1
    | Some bin ->
        if detach then begin
          (match Unix.fork () with
          | 0 ->
              Unix.setsid () |> ignore;
              Unix.execv bin [| bin |]
          | _ -> exit 0)
        end else begin
          let pid = Unix.create_process bin [| bin |] Unix.stdin Unix.stdout Unix.stderr in
          let _, status = Unix.waitpid [] pid in
          exit (match status with
            | Unix.WEXITED code -> code
            | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 1)
        end

let gui : unit Cmdliner.Cmd.t = Cmdliner.Cmd.v
  (Cmdliner.Cmd.info "gui"
     ~doc:"Launch the c2c desktop GUI, or run a headless smoke test."
     ~man:[ `S "DESCRIPTION"
          ; `P "With no flags, launches the c2c-gui Tauri desktop application. \
                Searches for the c2c-gui binary in PATH and alongside the c2c binary. \
                Use $(b,--detach) to run it in the background."
          ; `P "$(b,c2c gui --batch) runs a headless smoke test that verifies the \
                broker is reachable and exercises peer discovery and room listing. \
                Outputs a JSON snapshot to stderr and exits 0 on success, non-zero on failure. \
                Suitable for CI and operator inspection without a display."
          ])
  gui_cmd
