(* c2c_start — OCaml port of the managed-instance lifecycle. *)

let ( // ) = Filename.concat

(* ---------------------------------------------------------------------------
 * Client configurations
 * --------------------------------------------------------------------------- *)

type client_config = {
  binary : string;
  deliver_client : string;
  needs_poker : bool;
  poker_event : string option;
  poker_from : string option;
  extra_env : (string * string) list;
}

let clients : (string, client_config) Stdlib.Hashtbl.t = Stdlib.Hashtbl.create 5

let () =
  Stdlib.Hashtbl.add clients "claude"
    { binary = "claude"; deliver_client = "claude"; needs_poker = true;
      poker_event = Some "heartbeat"; poker_from = Some "claude-poker";
      extra_env = [] };
  Stdlib.Hashtbl.add clients "codex"
    { binary = "codex"; deliver_client = "codex"; needs_poker = false;
      poker_event = None; poker_from = None; extra_env = [] };
  Stdlib.Hashtbl.add clients "opencode"
    { binary = "opencode"; deliver_client = "opencode"; needs_poker = false;
      poker_event = None; poker_from = None; extra_env = [] };
  Stdlib.Hashtbl.add clients "kimi"
    { binary = "kimi"; deliver_client = "kimi"; needs_poker = true;
      poker_event = Some "heartbeat"; poker_from = Some "kimi-poker";
      extra_env = [] };
  Stdlib.Hashtbl.add clients "crush"
    { binary = "crush"; deliver_client = "crush"; needs_poker = false;
      poker_event = None; poker_from = None; extra_env = [] }

let supported_clients = Stdlib.Hashtbl.fold (fun k _ acc -> k :: acc) clients []

(* ---------------------------------------------------------------------------
 * Paths
 * --------------------------------------------------------------------------- *)

let home_dir () =
  try Sys.getenv "HOME" with Not_found -> "/home/" ^ Sys.getenv "USER"

let instances_dir = Filename.concat (home_dir ()) ".local" // "share" // "c2c" // "instances"

let instance_dir name = instances_dir // name
let config_path name = instance_dir name // "config.json"
let outer_pid_path name = instance_dir name // "outer.pid"
let deliver_pid_path name = instance_dir name // "deliver.pid"
let poker_pid_path name = instance_dir name // "poker.pid"

let default_name client =
  let hostname =
    try
      let ic = Unix.open_process_in "hostname" in
      Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic))
        (fun () -> input_line ic)
    with _ -> "localhost"
  in
  let hostname =
    try String.map (fun c -> if c = '.' then '-' else c) hostname
    with _ -> hostname
  in
  Printf.sprintf "%s-%s" client hostname

(* ---------------------------------------------------------------------------
 * Broker root
 * --------------------------------------------------------------------------- *)

let git_common_dir () =
  try
    let ic = Unix.open_process_in "git rev-parse --git-common-dir 2>/dev/null" in
    Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic))
      (fun () -> String.trim (input_line ic))
  with _ -> ""

let resolve_broker_root () =
  match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
  | Some dir when String.trim dir <> "" -> String.trim dir
  | _ ->
      let git_dir = git_common_dir () in
      if git_dir <> "" && Sys.is_directory git_dir then
        let abs_git =
          if Filename.is_relative git_dir then Sys.getcwd () // git_dir
          else git_dir
        in
        abs_git // "c2c" // "mcp"
      else instances_dir // ".." // ".." // ".." // "c2c" // "mcp"

let broker_root () = resolve_broker_root ()

(* ---------------------------------------------------------------------------
 * Instance config persistence
 * --------------------------------------------------------------------------- *)

type instance_config = {
  name : string;
  client : string;
  session_id : string;
  resume_session_id : string;
  alias : string;
  extra_args : string list;
  created_at : float;
  broker_root : string;
  auto_join_rooms : string;
  binary_override : string option;
}

