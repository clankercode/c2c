(* c2c_deliver_managed.ml — machine-wide supervised delivery service (#35).

   Phase 1: supervised singleton (lock + pidfile + start/stop/doctor).
   Phase 2: optional kimi adapter tick (flag-gated), dual-run with the
   per-alias notifier:
     - mode=shadow (default): rebuild watch-set, log would-deliver, no POST
     - mode=active: POST only when notifier is not already_running (DEAF
       fallback — single-writer, closes #9 class without dual POST)
     - mode=primary: service owns drain for watched kimi rows

   Fail-open watch-set rebuild (stale-but-trying over empty-and-silent).
   B098: adapters only probe+deliver DATA; no approval paths. *)

let ( // ) = Filename.concat

(* Keep state next to [C2c_start.instances_dir] / [C2c_relay_managed] so isolated
   test/dev environments (C2C_INSTANCES_DIR) cannot contend with the real HOME
   singleton. *)
let instances_dir () =
  match Sys.getenv_opt "C2C_INSTANCES_DIR" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ ->
      Filename.concat (Sys.getenv "HOME")
        (".local" // "share" // "c2c" // "instances")

let machine_state_dir () = Filename.dirname (instances_dir ())

let machine_lock_resource () = machine_state_dir () // "deliver-service"

(** Conventional instance name for `c2c start deliver-service` (no -n). *)
let default_instance_name = "deliver-service"

let is_default_deliver_service_name name =
  String.equal (String.trim name) default_instance_name

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" || Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o700
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let json_to_file path json =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
      output_string oc (Yojson.Safe.pretty_to_string json);
      output_char oc '\n')

let write_pidfile path pid =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
      output_string oc (string_of_int pid);
      output_char oc '\n')

let read_pidfile path =
  if not (Sys.file_exists path) then None
  else
    try
      let ic = open_in path in
      Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
          int_of_string_opt (String.trim (input_line ic)))
    with _ -> None

let pid_alive pid =
  try Unix.kill pid 0; true with Unix.Unix_error _ -> false

type kimi_mode = Shadow | Active | Primary

let kimi_mode_of_string s =
  match String.lowercase_ascii (String.trim s) with
  | "shadow" | "" -> Shadow
  | "active" -> Active
  | "primary" -> Primary
  | _ -> Shadow (* invalid → safe default *)

let kimi_mode_to_string = function
  | Shadow -> "shadow"
  | Active -> "active"
  | Primary -> "primary"

(** Env: C2C_DELIVER_SERVICE_KIMI=1 enables kimi adapter; mode from
    C2C_DELIVER_SERVICE_KIMI_MODE (default shadow). *)
let kimi_adapter_enabled () =
  match Sys.getenv_opt "C2C_DELIVER_SERVICE_KIMI" with
  | Some v ->
      let v = String.lowercase_ascii (String.trim v) in
      v = "1" || v = "true" || v = "yes" || v = "on"
  | None -> false

let kimi_adapter_mode () =
  match Sys.getenv_opt "C2C_DELIVER_SERVICE_KIMI_MODE" with
  | Some s -> kimi_mode_of_string s
  | None -> Shadow

let agy_adapter_enabled () =
  match Sys.getenv_opt "C2C_DELIVER_SERVICE_AGY" with
  | Some v ->
      let v = String.lowercase_ascii (String.trim v) in
      v = "1" || v = "true" || v = "yes" || v = "on"
  | None -> false

let tick_interval_s () =
  match Sys.getenv_opt "C2C_DELIVER_SERVICE_INTERVAL" with
  | Some s ->
      (try
         let f = float_of_string (String.trim s) in
         if f < 0.2 then 0.2 else if f > 30. then 30. else f
       with _ -> 1.5)
  | None -> 1.5

type watch_entry = {
  broker_root : string;
  session_id : string;
  alias : string;
  workdir : string;
  client_type : string option;
}

(** Pure: should this registration be a kimi watch candidate? *)
let is_kimi_registration (reg : C2c_mcp.registration) : bool =
  match C2c_delivery_endpoint.endpoint_of_kimi_reg ~broker_root:"/" reg with
  | Some _ -> true
  | None ->
      (* endpoint_of_kimi_reg needs workdir; still true for client_type alone
         when testing pure client filter without cwd. *)
      (match reg.client_type with
       | Some ct -> String.lowercase_ascii (String.trim ct) = "kimi"
       | None ->
           (match reg.registered_by with
            | Some rb ->
                let rb = String.lowercase_ascii rb in
                rb = "kimi-hook" || rb = "kimi"
            | None -> false))

(** Pure: build a watch entry via DeliveryEndpoint registry derivation. *)
let watch_entry_of_endpoint ~client_type (ep : C2c_delivery_endpoint.endpoint)
    : watch_entry option =
  let workdir =
    match ep.workdir with
    | Some w when String.trim w <> "" -> String.trim w
    | _ -> "" (* agy may not need workdir for agentapi *)
  in
  Some
    { broker_root = ep.broker_root
    ; session_id = ep.session_id
    ; alias = ep.alias
    ; workdir
    ; client_type
    }

let watch_entry_of_reg ~broker_root (reg : C2c_mcp.registration) : watch_entry option =
  match C2c_delivery_endpoint.endpoint_of_kimi_reg ~broker_root reg with
  | Some ep ->
      (match ep.workdir with
       | Some w when String.trim w <> "" ->
           Some
             { broker_root = ep.broker_root
             ; session_id = ep.session_id
             ; alias = ep.alias
             ; workdir = String.trim w
             ; client_type = reg.client_type
             }
       | _ -> None)
  | None ->
      (match C2c_delivery_endpoint.endpoint_of_agy_reg ~broker_root reg with
       | Some ep ->
           Some
             { broker_root = ep.broker_root
             ; session_id = ep.session_id
             ; alias = ep.alias
             ; workdir = Option.value ep.workdir ~default:""
             ; client_type = reg.client_type
             }
       | None -> None)

(** Pure fail-open merge: if a root failed, keep previous entries for that root. *)
let merge_watch_sets ~prev ~fresh ~failed_roots : watch_entry list =
  let keep_from_prev =
    List.filter
      (fun (e : watch_entry) -> List.mem e.broker_root failed_roots)
      prev
  in
  let from_fresh =
    List.filter
      (fun (e : watch_entry) -> not (List.mem e.broker_root failed_roots))
      fresh
  in
  keep_from_prev @ from_fresh

(** Pure delayed-drop: entry missing from [fresh] stays while miss count < max. *)
let apply_delayed_drop ~prev ~fresh ~miss_counts ~max_misses =
  let fresh_ids =
    List.fold_left
      (fun acc (e : watch_entry) -> e.session_id :: acc)
      [] fresh
  in
  let delayed =
    List.filter
      (fun (e : watch_entry) ->
         (not (List.mem e.session_id fresh_ids))
         &&
         let m =
           try List.assoc e.session_id miss_counts with Not_found -> 0
         in
         m < max_misses)
      prev
  in
  fresh @ delayed

let write_config ~config_path ~phase ~kimi_enabled ~kimi_mode ~agy_enabled =
  json_to_file config_path
    (`Assoc
       [ ("client", `String "deliver-service")
       ; ("scope", `String "machine")
       ; ("supervised", `Bool true)
       ; ("phase", `Int phase)
       ; ("kimi_adapter", `Bool kimi_enabled)
       ; ("kimi_mode", `String (kimi_mode_to_string kimi_mode))
       ; ("agy_adapter", `Bool agy_enabled)
       ; ("created_at", `Float (Unix.gettimeofday ()))
       ])

type managed_config = { mc_phase : int }

let parse_managed_config (json : Yojson.Safe.t) : managed_config option =
  match json with
  | `Assoc a ->
      let is_deliver =
        (match List.assoc_opt "client" a with
         | Some (`String "deliver-service") -> true
         | _ -> false)
        || (match List.assoc_opt "supervised" a, List.assoc_opt "scope" a with
            | Some (`Bool true), Some (`String "machine") ->
                (match List.assoc_opt "client" a with
                 | Some (`String "deliver-service") -> true
                 | _ -> false)
            | _ -> false)
      in
      if not is_deliver then None
      else
        let mc_phase =
          match List.assoc_opt "phase" a with
          | Some (`Int i) when i > 0 -> i
          | _ -> 1
        in
        Some { mc_phase }
  | _ -> None

let read_managed_config ~name : managed_config option =
  let path = instances_dir () // name // "config.json" in
  if not (Sys.file_exists path) then None
  else
    match (try Some (Yojson.Safe.from_file path) with _ -> None) with
    | Some json -> parse_managed_config json
    | None -> None

let remove_pidfile_if_owned path =
  match read_pidfile path with
  | Some pid when pid = Unix.getpid () -> (try Unix.unlink path with _ -> ())
  | _ -> ()

let redirect_daemon_stdio log_path =
  (try
     let dn = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
     Unix.dup2 dn Unix.stdin;
     Unix.close dn
   with _ -> ());
  (try
     let fd =
       Unix.openfile log_path
         [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ]
         0o600
     in
     Unix.dup2 fd Unix.stdout;
     Unix.dup2 fd Unix.stderr;
     Unix.close fd
   with _ -> ())

let scan_kimi_watch_entries () : watch_entry list * string list =
  let failed = ref [] in
  let acc = ref [] in
  let roots =
    try
      List.map (fun (_fp, root) -> root) (C2c_repo_fp.list_all_broker_roots ())
    with exn ->
      Printf.eprintf
        "[deliver-service] list_all_broker_roots failed: %s\n%!"
        (Printexc.to_string exn);
      []
  in
  List.iter
    (fun broker_root ->
      try
        let broker = C2c_mcp.Broker.create ~root:broker_root in
        let regs = C2c_mcp.Broker.list_registrations broker in
        List.iter
          (fun reg ->
            match watch_entry_of_reg ~broker_root reg with
            | Some e ->
                let allow =
                  match e.client_type with
                  | Some ct when String.lowercase_ascii ct = "kimi" ->
                      kimi_adapter_enabled ()
                  | Some ct when String.lowercase_ascii ct = "agy" ->
                      agy_adapter_enabled ()
                  | _ ->
                      (* fall back: kind from registered_by *)
                      (match reg.registered_by with
                       | Some rb when String.lowercase_ascii rb = "kimi-hook" ->
                           kimi_adapter_enabled ()
                       | Some rb when String.lowercase_ascii rb = "agy-hook" ->
                           agy_adapter_enabled ()
                       | _ -> false)
                in
                if allow then acc := e :: !acc
            | None -> ())
          regs
      with exn ->
        Printf.eprintf
          "[deliver-service] broker scan failed for %s: %s\n%!"
          broker_root (Printexc.to_string exn);
        failed := broker_root :: !failed)
    roots;
  (List.rev !acc, !failed)

let log_would_deliver (e : watch_entry) ~inbox_n ~mode =
  Printf.printf
    "[deliver-service] would-deliver mode=%s alias=%s session=%s workdir=%s inbox=%d broker=%s\n%!"
    (kimi_mode_to_string mode) e.alias e.session_id e.workdir inbox_n e.broker_root

let service_should_post ~mode ~alias =
  match mode with
  | Shadow -> false
  | Active -> not (C2c_kimi_notifier.already_running alias)
  | Primary -> true

let is_agy_entry (e : watch_entry) =
  match e.client_type with
  | Some ct -> String.lowercase_ascii ct = "agy"
  | None -> false

let tick_one_entry (e : watch_entry) ~mode : int =
  let broker = C2c_mcp.Broker.create ~root:e.broker_root in
  let msgs =
    try C2c_mcp.Broker.read_inbox broker ~session_id:e.session_id
    with _ -> []
  in
  let n = List.length msgs in
  if n = 0 then 0
  else begin
    log_would_deliver e ~inbox_n:n ~mode;
    if not (service_should_post ~mode ~alias:e.alias) then 0
    else if is_agy_entry e then begin
      match C2c_delivery_endpoint.find "agy" with
      | None -> 0
      | Some (module A) ->
          let ep : C2c_delivery_endpoint.endpoint =
            { kind = "agy"
            ; broker_root = e.broker_root
            ; session_id = e.session_id
            ; alias = e.alias
            ; workdir = if e.workdir = "" then None else Some e.workdir
            }
          in
          (match A.probe ep with
           | `Dead reason ->
               Printf.eprintf
                 "[deliver-service] agy probe dead alias=%s: %s
%!" e.alias
                 reason;
               0
           | `Unknown | `Live ->
               let delivered = ref 0 in
               List.iter
                 (fun msg ->
                   match A.deliver ep msg with
                   | Ok () -> incr delivered
                   | Error err ->
                       Printf.eprintf
                         "[deliver-service] agy deliver failed alias=%s: %s
%!"
                         e.alias err)
                 msgs;
               if
                 !delivered > 0
                 && A.drain_policy = C2c_delivery_endpoint.After_push
               then
                 ignore
                   (C2c_mcp.Broker.drain_inbox
                      ~drained_by:"deliver-service-agy" broker
                      ~session_id:e.session_id);
               !delivered)
    end
    else
      try
        Unix.putenv "C2C_KIMI_DELIVERY_CLAIMANT" ("deliver-service:" ^ e.alias);
        C2c_kimi_notifier.run_once ~broker_root:e.broker_root ~alias:e.alias
          ~session_id:e.session_id ~tmux_pane:None ~workdir:e.workdir
      with exn ->
        Printf.eprintf
          "[deliver-service] run_once failed alias=%s: %s
%!" e.alias
          (Printexc.to_string exn);
        0
  end

(** Phase-2 loop: rebuild kimi watch-set (fail open), optional deliver. *)
let idle_supervise ~pid_path =
  let stopping = ref false in
  let request_stop _ = stopping := true in
  Sys.set_signal Sys.sigterm (Sys.Signal_handle request_stop);
  Sys.set_signal Sys.sigint (Sys.Signal_handle request_stop);
  let prev_watch = ref ([] : watch_entry list) in
  let miss_counts = ref ([] : (string * int) list) in
  Fun.protect
    ~finally:(fun () -> remove_pidfile_if_owned pid_path)
    (fun () ->
      while not !stopping do
        let kimi_on = kimi_adapter_enabled () in
        let agy_on = agy_adapter_enabled () in
        let mode = kimi_adapter_mode () in
        if kimi_on || agy_on then begin
          let fresh, failed_roots =
            try scan_kimi_watch_entries ()
            with exn ->
              Printf.eprintf
                "[deliver-service] scan exception: %s — retaining previous watch-set\n%!"
                (Printexc.to_string exn);
              (!prev_watch, [])
          in
          let merged =
            merge_watch_sets ~prev:!prev_watch ~fresh ~failed_roots
          in
          let fresh_ids =
            List.map (fun (e : watch_entry) -> e.session_id) fresh
          in
          miss_counts :=
            List.filter_map
              (fun (e : watch_entry) ->
                 if List.mem e.session_id fresh_ids then Some (e.session_id, 0)
                 else
                   let m =
                     try List.assoc e.session_id !miss_counts with Not_found -> 0
                   in
                   Some (e.session_id, m + 1))
              merged;
          let watched =
            apply_delayed_drop
              ~prev:!prev_watch ~fresh:merged ~miss_counts:!miss_counts
              ~max_misses:5
          in
          prev_watch := watched;
          List.iter
            (fun e -> ignore (tick_one_entry e ~mode))
            watched
        end;
        Unix.sleepf (tick_interval_s ())
      done;
      0)

type supervisor_status =
  | Alive of { pid : int; name : string }
  | Dead of { reason : string }

let supervisor_status ?(name = default_instance_name) () : supervisor_status =
  let pid_path = instances_dir () // name // "outer.pid" in
  match read_pidfile pid_path with
  | Some pid when pid_alive pid -> Alive { pid; name }
  | Some pid ->
      Dead
        { reason =
            Printf.sprintf
              "pidfile present (pid=%d) but process not alive" pid
        }
  | None -> Dead { reason = "no outer.pid (supervisor not started)" }

let read_runtime_flags ~name =
  match read_managed_config ~name with
  | Some { mc_phase } ->
      let path = instances_dir () // name // "config.json" in
      let kimi_en, kimi_mode, agy_en =
        try
          match Yojson.Safe.from_file path with
          | `Assoc a ->
              let ke =
                match List.assoc_opt "kimi_adapter" a with
                | Some (`Bool b) -> b
                | _ -> false
              in
              let km =
                match List.assoc_opt "kimi_mode" a with
                | Some (`String s) -> kimi_mode_of_string s
                | _ -> Shadow
              in
              let ae =
                match List.assoc_opt "agy_adapter" a with
                | Some (`Bool b) -> b
                | _ -> false
              in
              (ke, km, ae)
          | _ -> (false, Shadow, false)
        with _ -> (false, Shadow, false)
      in
      (mc_phase, kimi_en, kimi_mode, agy_en)
  | None ->
      ( (if kimi_adapter_enabled () || agy_adapter_enabled () then 2 else 1)
      , kimi_adapter_enabled ()
      , kimi_adapter_mode ()
      , agy_adapter_enabled () )