let write_config (cfg : instance_config) =
  let dir = instance_dir cfg.name in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let path = config_path cfg.name in
  let fields =
    [ ("name", `String cfg.name)
    ; ("client", `String cfg.client)
    ; ("session_id", `String cfg.session_id)
    ; ("resume_session_id", `String cfg.resume_session_id)
    ; ("alias", `String cfg.alias)
    ; ("extra_args", `List (List.map (fun s -> `String s) cfg.extra_args))
    ; ("created_at", `Float cfg.created_at)
    ; ("broker_root", `String cfg.broker_root)
    ; ("auto_join_rooms", `String cfg.auto_join_rooms) ]
    @
    (match cfg.binary_override with
     | Some b -> [ ("binary_override", `String b) ]
     | None -> [])
  in
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () ->
      Yojson.Safe.pretty_to_channel oc (`Assoc fields);
      output_string oc "\n")

let load_config_opt (name : string) : instance_config option =
  let path = config_path name in
  if not (Sys.file_exists path) then None
  else
    try
      let json = Yojson.Safe.from_file path in
      let a = match json with `Assoc a -> a | _ -> raise Not_found in
      let gs k = match List.assoc_opt k a with Some (`String s) -> s | _ -> raise Not_found in
      let gso k = match List.assoc_opt k a with Some (`String s) -> Some s | _ -> None in
      let gf k = match List.assoc_opt k a with Some (`Float f) -> f | Some (`Int i) -> float_of_int i | _ -> raise Not_found in
      let gl k = match List.assoc_opt k a with Some (`List l) -> List.map (function `String s -> s | _ -> raise Not_found) l | _ -> [] in
      Some { name = gs "name"; client = gs "client"; session_id = gs "session_id";
             resume_session_id = gs "resume_session_id"; alias = gs "alias";
             extra_args = gl "extra_args"; created_at = gf "created_at";
             broker_root = gs "broker_root"; auto_join_rooms = gs "auto_join_rooms";
             binary_override = gso "binary_override" }
    with _ -> None

let load_config (name : string) : instance_config =
  match load_config_opt name with
  | Some cfg -> cfg
  | None ->
      Printf.eprintf "error: config not found for instance '%s'\n%!" name;
      exit 1

(* ---------------------------------------------------------------------------
 * Process utilities
 * --------------------------------------------------------------------------- *)

let pid_alive (pid : int) : bool =
  try Unix.kill pid 0; true with Unix.Unix_error _ -> false

let read_pid (path : string) : int option =
  try
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in ic)
      (fun () -> int_of_string_opt (String.trim (input_line ic)))
  with _ -> None

let write_pid (path : string) (pid : int) =
  let dir = Filename.dirname path in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc (Printf.sprintf "%d\n" pid))

let remove_pidfile (path : string) =
  try Sys.remove path with Unix.Unix_error _ -> ()

(* ---------------------------------------------------------------------------
 * Cleanup stale OpenUI Zig cache
 * --------------------------------------------------------------------------- *)

let cleanup_stale_opentui_zig_cache () : int =
  let tmp_dir = "/tmp" in
  let min_age = 300.0 in
  let now = Unix.gettimeofday () in
  let deleted = ref 0 in
  (try
     let entries = Sys.readdir tmp_dir in
     Array.iter
       (fun entry ->
         if String.length entry > 5
            && String.sub entry 0 4 = ".fea"
            && Filename.check_suffix entry ".so" then
           let path = tmp_dir // entry in
           (try
              let st = Unix.stat path in
              if now -. st.st_mtime >= min_age then (
                (try Sys.remove path with _ -> ());
                incr deleted
              )
            with _ -> ()))
       entries
   with _ -> ());
  !deleted

(* ---------------------------------------------------------------------------
 * Build environment
 * --------------------------------------------------------------------------- *)

let build_env (name : string) (alias_override : string option) : string array =
  let env = Array.copy (Unix.environment ()) in
  let additions = [
    "C2C_MCP_SESSION_ID", name;
    "C2C_MCP_AUTO_REGISTER_ALIAS", Option.value alias_override ~default:name;
    "C2C_MCP_BROKER_ROOT", broker_root ();
    "C2C_MCP_AUTO_JOIN_ROOMS", "swarm-lounge";
    "C2C_MCP_AUTO_DRAIN_CHANNEL", "0";
  ] in
  let merged =
    let existing = Array.to_list env in
    let updated =
      List.fold_left
        (fun acc (k, v) ->
          let rec update = function
            | [] -> [ (k, Printf.sprintf "%s=%s" k v) ]
            | (k', v') :: _ when k' = k -> (k, Printf.sprintf "%s=%s" k v) :: acc
            | h :: tl -> h :: update tl
          in
          update acc)
        (List.map (fun e -> try let i = String.index e '=' in (String.sub e 0 i, e) with _ -> (e, e)) existing)
        additions
    in
    Array.of_list (List.rev_map snd updated)
  in
  merged

(* ---------------------------------------------------------------------------
 * Kimi MCP config generation
 * --------------------------------------------------------------------------- *)

let kimi_mcp_config_path (name : string) : string =
  instance_dir name // "kimi-mcp.json"

let has_explicit_kimi_mcp_config (extra_args : string list) : bool =
  List.exists
    (fun arg ->
      List.mem arg [ "--mcp-config-file"; "--mcp-config" ]
      || (String.length arg > 14 && String.sub arg 0 14 = "--mcp-config=")
      || (String.length arg > 20 && String.sub arg 0 20 = "--mcp-config-file="))
    extra_args

let repo_toplevel () : string =
  try
    let ic = Unix.open_process_in "git rev-parse --show-toplevel 2>/dev/null" in
    Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic))
      (fun () -> String.trim (input_line ic))
  with _ -> ""

let build_kimi_mcp_config (name : string) (br : string) (alias_override : string option) : Yojson.Safe.t =
  let alias = Option.value alias_override ~default:name in
  let script_path =
    match repo_toplevel () with
    | "" -> "c2c_mcp.py"
    | dir -> dir // "c2c_mcp.py"
  in
  `Assoc [ "mcpServers",
    `Assoc [ "c2c",
      `Assoc [ "type", `String "stdio";
               "command", `String "python3";
               "args", `List [ `String script_path ];
               "env", `Assoc [
                 "C2C_MCP_BROKER_ROOT", `String br;
                 "C2C_MCP_SESSION_ID", `String name;
                 "C2C_MCP_AUTO_REGISTER_ALIAS", `String alias;
                 "C2C_MCP_AUTO_JOIN_ROOMS", `String "swarm-lounge";
                 "C2C_MCP_AUTO_DRAIN_CHANNEL", `String "0";
               ] ] ] ]