let supervisor_status_to_json (s : supervisor_status) : Yojson.Safe.t =
  let kinds = C2c_delivery_endpoint.list_kinds () in
  let kinds_json = List.map (fun k -> `String k) kinds in
  match s with
  | Alive { pid; name } ->
      let phase, kimi_en, kimi_mode, agy_en = read_runtime_flags ~name in
      let adapters =
        (if kimi_en then [ `String "kimi" ] else [])
        @ (if agy_en then [ `String "agy" ] else [])
      in
      `Assoc
        [ ("service", `String "deliver-service")
        ; ("status", `String "alive")
        ; ("pid", `Int pid)
        ; ("name", `String name)
        ; ("phase", `Int phase)
        ; ("kimi_adapter", `Bool kimi_en)
        ; ("kimi_mode", `String (kimi_mode_to_string kimi_mode))
        ; ("agy_adapter", `Bool agy_en)
        ; ("adapters", `List adapters)
        ; ("endpoint_kinds_registered", `List kinds_json)
        ]
  | Dead { reason } ->
      let phase =
        if kimi_adapter_enabled () || agy_adapter_enabled () then 2 else 1
      in
      `Assoc
        [ ("service", `String "deliver-service")
        ; ("status", `String "dead")
        ; ("reason", `String reason)
        ; ("phase", `Int phase)
        ; ("kimi_adapter", `Bool (kimi_adapter_enabled ()))
        ; ("kimi_mode", `String (kimi_mode_to_string (kimi_adapter_mode ())))
        ; ("agy_adapter", `Bool (agy_adapter_enabled ()))
        ; ("adapters", `List [])
        ; ("endpoint_kinds_registered", `List kinds_json)
        ]

let pp_supervisor_status_human (s : supervisor_status) =
  match s with
  | Alive { pid; name } ->
      let _phase, kimi_en, kimi_mode, agy_en = read_runtime_flags ~name in
      let adapters =
        String.concat ","
          ((if kimi_en then [ "kimi" ] else [])
          @ (if agy_en then [ "agy" ] else [])
          @ (if not kimi_en && not agy_en then [ "none" ] else []))
      in
      Printf.printf
        "=== deliver-service (machine-wide, #35 phase 1/2) ===\n\n\
        \  status: ALIVE (pid=%d, name=%s)\n\
        \  adapters: %s\n\
        \  kimi_mode: %s\n\
        \  endpoint_kinds: %s\n\
        \  stop: c2c stop %s\n\n%!"
        pid name adapters
        (kimi_mode_to_string kimi_mode)
        (String.concat "," (C2c_delivery_endpoint.list_kinds ()))
        name
  | Dead { reason } ->
      Printf.printf
        "=== deliver-service (machine-wide, #35 phase 1/2) ===\n\n\
        \  status: DEAD (%s)\n\
        \  start: c2c start deliver-service\n\
        \  adapters: enable with C2C_DELIVER_SERVICE_KIMI=1\n\
        \  mode: C2C_DELIVER_SERVICE_KIMI_MODE=shadow|active|primary\n\n%!"
        reason