(* ---------------------------------------------------------------------------
 * Launch argument preparation
 * --------------------------------------------------------------------------- *)

let prepare_launch_args ~(name : string) ~(client : string)
    ~(extra_args : string list) ~(broker_root : string)
    ?(alias_override : string option) ?(resume_session_id : string option)
    ?(binary_override : string option) () : string list =
  let args =
    match client with
    | "claude" ->
        (match resume_session_id with
         | Some sid when binary_override = None -> [ "--session-id"; sid; "--resume"; sid ]
         | Some sid -> [ "--session-id"; sid; "--fork-session" ]
         | None -> [])
    | "opencode" ->
        (match resume_session_id with Some sid -> [ "--session"; sid ] | None -> [])
    | "codex" ->
        (match resume_session_id with Some _ -> [ "resume"; "--last" ] | None -> [])
    | _ -> []
  in
  if client = "kimi" && not (has_explicit_kimi_mcp_config extra_args) then
    let cfg_path = kimi_mcp_config_path name in
    let dir = Filename.dirname cfg_path in
    (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    let oc = open_out cfg_path in
    Fun.protect ~finally:(fun () -> close_out oc)
      (fun () ->
        Yojson.Safe.pretty_to_channel oc (build_kimi_mcp_config name broker_root alias_override);
        output_string oc "\n");
    "--mcp-config-file" :: cfg_path :: (args @ extra_args)
  else
    args @ extra_args

(* ---------------------------------------------------------------------------
 * Binary lookup
 * --------------------------------------------------------------------------- *)

let find_binary (name : string) : string option =
  let path = try Sys.getenv "PATH" with Not_found -> "" in
  let rec search dirs =
    match dirs with
    | [] -> None
    | dir :: rest ->
        let full = dir // name in
        if Sys.file_exists full then
          (try Unix.access full [ Unix.X_OK ]; Some full with _ -> search rest)
        else search rest
  in
  search (String.split_on_char ':' path)

(* ---------------------------------------------------------------------------
 * Sidecar script paths
 * --------------------------------------------------------------------------- *)

let deliver_script_path () : string option =
  match repo_toplevel () with
  | "" -> None
  | dir ->
      let p = dir // "c2c_deliver_inbox.py" in
      if Sys.file_exists p then Some p else None

let poker_script_path () : string option =
  match repo_toplevel () with
  | "" -> None
  | dir ->
      let p = dir // "c2c_poker.py" in
      if Sys.file_exists p then Some p else None

(* ---------------------------------------------------------------------------
 * Sidecar daemon spawning
 * --------------------------------------------------------------------------- *)

let start_deliver_daemon ~(name : string) ~(client : string)
    ~(broker_root : string) ?(child_pid_opt : int option) () : int option =
  match deliver_script_path () with
  | None -> None
  | Some script ->
      let args =
        [ "python3"; script; "--client"; client; "--session-id"; name;
          "--notify-only"; "--loop"; "--broker-root"; broker_root ]
        @ (match child_pid_opt with None -> [] | Some p -> [ "--pid"; string_of_int p ])
      in
      try
        let pid = Unix.create_process_env "python3" (Array.of_list args)
            (Unix.environment ()) Unix.stdin Unix.stdout Unix.stderr
        in
        ignore pid;
        Some pid
      with Unix.Unix_error _ -> None

let start_poker ~(name : string) ~(client : string)
    ?(child_pid_opt : int option) () : int option =
  match poker_script_path () with
  | None -> None
  | Some script ->
      let cfg = try Some (Stdlib.Hashtbl.find clients client) with Not_found -> None in
      (match cfg with
       | None | Some { needs_poker = false; _ } -> None
       | Some cfg ->
           let args =
             (match child_pid_opt with
              | None -> [ "python3"; script; "--claude-session"; name; "--interval"; "600" ]
              | Some p -> [ "python3"; script; "--pid"; string_of_int p; "--interval"; "600" ])
             @ (match cfg.poker_event with None -> [] | Some e -> [ "--event"; e ])
           in
           try
             let pid = Unix.create_process_env "python3" (Array.of_list args)
                 (Unix.environment ()) Unix.stdin Unix.stdout Unix.stderr
             in
             ignore pid;
             Some pid
           with Unix.Unix_error _ -> None)

(* ---------------------------------------------------------------------------
 * Outer loop
 * --------------------------------------------------------------------------- *)

let run_outer_loop ~(name : string) ~(client : string)
    ~(extra_args : string list) ~(broker_root : string)
    ?(binary_override : string option) ?(alias_override : string option)
    ?(resume_session_id : string option) () : int =
  let cfg =
    try Stdlib.Hashtbl.find clients client
    with Not_found ->
      Printf.eprintf "error: unknown client '%s'\n%!" client; exit 1
  in
  let binary = Option.value binary_override ~default:cfg.binary in
  match find_binary binary with
  | None ->
      Printf.eprintf "error: '%s' not found in PATH. Install %s first.\n%!" binary client;
      exit 2
  | Some binary_path ->
      (* Auto-reap children *)
      (try ignore (Sys.signal Sys.sigchld Sys.Signal_ignore) with _ -> ());

      let inst_dir = instance_dir name in
      (try Unix.mkdir inst_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      write_pid (outer_pid_path name) (Unix.getpid ());

      let deliver_pid = ref None in
      let poker_pid = ref None in

      let stop_sidecar pid_opt =
        match pid_opt with
        | None -> ()
        | Some p ->
            (try Unix.kill p Sys.sigterm with Unix.Unix_error _ -> ());
            for _ = 1 to 30 do
              if not (pid_alive p) then () else Unix.sleepf 0.1
            done;
            (try Unix.kill p Sys.sigkill with Unix.Unix_error _ -> ())
      in

      let cleanup_and_exit code =
        stop_sidecar !deliver_pid;
        stop_sidecar !poker_pid;
        remove_pidfile (outer_pid_path name);
        remove_pidfile (deliver_pid_path name);
        remove_pidfile (poker_pid_path name);
        code
      in

      (* Cleanup stale zig cache *)
      (try
         let n = cleanup_stale_opentui_zig_cache () in
         if n > 0 then Printf.printf "[c2c-start/%s] cleaned %d stale /tmp/.fea*.so file(s)\n" name n
       with _ -> ());

      Printf.printf "[c2c-start/%s] iter 1: launching %s\n%!" name client;

      let start_time = Unix.gettimeofday () in

      (* Build env *)
      let env = build_env name alias_override in
      let env =
        Array.append env
          (Array.of_list
             (List.map (fun (k, v) -> Printf.sprintf "%s=%s" k v) cfg.extra_env))
      in
      let env = Array.append env [| Printf.sprintf "C2C_MCP_CLIENT_PID=%d" (Unix.getpid ()) |] in

      (* Launch args *)
      let launch_args =
        prepare_launch_args ~name ~client ~extra_args ~broker_root
          ?alias_override ?resume_session_id ?binary_override ()
      in
      let cmd = binary_path :: launch_args in

      (* Save TTY attrs *)
      let old_tty =
        (try if Unix.isatty Unix.stdin then Some (Unix.tcgetattr Unix.stdin) else None
         with _ -> None)
      in

      let child_pid_opt =
        try
          let pid = Unix.create_process_env binary_path (Array.of_list cmd) env
              Unix.stdin Unix.stdout Unix.stderr
          in
          (* Start deliver daemon *)
          (if !deliver_pid = None then
             match start_deliver_daemon ~name ~client ~broker_root ?child_pid_opt:(Some pid) () with
             | Some p -> deliver_pid := Some p; write_pid (deliver_pid_path name) p
             | None -> ());
          (* Start poker *)
          (if !poker_pid = None && cfg.needs_poker then
             match start_poker ~name ~client ?child_pid_opt:(Some pid) () with
             | Some p -> poker_pid := Some p; write_pid (poker_pid_path name) p
             | None -> ());
          pid
        with Unix.Unix_error (Unix.EINTR, _, _) -> 0
      in

      let exit_code =
        if child_pid_opt = 0 then 130
        else
          (try
             let rec wait_for_child () =
               match Unix.waitpid [ Unix.WUNTRACED ] child_pid_opt with
               | _, Unix.WSIGNALED n -> 128 + n
               | _, Unix.WSTOPPED n -> 128 + n
               | _, Unix.WEXITED n -> n
               | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_for_child ()
             in
             wait_for_child ()
           with _ -> 1)
      in

      (* Restore TTY *)
      (match old_tty with
       | Some t -> (try Unix.tcsetattr Unix.stdin Unix.TCSANOW t with _ -> ())
       | None -> ());

      let elapsed = Unix.gettimeofday () -. start_time in
      Printf.printf "[c2c-start/%s] inner exited code=%d after %.1fs\n%!" name exit_code elapsed;

      let resume_cmd =
        Printf.sprintf "c2c start %s -n %s" client name
        ^ (match binary_override with None -> "" | Some b -> Printf.sprintf " --bin %s" b)
      in
      print_endline ("\n  " ^ resume_cmd);
      cleanup_and_exit exit_code

(* ---------------------------------------------------------------------------
 * Commands
 * --------------------------------------------------------------------------- *)

let cmd_start ~(client : string) ~(name : string) ~(extra_args : string list)
    ?(binary_override : string option) ?(alias_override : string option)
    ?(session_id_override : string option) () : int =
  if not (Stdlib.Hashtbl.mem clients client) then
    (Printf.eprintf "error: unknown client: '%s'. Choose from: %s\n%!"
       client (String.concat ", " (List.sort String.compare supported_clients));
     exit 1);

  (* Validate --session-id *)
  (match session_id_override with
   | None -> ()
   | Some sid ->
       (try ignore (Uuidm.of_string sid) with _ ->
         Printf.eprintf "error: --session-id must be a valid UUID, e.g. 550e8400-e29b-41d4-a716-446655440000\n%!";
         exit 1));

  (* Check duplicate running *)
  (match read_pid (outer_pid_path name) with
   | Some pid when pid_alive pid ->
       Printf.eprintf "error: instance '%s' is already running (pid %d). Use 'c2c stop %s' first.\n%!"
         name pid name;
       exit 1
   | _ -> ());

  remove_pidfile (outer_pid_path name);

  (* Resume: inherit saved settings *)
  let existing = load_config_opt name in
  let (binary_override, alias_override, extra_args, resume_session_id, broker_root) =
    match existing with
    | Some ex ->
        if ex.client <> client then
          (Printf.eprintf
             "error: instance '%s' was previously a %s instance. Cannot resume as %s. Use 'c2c stop %s' first.\n%!"
             name ex.client client name;
           exit 1);
        let bo = if binary_override = None then ex.binary_override else binary_override in
        let ao = if alias_override = None then Some ex.alias else alias_override in
        let ea = if extra_args = [] then ex.extra_args else extra_args in
        let rs_from_existing = match binary_override with
          | Some _ -> None
          | None -> Some ex.resume_session_id
        in
        let rs = if session_id_override = None then rs_from_existing else session_id_override in
        (bo, ao, ea, rs, ex.broker_root)
    | None ->
        let rs =
          match session_id_override with
          | Some s -> s
          | None -> Uuidm.to_string (Uuidm.v `V4)
        in
        (binary_override, alias_override, extra_args, Some rs, broker_root ())
  in

  let cfg : instance_config = {
    name; client; session_id = name;
    resume_session_id = Option.value resume_session_id ~default:name;
    alias = Option.value alias_override ~default:name;
    extra_args;
    created_at = (match existing with Some ex -> ex.created_at | None -> Unix.gettimeofday ());
    broker_root;
    auto_join_rooms = "swarm-lounge";
    binary_override;
  }
  in
  write_config cfg;

  run_outer_loop ~name ~client ~extra_args ~broker_root
    ?binary_override ?alias_override ?resume_session_id ()

let cmd_stop (name : string) : int =
  match read_pid (outer_pid_path name) with
  | Some pid when pid_alive pid ->
      (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ());
      let deadline = Unix.gettimeofday () +. 10.0 in
        while Unix.gettimeofday () < deadline && pid_alive pid do
          Unix.sleepf 0.1
        done;
      if pid_alive pid then
        (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
      0
  | _ ->
      Printf.eprintf "error: instance '%s' is not running.\n%!" name;
      1

let cmd_restart (name : string) : int =
  match load_config_opt name with
  | None ->
      Printf.eprintf "error: no config found for instance '%s'\n%!" name;
      exit 1
  | Some cfg ->
      ignore (cmd_stop name);
      run_outer_loop ~name ~client:cfg.client ~extra_args:cfg.extra_args
        ~broker_root:cfg.broker_root
        ?binary_override:cfg.binary_override
        ?alias_override:(Some cfg.alias)
        ?resume_session_id:(Some cfg.resume_session_id) ()

let cmd_instances () : int =
  if not (Sys.file_exists instances_dir) then
    (Printf.printf "No c2c instances found.\n"; 0)
  else
    let entries =
      try Array.to_list (Sys.readdir instances_dir) with _ -> []
    in
    let instances =
      List.filter_map
        (fun name ->
          let full = instances_dir // name in
          if Sys.is_directory full && Sys.file_exists (full // "config.json")
          then Some name else None)
        entries
    in
    if instances = [] then
      (Printf.printf "No c2c instances found.\n"; 0)
    else
      let sorted = List.sort String.compare instances in
      Printf.printf "%-20s %-10s %-8s %-12s %s\n" "NAME" "CLIENT" "STATUS" "UPTIME" "PID";
      Printf.printf "%s\n" (String.make 65 '-');
      List.iter
        (fun name ->
          let cfg_opt = load_config_opt name in
          let client = match cfg_opt with Some c -> c.client | None -> "?" in
          let outer_pid = read_pid (outer_pid_path name) in
          let alive = match outer_pid with Some p -> pid_alive p | None -> false in
          let status = if alive then "ALIVE" else "DEAD" in
          let uptime =
            if alive then
              (try
                 let pid = Option.value outer_pid ~default:0 in
                 let stat_ic = open_in (Printf.sprintf "/proc/%d/stat" pid) in
                 Fun.protect ~finally:(fun () -> close_in stat_ic)
                   (fun () ->
                     let fields = String.split_on_char ' ' (input_line stat_ic) in
                     if List.length fields > 21 then
                       let hz = 100.0 in (* CLK_TCK, almost always 100 on Linux *)
                       let uptime_ic = open_in "/proc/uptime" in
                       Fun.protect ~finally:(fun () -> close_in uptime_ic)
                         (fun () ->
                           let boot_time = float_of_string (List.hd (String.split_on_char ' ' (input_line uptime_ic))) in
                           let start_since_boot = float_of_string (List.nth fields 21) /. hz in
                           let s = boot_time -. start_since_boot in
                           if s < 60.0 then Printf.sprintf "%.0fs" s
                           else if s < 3600.0 then Printf.sprintf "%.0fm" (s /. 60.0)
                           else Printf.sprintf "%.1fh" (s /. 3600.0))
                     else "")
               with _ -> "")
            else ""
          in
          let pid_str = match outer_pid with Some p -> string_of_int p | None -> "?" in
          Printf.printf "%-20s %-10s %-8s %-12s %s\n" name client status uptime pid_str)
        sorted;
      0