let stop_supervisor ~name ~timeout_s : bool =
  let pid_path = instances_dir () // name // "outer.pid" in
  match read_pidfile pid_path with
  | Some pid when pid_alive pid
                  && not (C2c_pid_identity.pidfile_pid_is_ours ~pidfile:pid_path ~pid) ->
      (* #85: the number is live but was recycled onto another process. There is
         no supervisor to stop, and signalling it would hit a stranger. *)
      true
  | Some pid when pid_alive pid ->
      (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ());
      let deadline = Unix.gettimeofday () +. timeout_s in
      let rec wait () =
        if not (pid_alive pid) then true
        else if Unix.gettimeofday () >= deadline then begin
          (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
          Unix.sleepf 0.2;
          not (pid_alive pid)
        end
        else (Unix.sleepf 0.1; wait ())
      in
      wait ()
  | _ -> true

let run_owner ~name ~foreground ~ready_fd =
  mkdir_p (machine_state_dir ());
  match C2c_singleton_lock.try_acquire ~path:(machine_lock_resource ()) with
  | Already_running ->
      (match ready_fd with
       | Some fd ->
           ignore (Unix.write_substring fd "ALREADY\n" 0 8);
           Unix.close fd
       | None -> ());
      Printf.eprintf
        "error: a machine-wide deliver-service is already running.\n\
         Use 'c2c instances' / 'c2c doctor deliver-service' to inspect it;\n\
         only one supervisor is needed (#35).\n%!";
      1
  | Acquired lock_fd ->
      let inst_dir = instances_dir () // name in
      let pid_path = inst_dir // "outer.pid" in
      let log_path = inst_dir // "log" in
      mkdir_p inst_dir;
      if not foreground then redirect_daemon_stdio log_path;
      write_config
        ~config_path:(inst_dir // "config.json")
        ~phase:
          (if kimi_adapter_enabled () || agy_adapter_enabled () then 2 else 1)
        ~kimi_enabled:(kimi_adapter_enabled ())
        ~kimi_mode:(kimi_adapter_mode ())
        ~agy_enabled:(agy_adapter_enabled ());
      write_pidfile pid_path (Unix.getpid ());
      (match ready_fd with
       | Some fd ->
           ignore (Unix.write_substring fd "READY\n" 0 6);
           Unix.close fd
       | None -> ());
      let code =
        Fun.protect
          ~finally:(fun () -> C2c_singleton_lock.release lock_fd)
          (fun () -> idle_supervise ~pid_path)
      in
      code

let read_ready fd =
  let buf = Bytes.create 16 in
  let n = Unix.read fd buf 0 (Bytes.length buf) in
  Bytes.sub_string buf 0 n

let[@noreturn] start ~name ~daemon () =
  if not daemon then
    exit (run_owner ~name ~foreground:true ~ready_fd:None)
  else begin
    let ready_r, ready_w = Unix.pipe ~cloexec:false () in
    flush_all ();
    match Unix.fork () with
    | 0 ->
        Unix.close ready_r;
        ignore (try Unix.setsid () with _ -> 0);
        (try Unix.chdir "/" with _ -> ());
        exit (run_owner ~name ~foreground:false ~ready_fd:(Some ready_w))
    | supervisor_pid ->
        Unix.close ready_w;
        let status = read_ready ready_r in
        Unix.close ready_r;
        if status = "READY\n" then begin
          Printf.printf
            "[c2c start deliver-service] machine-wide supervisor pid=%d\n\
             [c2c start deliver-service] phase %d (kimi=%b mode=%s)\n\
             [c2c start deliver-service] stop with: c2c stop %s\n%!"
            supervisor_pid
            (if kimi_adapter_enabled () then 2 else 1)
            (kimi_adapter_enabled ())
            (kimi_mode_to_string (kimi_adapter_mode ()))
            name;
          exit 0
        end else if status = "ALREADY\n" then begin
          ignore (Unix.waitpid [] supervisor_pid);
          exit 1
        end else begin
          ignore (Unix.waitpid [] supervisor_pid);
          exit 1
        end
  end

let restart ~name ~timeout_s () =
  match read_managed_config ~name with
  | None when not (is_default_deliver_service_name name) ->
      Printf.eprintf
        "error: '%s' is not a managed deliver-service.\n\
        \  For the machine-wide service: c2c start deliver-service\n\
        \  or c2c restart deliver-service.\n%!"
        name;
      exit 1
  | None | Some _ ->
      if not (stop_supervisor ~name ~timeout_s) then begin
        Printf.eprintf
          "error: could not stop deliver-service '%s' (pid still alive \
           after SIGKILL).\n%!"
          name;
        exit 1
      end;
      Printf.printf
        "[c2c restart] relaunching machine-wide deliver-service '%s'\n%!"
        name;
      start ~name ~daemon:true ()
