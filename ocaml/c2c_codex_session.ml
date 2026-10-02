(* c2c_codex_session — see .mli for the ownership contract. *)

let ( // ) = Filename.concat

(* ------------------------------- identity --------------------------------- *)

(* Codex 0.144.x is the first release exposing the app-server + remote-TUI flag
   set proven by T001/T002 (`--listen`, `--ws-auth`, `--ws-token-sha256`,
   `--remote`, `--remote-auth-token-env`). *)
let codex_min_version = (0, 144, 0)

(* Reuse T002's SHA256 helper so we don't add a second hashing dependency. *)
let sha256_hex = C2c_codex_app_server.sha256_hex

(* 8 hex chars = 32 bits, always < 2^62 so [int_of_string "0x..."] is safe on a
   63-bit OCaml int. *)
let idx_of_hex hex ~start ~modulo =
  let slice = String.sub hex start 8 in
  (int_of_string ("0x" ^ slice)) mod modulo

let derive_alias_base (session_id : string) : string =
  let words = C2c_alias_words.words in
  let n = Array.length words in
  let h = sha256_hex session_id in
  let i1 = idx_of_hex h ~start:0 ~modulo:n in
  let i2raw = idx_of_hex h ~start:8 ~modulo:n in
  (* Guarantee two DIFFERENT words (matches [generate_alias] invariant). *)
  let i2 = if i2raw = i1 then (i2raw + 1) mod n else i2raw in
  (* Match the normal managed-session shape while keeping resume stable. The
     session id is freshly generated for a new launch, so these four digest
     characters provide the random-looking hexadecimal nonce operators expect;
     deriving it from the stable id avoids changing identity on restart. *)
  let nonce = String.sub h 16 4 in
  Printf.sprintf "codex-%s-%s-%s" words.(i1) words.(i2) nonce

let derive_alias ~(session_id : string) ~(taken : string -> bool) : string =
  let base = derive_alias_base session_id in
  if not (taken base) then base
  else begin
    (* Deterministic collision extension: append entropy derived from the SAME
       session id, re-probing [taken] each attempt. Never an unrelated random
       alias, so the extension is stable across restart/resume. *)
    let rec ext k =
      if k > 4096 then
        (* Practically unreachable; keep total with a session-derived suffix. *)
        Printf.sprintf "%s-%s" base (String.sub (sha256_hex (session_id ^ ":x")) 0 8)
      else
        let suffix = String.sub (sha256_hex (Printf.sprintf "%s:%d" session_id k)) 0 4 in
        let cand = Printf.sprintf "%s-%s" base suffix in
        if taken cand then ext (k + 1) else cand
    in
    ext 1
  end

(* --------------------------------- --yolo --------------------------------- *)

let yolo_bypass_flag = "--dangerously-bypass-approvals-and-sandbox"

let yolo_warning =
  "!! --yolo: forwarding codex --dangerously-bypass-approvals-and-sandbox.\n\
   !! All approval prompts AND the sandbox are DISABLED for this session; the\n\
   !! agent can run any command with no confirmation. Only use this in a trusted,\n\
   !! disposable environment. This flag is per-launch and is NOT saved for resume."

let frontend_extra_args ~(yolo : bool) ~(extra : string list) : string list =
  (if yolo then [ yolo_bypass_flag ] else []) @ extra

(* Codex 0.159+ auto-starts a machine-wide app-server daemon. Hook-fallback
   `codex` without --no-daemon attaches to it, prints "Disconnected from this
   task", and the inner TUI exits 0. Gate on the same version parser as the
   app-server path so older Codex is not handed an unknown flag. *)
let no_daemon_min_version = (0, 159, 0)

let codex_version_supports_no_daemon (ver : string option) : bool =
  match ver with
  | None -> false
  | Some s ->
      (match C2c_codex_app_server.parse_version s with
       | Some v -> C2c_codex_app_server.version_ge v no_daemon_min_version
       | None -> false)

let hook_fallback_extra_args ~(yolo : bool) ~(extra : string list)
    ~(codex_version : string option) : string list =
  let base = frontend_extra_args ~yolo ~extra in
  if codex_version_supports_no_daemon codex_version then
    base @ [ "--no-daemon" ]
  else base

let app_server_log_label = "[c2c codex app-server]"

(* B176: local wall-clock HH:MM:SS for every [c2c codex app-server] line. Pure
   so tests can pin [now] without racing the clock. *)
let app_server_log_hms (t : float) : string =
  let tm = Unix.localtime t in
  Printf.sprintf "%02d:%02d:%02d" tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let startup_banner ~color ~(alias : string) ~(endpoint : string) : string =
  let paint code s = if color then code ^ s ^ "\027[0m" else s in
  let sep = paint "\027[2m" " · " in
  String.concat sep
    [ paint "\027[1m" "c2c codex"
    ; paint "\027[32m" "ready"
    ; paint "\027[1m" alias
    ; paint "\027[2m" endpoint
    ]

let online_attached_log_body ~(alias : string) ~(endpoint : string) : string =
  startup_banner ~color:false ~alias ~endpoint

(* Lifecycle phase bodies (no label/timestamp) — distinguishable for operators
   and for regression tests of the three B176 phases. *)
let lifecycle_launching_body ~(alias : string) : string =
  Printf.sprintf "launching app-server (c2c-alias=%s)" alias

let lifecycle_ready_body ~(endpoint : string) : string =
  Printf.sprintf "app-server ready (%s)" endpoint

let lifecycle_tui_handoff_body ~(alias : string) ~(endpoint : string) : string =
  (* Final pre-TUI line reuses the B159 statusline-quality banner content so the
     handoff still reads as a polished ready signal with alias + endpoint. *)
  startup_banner ~color:false ~alias ~endpoint

(** [format_app_server_log ~color ?now body] builds
    [[c2c codex app-server] [HH:MM:SS] body], painting only the label when
    [color] is set (matches historical yellow-label styling). *)
let format_app_server_log ~(color : bool) ?now (body : string) : string =
  let t = match now with Some t -> t | None -> Unix.gettimeofday () in
  let ts = app_server_log_hms t in
  let label =
    if color then "\027[1;33m" ^ app_server_log_label ^ "\027[0m"
    else app_server_log_label
  in
  Printf.sprintf "%s [%s] %s" label ts body

(* Keep managed identity scoped to the remote frontend.  This is intentionally
   the normal c2c session marker: bare `c2c init` and CLI commands then reuse
   the launcher registration instead of synthesizing a second alias.
   AUTO_REGISTER_ALIAS is a whoami/send belt-and-suspenders when a process
   inherits the frontend env but session_id lookup is briefly ambiguous. *)
let app_server_frontend_env ~session_id ~alias =
  [ "C2C_MCP_SESSION_ID=" ^ session_id
  ; "C2C_CODEX_APPSERVER_SESSION=" ^ session_id
  ; "C2C_MCP_AUTO_REGISTER_ALIAS=" ^ alias
  ; "C2C_CODEX_MANAGED=1" ]

(* Daemon-attach TUI must NOT inherit the private-server marker. The launcher
   discovers the exact native thread after the remote frontend is loaded and
   arms the sidecar itself; the hook remains identity/fallback-only. *)
let daemon_frontend_env ~session_id ~alias ~instance_name =
  [ "C2C_MCP_SESSION_ID=" ^ session_id
  ; "C2C_MCP_AUTO_REGISTER_ALIAS=" ^ alias
  ; "C2C_CODEX_APPSERVER_SESSION="
  ; "C2C_CODEX_MANAGED=1"
  ; "C2C_CODEX_INSTANCE_NAME=" ^ instance_name ]

let daemon_frontend_workspace_args ~(cwd : string) =
  [ "--cd"; cwd ]

let select_new_loaded_thread ~before ~candidates =
  match List.filter (fun thread_id -> not (List.mem thread_id before)) candidates with
  | [ thread_id ] -> Some thread_id
  | _ -> None

let daemon_attach_forced_off () =
  match Sys.getenv_opt "C2C_CODEX_FORCE_PRIVATE_APPSERVER" with
  | Some "1" -> true
  | _ -> false

let daemon_attach_safe_to_start ~socket_available ~pidfd_available
    ~pid_generation_available =
  socket_available && pidfd_available && pid_generation_available

let daemon_attach_available () =
  if daemon_attach_forced_off () then false
  else
    let socket_available =
      match C2c_codex_daemon_sidecar.default_control_socket () with
      | None -> false
      | Some path ->
          (match C2c_codex_daemon_sidecar.unix_endpoint path with
           | None -> false
           | Some ep ->
               try
                 let fd = C2c_codex_transport.ws_connect ep ~token:"" ~timeout:2.0 in
                 (try Unix.close fd with _ -> ());
                 true
               with _ -> false)
    in
    (* The daemon path starts a detached remote frontend and later relies on
       owner-bound cleanup. Refuse that path before the frontend is spawned
       unless this launcher has both an exact process generation and pidfd
       signalling. The private app-server path below remains the safe fallback. *)
    daemon_attach_safe_to_start ~socket_available
      ~pidfd_available:(C2c_pid_identity.pidfd_supported ())
      ~pid_generation_available:
        (Option.is_some
           (C2c_mcp.Broker.read_pid_start_time (Unix.getpid ())))

let child_env extra =
  let key kv =
    match String.index_opt kv '=' with Some i -> String.sub kv 0 i | None -> kv
  in
  let overridden = List.map key extra in
  let inherited =
    Unix.environment () |> Array.to_list
    |> List.filter (fun kv -> not (List.mem (key kv) overridden))
  in
  Array.of_list (inherited @ extra)

(* [spawn_frontend_process] learns the real frontend PID only after [fork].
   Publish that PID into the child environment immediately before [exec], so
   Codex hooks can distinguish this frontend from a nested Codex that merely
   inherited the managed launcher's environment. *)
let frontend_owner_env env pid =
  let key kv =
    match String.index_opt kv '=' with
    | Some i -> String.sub kv 0 i
    | None -> kv
  in
  let overridden =
    [ "C2C_CODEX_FRONTEND_PID"; "C2C_CODEX_FRONTEND_PID_START_TIME" ]
  in
  let kept =
    Array.to_list env |> List.filter (fun kv -> not (List.mem (key kv) overridden))
  in
  let generation = C2c_mcp.Broker.read_pid_start_time pid in
  let generation_text =
    match generation with Some value -> string_of_int value | None -> ""
  in
  Array.of_list
    (kept
     @ [ "C2C_CODEX_FRONTEND_PID=" ^ string_of_int pid
       ; ( "C2C_CODEX_FRONTEND_PID_START_TIME="
         ^ generation_text ) ])

let wait_child pid =
  match Unix.waitpid [] pid with
  | _, Unix.WEXITED n -> n
  | _, Unix.WSIGNALED _ -> 128
  | _, Unix.WSTOPPED _ -> 1

(* The daemon attach frontend is a real interactive child, but it owns a
   process group so `c2c stop` cannot leave a shell/inner Codex process behind.
   OCaml's Unix module does not expose setpgid on this toolchain; the project
   C stub is already used by the managed-client launcher. *)
external setpgid : int -> int -> unit = "caml_c2c_setpgid"
external tcgetpgrp : Unix.file_descr -> int = "caml_c2c_tcgetpgrp"
external tcsetpgrp : Unix.file_descr -> int -> unit = "caml_c2c_tcsetpgrp"

let sentinel_group_joined ~frontend_pid ~sentinel_pid =
  C2c_pid_identity.proc_pgrp sentinel_pid = Some frontend_pid

let sentinel_join_proven ~parent_joined ~child_joined ~group_joined =
  parent_joined && child_joined && group_joined

let reap_process ~pid =
  let rec reap attempts =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ when attempts > 0 -> Unix.sleepf 0.01; reap (attempts - 1)
    | 0, _ -> ()
    | _, _ -> ()
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> ()
  in
  reap 100

let kill_exact_process_and_reap ~pid ~start_time =
  match start_time with
  | Some expected
    when C2c_mcp.Broker.read_pid_start_time pid = Some expected ->
      let signalled =
        try
          C2c_pid_identity.signal_pid_if_generation_matches
            ~pid ~start_time:expected ~signal:Sys.sigkill
        with _ -> false
      in
      if not signalled
         && C2c_mcp.Broker.read_pid_start_time pid = Some expected
      then (try Unix.kill pid Sys.sigkill with _ -> ());
      reap_process ~pid
  | _ -> ()

let cleanup_after_sentinel_join_failure ~frontend_pid ~frontend_start_time
    ~sentinel_pid ~sentinel_start_time =
  (match frontend_start_time with
   | Some expected
     when C2c_mcp.Broker.read_pid_start_time frontend_pid = Some expected ->
       if C2c_pid_identity.proc_pgrp frontend_pid = Some frontend_pid then
         (try Unix.kill (-frontend_pid) Sys.sigkill with _ -> ())
       else
         ignore
           (try
              C2c_pid_identity.signal_pid_if_generation_matches
                ~pid:frontend_pid ~start_time:expected ~signal:Sys.sigkill
            with _ -> false);
       reap_process ~pid:frontend_pid
   | _ -> ());
  kill_exact_process_and_reap ~pid:sentinel_pid ~start_time:sentinel_start_time

type terminal_foreground = {
  fd : Unix.file_descr;
  original_pgrp : int;
}

let capture_terminal_foreground () : terminal_foreground option =
  try
    if Unix.isatty Unix.stdin then
      Some { fd = Unix.stdin; original_pgrp = tcgetpgrp Unix.stdin }
    else None
  with _ -> None

let handoff_terminal_to_child (terminal : terminal_foreground option) pid =
  match terminal with
  | Some { fd; _ } -> (try tcsetpgrp fd pid with _ -> ())
  | None -> ()

let restore_terminal_foreground (terminal : terminal_foreground option) =
  match terminal with
  | Some { fd; original_pgrp } -> (try tcsetpgrp fd original_pgrp with _ -> ())
  | None -> ()

let spawn_frontend_process ~(bin : string) ~(argv : string array)
    ~(env : string array) ~(terminal : terminal_foreground option)
    ~(on_parent_fork : int -> unit)
    ~(on_sentinel : (int * int option) -> unit) : int =
  (* A termination signal delivered after fork but before [on_parent_fork]
     publishes the child used to run cleanup with no frontend PID. Keep those
     signals pending across the complete fork/publication/terminal-handoff
     sequence; the handler then sees the child and can kill its process group. *)
  let blocked = [ Sys.sigterm; Sys.sigint ] in
  let previous = try Thread.sigmask Unix.SIG_BLOCK blocked with _ -> [] in
  Fun.protect
    ~finally:(fun () ->
      try ignore (Thread.sigmask Unix.SIG_SETMASK previous) with _ -> ())
    (fun () ->
      match Unix.fork () with
      | 0 ->
          (* The frontend must not inherit the launcher's shutdown handlers.
             Reset these dispositions before any process-group or TTY setup so
             an early signal reaches the exec'd client normally. *)
          (try ignore (Sys.signal Sys.sigterm Sys.Signal_default) with _ -> ());
          (try ignore (Sys.signal Sys.sigint Sys.Signal_default) with _ -> ());
          (* The child must not inherit the parent's blocked termination signals
             while it is running the actual frontend. *)
          (try ignore (Thread.sigmask Unix.SIG_SETMASK previous) with _ -> ());
          (try setpgid 0 0 with _ -> exit 125);
          (* Hand the terminal to the new group before exec. The parent repeats
             the handoff below to close the fork/exec race. *)
          handoff_terminal_to_child terminal (Unix.getpid ());
          (try Unix.execvpe bin argv (frontend_owner_env env (Unix.getpid ()))
           with _ -> exit 127)
      | pid ->
          let generation = C2c_mcp.Broker.read_pid_start_time pid in
          let cleanup_exact_owner () =
            match generation with
            | Some expected
              when C2c_mcp.Broker.read_pid_start_time pid = Some expected ->
                if C2c_pid_identity.proc_pgrp pid = Some pid then begin
                  (try Unix.kill (-pid) Sys.sigterm with _ -> ());
                  Unix.sleepf 0.05;
                  if C2c_mcp.Broker.read_pid_start_time pid = Some expected
                     && C2c_pid_identity.proc_pgrp pid = Some pid then
                    (try Unix.kill (-pid) Sys.sigkill with _ -> ())
                end else
                  ignore
                    (C2c_pid_identity.signal_pid_if_generation_matches
                       ~pid ~start_time:expected ~signal:Sys.sigkill);
                reap_process ~pid
            | _ -> ()
          in
          (try setpgid pid pid with e -> cleanup_exact_owner (); raise e);
          (* Keep an owner-bound sentinel in the frontend's process group. The
             frontend may exit and be reaped while descendants remain; the
             sentinel preserves a generation-checked owner until teardown, so
             a reused PGID is never signalled. *)
          let sentinel_status_r, sentinel_status_w = Unix.pipe () in
          let close_fd fd = try Unix.close fd with _ -> () in
          (match Unix.fork () with
           | 0 ->
               close_fd sentinel_status_r;
               let joined =
                 try setpgid 0 pid; true with _ -> false
               in
               (* The parent must observe the child's own join result. A
                  successful parent-side setpgid alone is not proof that the
                  sentinel made the required transition. *)
               (try
                  ignore
                    (Unix.write_substring sentinel_status_w
                       (if joined then "1" else "0") 0 1)
                with _ -> ());
               close_fd sentinel_status_w;
               if not joined then exit 125;
               (try ignore (Sys.signal Sys.sigterm Sys.Signal_ignore) with _ -> ());
               (try ignore (Sys.signal Sys.sigint Sys.Signal_ignore) with _ -> ());
               while true do Unix.pause () done
           | sentinel ->
               close_fd sentinel_status_w;
               let sentinel_start_time =
                 C2c_mcp.Broker.read_pid_start_time sentinel
               in
               let fail_sentinel_join message =
                 close_fd sentinel_status_r;
                 cleanup_after_sentinel_join_failure ~frontend_pid:pid
                   ~frontend_start_time:generation ~sentinel_pid:sentinel
                   ~sentinel_start_time;
                 raise (Failure message)
               in
               (try setpgid sentinel pid with e ->
                  close_fd sentinel_status_r;
                  cleanup_after_sentinel_join_failure ~frontend_pid:pid
                    ~frontend_start_time:generation ~sentinel_pid:sentinel
                    ~sentinel_start_time;
                  raise e);
               let child_joined =
                 let status = Bytes.create 1 in
                 try
                   Unix.read sentinel_status_r status 0 1 = 1
                   && Bytes.get status 0 = '1'
                 with _ -> false
               in
               close_fd sentinel_status_r;
               if not child_joined then
                 fail_sentinel_join
                   "Codex frontend sentinel child could not join its exact process group";
               if not
                    (sentinel_join_proven ~parent_joined:true ~child_joined
                       ~group_joined:
                         (sentinel_group_joined ~frontend_pid:pid
                            ~sentinel_pid:sentinel)) then
                 fail_sentinel_join
                   "Codex frontend sentinel did not join its exact process group";
               (* Publish ownership only after the parent and child have both
                  proved the sentinel's exact frontend group. A failed join
                  must never leave a teardown record claiming a group we cannot
                  prove. *)
               on_parent_fork pid;
               on_sentinel
                 (sentinel, C2c_mcp.Broker.read_pid_start_time sentinel));
          handoff_terminal_to_child terminal pid;
          pid)

let stop_frontend_process ?owner_start_time ?sentinel_pid ?sentinel_start_time pid : bool =
  let wait_once () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ -> false
    | _, _ -> true
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> true
  in
  let owner_alive () =
    match sentinel_pid, sentinel_start_time with
    | Some sentinel, Some expected ->
        C2c_mcp.Broker.read_pid_start_time sentinel = Some expected
        && C2c_pid_identity.proc_pgrp sentinel = Some pid
    | _ ->
        (* Without a sentinel, the process-group leader itself is the only
           owner proof. Missing generation metadata is not sufficient owner
           proof: a recycled PID/PGID must never receive a signal. *)
        (match owner_start_time with
         | None -> false
         | Some expected ->
             C2c_mcp.Broker.read_pid_start_time pid = Some expected
             && C2c_pid_identity.proc_pgrp pid = Some pid)
  in
  let group_alive () =
    try Unix.kill (-pid) 0; true
    with Unix.Unix_error (Unix.ESRCH, _, _) -> false
       | Unix.Unix_error _ -> true
  in
  let signal_group signal =
    if not (owner_alive ()) then false
    else try Unix.kill (-pid) signal; true with Unix.Unix_error _ -> false
  in
  (* A missing generation/sentinel is an unknown owner, even when the numeric
     process group happens to be gone already.  Never turn that uncertainty
     into a successful cleanup result. *)
  if not (owner_alive ()) then false
  else
  (* The leader may already have exited (and been reaped) while descendants
     remain in its process group.  Signal the group independently of the
     leader's wait state, then reap the leader if it is still our child. *)
  let term_sent = signal_group Sys.sigterm in
  let deadline = Unix.gettimeofday () +. 2.0 in
  let rec wait_grace () =
    if (wait_once () && not (group_alive ())) || Unix.gettimeofday () >= deadline then ()
    else (Unix.sleepf 0.05; wait_grace ())
  in
  wait_grace ();
  (* Escalate the group even when [wait_once] observed ECHILD.  That is the
     case where the old implementation leaked shell/inner-Codex descendants. *)
  let kill_sent = signal_group Sys.sigkill in
  let deadline = Unix.gettimeofday () +. 2.0 in
  let reap_sentinel () =
    match sentinel_pid with
    | Some sentinel ->
        (try ignore (Unix.waitpid [ Unix.WNOHANG ] sentinel) with _ -> ())
    | None -> ()
  in
  let rec wait_group_gone () =
    reap_sentinel ();
    if not (group_alive ()) then true
    else if Unix.gettimeofday () >= deadline then false
    else (Unix.sleepf 0.05; wait_group_gone ())
  in
  let group_gone = wait_group_gone () in
  (match sentinel_pid with
   | Some sentinel ->
       (try ignore (Unix.waitpid [ Unix.WNOHANG ] sentinel) with _ -> ())
   | None -> ());
  (try ignore (Unix.waitpid [] pid) with Unix.Unix_error _ -> ());
  (* A process-group id is the only target used here. If the group did not
     disappear within the bounded poll, report failure so callers cannot claim
     teardown completed while descendants remain. *)
  ignore term_sent;
  ignore kill_sent;
  group_gone

(* ------------------------- positional splitting --------------------------- *)

(* cmdliner captures everything after a literal `--` as positionals; on some
   invocations the `--` token itself is included. Drop one leading separator so
   the remainder is the verbatim codex passthrough. *)
let drop_sep = function
  | "--" :: rest -> rest
  | other -> other

let split_client raw =
  match raw with
  | client :: rest -> (Some client, drop_sep rest)
  | [] -> (None, [])

let split_client_alias raw =
  match raw with
  | client :: alias :: rest -> (Some client, Some alias, drop_sep rest)
  | [ client ] -> (Some client, None, [])
  | [] -> (None, None, [])

(* B221: resolve the reserved post-separator wrapper namespace for Codex's
   reduced command forms. Fresh/start forms may use --c2c:name as the alias +
   managed instance name; resume already has an authoritative positional alias
   and rejects a second identity selector. *)
let resolve_namespaced_passthrough ~allow_name ~(existing_name : string option)
    (extra_args : string list) : ((string option * string list), string) result =
  match C2c_start.parse_namespaced_passthrough extra_args with
  | Error _ as error -> error
  | Ok parsed when not allow_name && parsed.C2c_start.c2c_name <> None ->
      Error
        "--c2c:name is not valid with `c2c resume codex`; the positional ALIAS \
         selects the saved identity"
  | Ok parsed ->
      (match C2c_start.merge_namespaced_name ~existing:existing_name
               ~namespaced:parsed.C2c_start.c2c_name with
       | Ok name -> Ok (name, parsed.C2c_start.client_args)
       | Error _ as error -> error)

(* --thread-id reconciliation: a requested thread that conflicts with the saved
   thread is rejected rather than guessed. *)
let reconcile_thread ~(requested : string option) ~(saved : string option)
    : (string option, string) result =
  match requested, saved with
  | Some t, Some s when String.trim t <> "" && t <> s ->
      Error (Printf.sprintf
        "--thread-id %s conflicts with the saved thread %s for this session; \
         refusing to guess. Pass the matching --thread-id or omit it." t s)
  | Some t, _ when String.trim t <> "" -> Ok (Some t)
  | _, saved -> Ok saved

(* -------------------------------- status ---------------------------------- *)

type status =
  | Starting
  | Online_attached
  | Offline
  | Failed_startup

let status_to_string = function
  | Starting -> "starting"
  | Online_attached -> "online-attached"
  | Offline -> "offline"
  | Failed_startup -> "failed-startup"

let status_of_app_server_state (s : C2c_codex_app_server.state) : status =
  match s with
  | Allocating | Starting_server | Waiting_ready | Starting_frontend -> Starting
  | Running -> Online_attached
  | Frontend_exited | Stopping_server | Offline -> Offline
  | Failed | Cleaning_up -> Failed_startup

let status_of_instance ~(instance_dir : string) : status option =
  match C2c_codex_app_server.load_persisted ~instance_dir with
  | None -> None
  | Some p ->
      let st = status_of_app_server_state p.C2c_codex_app_server.state in
      (* A record that claims to be up but whose recorded pids are dead (hard
         kill / crash — the supervisor never got to persist Offline) is really
         offline. Cross-check liveness so `c2c instances` doesn't show a ghost
         session as online-attached. *)
      (match st with
       | Starting | Online_attached ->
           let alive = function Some pid -> C2c_codex_app_server.pid_alive pid | None -> false in
           if alive p.C2c_codex_app_server.server_pid
              || alive p.C2c_codex_app_server.frontend_pid
           then Some st
           else Some Offline
       | _ -> Some st)

(* ------------------------- deliver-loop health ---------------------------- *)

(* B138: the deliver loop's [degraded] flag (no frontend thread ever loaded, so
   nothing actually delivers) is runtime-only. Persist it into the instance dir
   so `c2c doctor`/`c2c health` — which read persisted state, not the live loop —
   can tell a healthy online-attached session from one whose delivery is
   degraded, instead of overclaiming LIVE app-server delivery for both.

   The record is STAMPED with the app-server unit's [unit_id] (its generation).
   A record whose unit_id does not match the currently-attached unit is from a
   prior run on a reused instance dir and MUST NOT be trusted — otherwise a
   healthy prior run's [degraded=false] would mask a new no-thread session
   (B138 review). *)
let delivery_status_path ~instance_dir = instance_dir // "codex-delivery-status.json"

(* #31: WHY a deliver loop is degraded. [degraded] alone conflates two
   operationally different states, and the remediation for each is the opposite
   of the other's:
   - [Dr_no_thread]: no frontend thread ever loaded, so there is nothing to
     inject into. Fix: open/focus a thread in the remote TUI.
   - [Dr_binding_refused]: a thread DID load and mail IS being injected into it,
     but the #24 guard refused to record the durable thread binding because a
     live managed sibling already owns that thread. Telling the operator to open
     a thread here is unfollowable (one is already open); the real action is to
     resolve the sibling. *)
type degraded_reason = Dr_no_thread | Dr_binding_refused

let degraded_reason_to_string = function
  | Dr_no_thread -> "no-thread"
  | Dr_binding_refused -> "binding-refused"

let degraded_reason_of_string = function
  | "no-thread" -> Some Dr_no_thread
  | "binding-refused" -> Some Dr_binding_refused
  | _ -> None

(* Best-effort persist of the deliver-loop degraded signal, stamped with the
   attached unit's [unit_id]. [degraded] = true means the app-server unit is
   supervised but no thread was discovered to inject into. Written fail-closed
   (true) at session start + loop start, flipped to false once a thread loads.
   Never raises (delivery health must never wedge the session). *)
let write_delivery_degraded ?now ?(reason = Dr_no_thread) ~instance_dir
    ~(unit_id : string) (degraded : bool) : unit =
  try
    (try if not (Sys.file_exists instance_dir) then C2c_io.mkdir_p instance_dir
     with _ -> ());
    let path = delivery_status_path ~instance_dir in
    (* #27: [updated_at] doubles as the deliver loop's liveness HEARTBEAT — the
       loop re-stamps it on a throttle while alive, so a stale value means the
       loop died. [?now] is a test seam; production uses the wall clock. *)
    let ts = match now with Some t -> t | None -> Unix.gettimeofday () in
    (* #31 (nit 3): [thread_loaded] is the narrow "a frontend thread exists"
       fact, decoupled from [degraded] — a binding-refused unit HAS a loaded
       thread while being degraded. [reason] is only meaningful when
       [degraded]; a healthy record carries none. *)
    let thread_loaded = (not degraded) || reason = Dr_binding_refused in
    let j =
      `Assoc
        ([ ("unit_id", `String unit_id);
           ("degraded", `Bool degraded);
           ("thread_loaded", `Bool thread_loaded) ]
         @ (if degraded then [ ("reason", `String (degraded_reason_to_string reason)) ]
            else [])
         @ [ ("updated_at", `Float ts) ])
    in
    let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
    let oc = open_out tmp in
    Fun.protect ~finally:(fun () -> close_out oc)
      (fun () -> output_string oc (Yojson.Safe.to_string j); output_string oc "\n");
    (try Unix.rename tmp path with _ -> ())
  with _ -> ()

(* Read the persisted deliver-loop degraded signal, trusting it ONLY when its
   stamped unit_id matches [unit_id] (the currently-attached unit). [None] =
   absent / parse error / unit_id mismatch (stale record from a prior run on a
   reused dir). Total — any read/parse error reads as [None]. *)
(* #27: staleness window for the deliver-loop heartbeat. The loop re-stamps
   [updated_at] roughly every {!C2c_codex_deliver_loop.heartbeat_interval_s}
   (~10s) while alive; a persisted [degraded=false] is only trustworthy while
   that heartbeat is fresh. The window is DELIBERATELY GENEROUS — a slow/paused
   host (this machine has known post-resume RTC/NTP clock jumps) must never be
   false-flagged as deaf — so only a clearly-silent heartbeat (older than the
   window, i.e. many missed beats) is treated as a dead loop. *)
let default_stale_window_s = 120.0

let delivery_degraded_of_instance ?now ?(stale_window_s = default_stale_window_s)
    ~(instance_dir : string) ~(unit_id : string) () : bool option =
  match C2c_io.read_json_opt (delivery_status_path ~instance_dir) with
  | Some (`Assoc a) ->
      let unit_matches =
        match List.assoc_opt "unit_id" a with
        | Some (`String u) -> u = unit_id
        | _ -> false
      in
      if not unit_matches then None
      else (
        match List.assoc_opt "degraded" a with
        | Some (`Bool false) ->
            (* Persisted HEALTHY: trust it only while the heartbeat is fresh.
               A stale [updated_at] means the deliver loop died (SIGKILL etc.)
               while the frontend TUI child survived — the record still claims
               healthy but nothing is delivering (#27). Downgrade to degraded so
               the silent-deaf session becomes visible. Only ever DOWNGRADES a
               healthy claim; a missing [updated_at] (older record) is treated
               as fresh (no false-flag). *)
            let now = match now with Some t -> t | None -> Unix.gettimeofday () in
            let updated_at =
              match List.assoc_opt "updated_at" a with
              | Some (`Float f) -> Some f
              | Some (`Int i) -> Some (float_of_int i)
              | _ -> None
            in
            (match updated_at with
             | Some ts when now -. ts > stale_window_s -> Some true
             | _ -> Some false)
        | Some (`Bool b) -> Some b
        | _ -> None)
  | _ -> None

(* #31: WHY the persisted record is degraded, for the operator-facing surfaces.
   [None] = healthy / untrusted / unreadable — callers must not invent a reason
   for a record they would not trust. Only ever consulted alongside a degraded
   verdict; a record with no (or an unknown) [reason] field — e.g. one written
   by a pre-#31 binary — reads as [Dr_no_thread], the historical meaning. *)
let delivery_degraded_reason_of_instance ~(instance_dir : string)
    ~(unit_id : string) () : degraded_reason option =
  match C2c_io.read_json_opt (delivery_status_path ~instance_dir) with
  | Some (`Assoc a) ->
      let unit_matches =
        match List.assoc_opt "unit_id" a with
        | Some (`String u) -> u = unit_id
        | _ -> false
      in
      if not unit_matches then None
      else (
        match List.assoc_opt "degraded" a with
        | Some (`Bool true) ->
            (match List.assoc_opt "reason" a with
             | Some (`String s) ->
                 (match degraded_reason_of_string s with
                  | Some r -> Some r
                  | None -> Some Dr_no_thread)
             | _ -> Some Dr_no_thread)
        | _ -> None)
  | _ -> None

(* Decide, fail-closed, whether an ONLINE-ATTACHED managed codex session's
   delivery loop is degraded (B138). Loads the live unit_id from the app-server
   record and trusts the persisted degraded signal only when its stamp matches.
   Absence / staleness / a missing persisted record ALL read as degraded=true:
   an online-attached session always has a driving deliver loop that writes this
   record, so its absence means write-failure / mid-startup / stale reuse, and
   we must fail TOWARD degraded rather than overclaim LIVE. A genuinely healthy
   session (thread loaded) wrote degraded=false with the matching unit_id, so it
   still reads healthy — the healthy path is not weakened. Total. *)
let online_attached_delivery_degraded ?now ?(stale_window_s = default_stale_window_s)
    ~(instance_dir : string) () : bool =
  match C2c_codex_app_server.load_persisted ~instance_dir with
  | Some p ->
      (match
         delivery_degraded_of_instance ?now ~stale_window_s ~instance_dir
           ~unit_id:p.C2c_codex_app_server.unit_id ()
       with
       | Some b -> b
       | None -> true)
  | None -> true

(* #31: companion to {!online_attached_delivery_degraded} — [true] only when the
   trusted, unit-stamped record attributes the degradation to the #24 refusal (a
   live managed sibling already owns this thread). Never fails toward [true]:
   every uncertain case (no record, wrong unit, healthy, absent reason) is the
   historical [Dr_no_thread] shape, so an unknown record can only produce the
   generic remediation, never a specific-but-wrong one. Total. *)
let online_attached_delivery_binding_refused ~(instance_dir : string) () : bool =
  match C2c_codex_app_server.load_persisted ~instance_dir with
  | Some p ->
      (try
         delivery_degraded_reason_of_instance ~instance_dir
           ~unit_id:p.C2c_codex_app_server.unit_id ()
         = Some Dr_binding_refused
       with _ -> false)
  | None -> false

(* --------------------------- identity mapping ----------------------------- *)

type mapping = {
  session_id : string;
  alias : string;
  thread_id : string option;
  created_at : float;
  updated_at : float;
}

let mapping_path ~instance_dir = instance_dir // "codex-session.json"
let restart_request_path ~instance_dir = instance_dir // "restart.request.json"
let restart_result_path ~instance_dir ~request_id =
  instance_dir // ("restart.result." ^ request_id ^ ".json")

type restart_request = { rr_id : string; rr_force : bool }

let fresh_request_id () =
  Printf.sprintf "%d-%08x" (Unix.getpid ()) (Random.bits ())

let request_restart ~instance_dir ~(force : bool) : string =
  let request_id = fresh_request_id () in
  let path = restart_request_path ~instance_dir in
  let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
  let oc = open_out tmp in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
      Yojson.Safe.to_channel oc
        (`Assoc [ ("request_id", `String request_id);
                  ("force", `Bool force);
                  ("requested_at", `Float (Unix.gettimeofday ())) ]);
      output_string oc "\n");
  Unix.rename tmp path;
  request_id

let consume_restart_request ~instance_dir : restart_request option =
  let path = restart_request_path ~instance_dir in
  match C2c_io.read_json_opt path with
  | None -> None
  | Some (`Assoc fields) ->
      (try Sys.remove path with _ -> ());
      let id = match List.assoc_opt "request_id" fields with
        | Some (`String s) when String.trim s <> "" -> s
        | _ -> fresh_request_id ()
      in
      Some { rr_id = id;
             rr_force = (match List.assoc_opt "force" fields with
                         | Some (`Bool b) -> b | _ -> false) }
  | Some _ -> (try Sys.remove path with _ -> ()); None

let write_restart_result ~instance_dir ~request_id ~result : unit =
  let path = restart_result_path ~instance_dir ~request_id in
  let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
  let oc = open_out tmp in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
      Yojson.Safe.to_channel oc
        (`Assoc [ ("request_id", `String request_id);
                  ("result", `String result);
                  ("decided_at", `Float (Unix.gettimeofday ())) ]);
      output_string oc "\n");
  Unix.rename tmp path

let await_restart_result ~instance_dir ~request_id ~(timeout_s : float) : string option =
  let path = restart_result_path ~instance_dir ~request_id in
  let deadline = Unix.gettimeofday () +. max 0.0 timeout_s in
  let rec loop () =
    match C2c_io.read_json_opt path with
    | Some (`Assoc fields) ->
        let result = match List.assoc_opt "result" fields with
          | Some (`String s) -> Some s | _ -> None
        in
        (try Sys.remove path with _ -> ());
        result
    | _ when Unix.gettimeofday () >= deadline -> None
    | _ -> Unix.sleepf 0.05; loop ()
  in
  loop ()

let executable_file path =
  try
    let st = Unix.stat path in
    if st.Unix.st_kind <> Unix.S_REG then false
    else (Unix.access path [ Unix.X_OK ]; true)
  with _ -> false

(* --- B224: codex MCP-block preflight -------------------------------------- *)
(* Managed Codex launches (all four command forms funnel through {!run}) use
   the app-server transport, hooks, and CLI without requiring an MCP block.
   The optional machine-wide [mcp_servers.c2c] block is written only by
   `c2c install codex --with-mcp`. If it is present but stale (an `opam exec
   -- <server_path>` whose build path was removed, or a bare `c2c-mcp-server`
   no longer on PATH), Codex fails the MCP handshake and the operator lands in
   a silently-broken managed session:

     MCP client for `c2c` failed to start: ... connection closed
     MCP startup incomplete (failed: c2c)

   The preflight below classifies that block up front so [run] can stop with an
   actionable repair message instead of launching into the broken state. *)

type mcp_block_status =
  | Mcp_ok                (* block present and its launch command resolves *)
  | Mcp_missing           (* no [mcp_servers.c2c] block at all *)
  | Mcp_stale of string   (* block present but the launch command is unresolvable *)

(* All double-quoted substrings on one line, in order (TOML string tokens). The
   setup writer emits [command]/[args] on single lines with simple quoting, so a
   naive scan is sufficient and avoids a TOML dependency here. *)
let quoted_tokens (line : string) : string list =
  let n = String.length line in
  let rec go i acc =
    if i >= n then List.rev acc
    else if line.[i] = '"' then begin
      match String.index_from_opt line (i + 1) '"' with
      | Some j -> go (j + 1) (String.sub line (i + 1) (j - i - 1) :: acc)
      | None -> List.rev acc
    end
    else go (i + 1) acc
  in
  go 0 []

(* Parse the [command] and [args] of the [mcp_servers.c2c] section from raw
   config.toml content. Scanning stops at the first following section header so
   the nested [mcp_servers.c2c.env] / [.tools.*] sub-tables are never mistaken
   for the launch command. Returns [None] when the section header is absent. *)
let parse_codex_mcp_command (content : string) : (string option * string list) option =
  let lines = String.split_on_char '\n' content in
  let rec find_section = function
    | [] -> None
    | line :: rest ->
        if String.trim line = "[mcp_servers.c2c]" then Some rest
        else find_section rest
  in
  match find_section lines with
  | None -> None
  | Some body ->
      let command = ref None and args = ref [] in
      let rec scan = function
        | [] -> ()
        | line :: rest ->
            let t = String.trim line in
            if String.length t > 0 && t.[0] = '[' then ()  (* next section: stop *)
            else begin
              (match quoted_tokens line with
               | first :: _ when
                   (let key = String.trim (List.hd (String.split_on_char '=' line)) in
                    key = "command") -> command := Some first
               | _ -> ());
              (let key = String.trim (List.hd (String.split_on_char '=' line)) in
               if key = "args" then args := quoted_tokens line);
              scan rest
            end
      in
      scan body;
      Some (!command, !args)

(* [classify_codex_mcp_block ~content ~resolves] is the pure classifier. [content]
   is [None] when the config file is absent; [resolves cmd] reports whether a
   launch command (bare name searched on PATH, or a path) is runnable. For the
   `opam exec -- <server>` shape the meaningful target is the wrapped server
   (the reported staleness), so that argument is validated rather than `opam`. *)
let classify_codex_mcp_block ~(content : string option)
    ~(resolves : string -> bool) : mcp_block_status =
  match content with
  | None -> Mcp_missing
  | Some content ->
      (match parse_codex_mcp_command content with
       | None -> Mcp_missing
       | Some (None, _) ->
           Mcp_stale "[mcp_servers.c2c] has no `command`"
       | Some (Some cmd, args) ->
           (* opam exec -- <server_path>: the server after `--` is the real
              MCP target; a removed build path is the classic stale case. *)
           let target =
             if cmd = "opam" then
               let rec after_sep = function
                 | "--" :: p :: _ -> Some p
                 | _ :: rest -> after_sep rest
                 | [] -> None
               in
               (match after_sep args with Some p -> p | None -> cmd)
             else cmd
           in
           if resolves target then Mcp_ok
           else
             Mcp_stale
               (Printf.sprintf "the c2c MCP command `%s` is not runnable \
                                (missing build path or not on PATH)" target))

(* Resolve a launch command: a path (contains '/') must be an executable regular
   file; a bare name is searched on PATH. Mirrors [resolve_restart_executable]'s
   PATH walk. *)
let command_resolves ?(path = Sys.getenv_opt "PATH") (cmd : string) : bool =
  if String.contains cmd '/' then
    executable_file (if Filename.is_relative cmd then Sys.getcwd () // cmd else cmd)
  else
    match path with
    | None -> false
    | Some value ->
        List.exists
          (fun dir ->
            let dir = if dir = "" then Sys.getcwd () else dir in
            executable_file (dir // cmd))
          (String.split_on_char ':' value)

(* ~/.codex/config.toml, or the C2C_CODEX_CONFIG_PATH override (test seam /
   non-standard CODEX_HOME). *)
let codex_config_path () : string =
  match Sys.getenv_opt "C2C_CODEX_CONFIG_PATH" with
  | Some p when String.trim p <> "" -> p
  | _ -> (Sys.getenv "HOME") // ".codex" // "config.toml"

(* Impure preflight: read the (override-able) codex config and classify its
   [mcp_servers.c2c] block against the real PATH / filesystem. [resolves] is an
   injectable seam for tests. *)
let preflight_codex_mcp_block ?config_path
    ?(resolves = command_resolves ?path:None) () : mcp_block_status =
  let path = match config_path with Some p -> p | None -> codex_config_path () in
  let content =
    if Sys.file_exists path then
      try
        let ic = open_in path in
        Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
            Some (really_input_string ic (in_channel_length ic)))
      with _ -> None
    else None
  in
  classify_codex_mcp_block ~content ~resolves

(* Distinct exit code so a launch aborted by the stale-config preflight is
   distinguishable from a downstream Codex/app-server failure. *)
let codex_mcp_preflight_exit_code = 78

(* Actionable operator repair text for a stale c2c MCP block. Plain text: the
   ANSI color helpers live below this point and are not in scope here. *)
let codex_mcp_preflight_diagnostic (reason : string) : string =
  Printf.sprintf
    "[c2c codex] stale c2c MCP configuration: %s.\n\
     The managed Codex session would launch with a broken c2c MCP server \
     (handshake failure).\n\
     Repair the machine-wide install, then relaunch:\n\
     \n\
    \    c2c install codex --with-mcp\n\
     \n\
     (Set C2C_CODEX_SKIP_MCP_PREFLIGHT=1 to launch anyway.)\n"
    reason

(* --- #27: hook-fallback preflight ----------------------------------------- *)
(* A managed Codex launch defaults to the app-server transport for arrival-time
   delivery; the c2c hook blocks that `c2c install codex` writes into
   ~/.codex/config.toml are the FALLBACK that keeps the session reachable when
   the app-server bridge is unavailable or later drops. When those blocks are
   absent at launch time, the app-server transport is the SOLE delivery path: if
   it goes offline, inbound c2c mail queues silently and the session is never
   woken — exactly the #27 config-drift scenario (managed block removed after
   launch, bridge offline, six messages queued unseen).

   This is NOT a launch blocker: the app-server path is the primary managed path
   and may well be healthy, and on an old codex the fallback IS the primary path
   (so the same warning still applies). It is a WARNING only, mirroring how a
   MISSING (rather than stale) MCP block does not abort the launch. Pure so it is
   unit-testable; [run] wires it as a best-effort stderr note. *)
let codex_hook_fallback_warning ~(hooks_installed : bool) : string option =
  if hooks_installed then None
  else
    Some
      "[c2c codex] no c2c hook fallback is installed (~/.codex/config.toml has \
       no c2c hooks block).\n\
       This managed session will rely on the app-server transport as its ONLY \
       c2c delivery path — if that bridge is unavailable or later goes offline, \
       inbound mail queues silently and the session is NOT woken (#27).\n\
       Install the hook fallback so delivery degrades to the hook boundary \
       instead of going deaf:\n\
       \n\
      \    c2c install codex\n\
       \n\
       (Set C2C_CODEX_SKIP_HOOK_PREFLIGHT=1 to silence this check.)\n"

(* ---------------- B227: resume-thread persistence preflight ---------------- *)

(* Codex persists a resumable session as a rollout file
   ($CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<thread-id>.jsonl) only once
   the thread has actually run. A zero-turn thread — e.g. a managed session
   restarted (restart-stale) before its first message — has NO rollout, so
   `codex resume <id>` hard-fails ("No saved session found") and the relaunched
   supervisor runs degraded with the alias stranded (B227). *)

type thread_persistence = Thread_persisted | Thread_unpersisted | Thread_unknown

let codex_sessions_dir () : string =
  match Sys.getenv_opt "C2C_CODEX_SESSIONS_DIR" with
  | Some p when String.trim p <> "" -> p
  | _ ->
      (match Sys.getenv_opt "CODEX_HOME" with
       | Some h when String.trim h <> "" -> h // "sessions"
       (* An unavailable home directory is scanner uncertainty, not evidence
          that a saved thread is absent.  The empty path below therefore
          classifies as [Thread_unknown] in [thread_rollout_exists]. *)
       | _ ->
           (match Sys.getenv_opt "HOME" with
            | Some h when String.trim h <> "" -> h // ".codex" // "sessions"
            | _ -> ""))

let thread_rollout_exists ~(sessions_dir : string) ~(thread_id : string)
    : thread_persistence =
  (* Rollout filenames end with the thread id: rollout-<ts>-<thread-id>.jsonl.
     Only a completed, readable scan may prove absence.  Any unreadable entry,
     symlink, or depth overflow is uncertainty: it must preserve the resume
     target rather than turn a filesystem problem into a fresh thread. *)
  let suffix = thread_id ^ ".jsonl" in
  let is_rollout_file entry =
    String.starts_with ~prefix:"rollout-" entry
    && String.ends_with ~suffix entry
  in
  let rec scan depth dir =
    if depth > 6 then `Unknown
    else
      match (try Some (Sys.readdir dir) with _ -> None) with
      | None -> `Unknown
      | Some entries ->
          Array.fold_left
            (fun result entry ->
              match result with
              | `Found | `Unknown -> result
              | `Absent ->
                  let path = dir // entry in
                  (match (try Some (Unix.lstat path) with _ -> None) with
                   | None -> `Unknown
                   | Some { Unix.st_kind = Unix.S_REG; _ } ->
                       if is_rollout_file entry then `Found else `Absent
                   | Some { Unix.st_kind = Unix.S_DIR; _ } ->
                       if depth = 6 then `Unknown else scan (depth + 1) path
                   (* Do not follow symlinks: a sessions layout must be fully
                      observable before it can prove a thread absent, and this
                      also makes symlink cycles bounded without traversal. *)
                   | Some { Unix.st_kind = Unix.S_LNK; _ } -> `Unknown
                   | Some _ -> `Absent))
            `Absent entries
  in
  try
    if String.trim thread_id = "" || String.trim sessions_dir = "" then
      Thread_unknown
    else
      (* Resolve the ROOT through symlinks before classifying: profile-share
         setups routinely symlink ~/.codex and ~/.codex/sessions (that is the
         layout the B227 incident machine runs), and an inert preflight there
         would silently reintroduce the bug. Resolution failure (missing path,
         cycle) is uncertainty. Entries INSIDE the resolved tree keep the
         strict no-symlink rule below. *)
      match (try Some (Unix.realpath sessions_dir) with _ -> None) with
      | None -> Thread_unknown
      | Some resolved ->
          (match (try Some (Unix.lstat resolved) with _ -> None) with
           | Some { Unix.st_kind = Unix.S_DIR; _ } ->
               (match scan 0 resolved with
                | `Found -> Thread_persisted
                | `Absent -> Thread_unpersisted
                | `Unknown -> Thread_unknown)
           | _ -> Thread_unknown)
  with _ -> Thread_unknown

let should_preflight_resume_thread ~(backend_is_injected : bool) : bool =
  let explicit_sessions_dir =
    match Sys.getenv_opt "C2C_CODEX_SESSIONS_DIR" with
    | Some p -> String.trim p <> ""
    | None -> false
  in
  Sys.getenv_opt "C2C_CODEX_SKIP_THREAD_PREFLIGHT" <> Some "1"
  && (not backend_is_injected || explicit_sessions_dir)

(* Pure fallback decision (B227): a resume target that is KNOWN-unpersisted is
   dropped so the relaunch starts a FRESH thread on the same alias instead of
   handing `codex resume` a session it never saved. [Thread_unknown] keeps the
   thread — scanner uncertainty (missing/unreadable sessions dir, e.g. a future
   Codex layout change) must never discard genuine resume context. Returns the
   effective thread plus an optional operator log body. *)
let effective_resume_thread
    ~(persistence : string -> thread_persistence)
    (thread : string option) : string option * string option =
  match thread with
  | Some t when String.trim t <> "" ->
      (match persistence t with
       | Thread_unpersisted ->
           ( None,
             Some
               (Printf.sprintf
                  "saved thread %s has no persisted Codex session (a zero-turn \
                   thread is never saved); starting a fresh thread on the same \
                   alias. Set C2C_CODEX_SKIP_THREAD_PREFLIGHT=1 to force the \
                   resume." t) )
       | Thread_persisted | Thread_unknown -> (thread, None))
  | _ -> (thread, None)

(* Resolve the UPGRADE target at request-decision time, not launcher startup:
   `c2c install` may have replaced the PATH binary while this owner kept the old
   executable mapped. Return an absolute, already-validated path so the caller
   can acknowledge safely BEFORE stopping its owned app-server/frontend. *)
let resolve_restart_executable ?(path = Sys.getenv_opt "PATH")
    ?(self = Sys.executable_name) () : string option =
  let absolute_if_executable p =
    let p = if Filename.is_relative p then Filename.concat (Sys.getcwd ()) p else p in
    if executable_file p then Some (try Unix.realpath p with _ -> p) else None
  in
  let from_path () =
    match path with
    | None -> None
    | Some value ->
        let rec find = function
          | [] -> None
          | dir :: rest ->
              let dir = if dir = "" then Sys.getcwd () else dir in
              let candidate = Filename.concat dir "c2c" in
              (match absolute_if_executable candidate with
               | Some _ as found -> found
               | None -> find rest)
        in
        find (String.split_on_char ':' value)
  in
  match from_path () with
  | Some _ as found -> found
  | None -> absolute_if_executable self

let restart_environment () =
  let key e = try String.sub e 0 (String.index e '=') with Not_found -> e in
  C2c_start.filter_env_for_restart ()
  |> Array.to_list
  |> List.filter (fun e -> key e <> "C2C_CODEX_INGRESS_LIVE")
  |> Array.of_list

let mapping_file_matches path (m : mapping) =
  try
    match C2c_io.read_json_opt path with
    | Some (`Assoc fields) ->
        let string_field key =
          match List.assoc_opt key fields with Some (`String s) -> Some s | _ -> None
        in
        string_field "session_id" = Some m.session_id
        && string_field "alias" = Some m.alias
        && string_field "thread_id" = m.thread_id
    | _ -> false
  with _ -> false

(* Mapping writes are ownership records. A successful return therefore means
   both that rename completed and that the replacement can be read back as the
   requested owner/thread. *)
let write_mapping ~instance_dir (m : mapping) : bool =
  let ensure_dir () =
    if Sys.file_exists instance_dir then Sys.is_directory instance_dir
    else (C2c_io.mkdir_p instance_dir; true)
  in
  let fields =
    [ ("session_id", `String m.session_id)
    ; ("alias", `String m.alias)
    ; ("created_at", `Float m.created_at)
    ; ("updated_at", `Float m.updated_at)
    ]
    @ (match m.thread_id with Some t -> [ ("thread_id", `String t) ] | None -> [])
  in
  let path = mapping_path ~instance_dir in
  let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) ^
            "." ^ string_of_int (Random.bits ()) in
  try
    if not (ensure_dir ()) then false
    else begin
      let oc = open_out_gen [ Open_wronly; Open_creat; Open_trunc; Open_text ] 0o600 tmp in
      Fun.protect
        ~finally:(fun () -> try close_out oc with _ -> ())
        (fun () ->
           Yojson.Safe.pretty_to_channel oc (`Assoc fields);
           output_string oc "\n";
           flush oc;
           Unix.fsync (Unix.descr_of_out_channel oc));
      Unix.rename tmp path;
      let dir_fd = Unix.openfile (Filename.dirname path) [ Unix.O_RDONLY ] 0 in
      Fun.protect
        ~finally:(fun () -> try Unix.close dir_fd with _ -> ())
        (fun () -> Unix.fsync dir_fd);
      mapping_file_matches path m
    end
  with _ ->
    (try Sys.remove tmp with _ -> ());
    false

let load_mapping ~instance_dir : mapping option =
  let path = mapping_path ~instance_dir in
  match C2c_io.read_json_opt path with
  | None -> None
  | Some (`Assoc a) ->
      let s k = match List.assoc_opt k a with Some (`String v) -> Some v | _ -> None in
      let f k = match List.assoc_opt k a with
        | Some (`Float v) -> v | Some (`Int i) -> float_of_int i | _ -> 0.0 in
      (match s "session_id", s "alias" with
       | Some session_id, Some alias ->
           Some { session_id; alias; thread_id = s "thread_id";
                  created_at = f "created_at"; updated_at = f "updated_at" }
       | _ -> None)
  | Some _ -> None

type mapping_read_state =
  | Mapping_missing
  | Mapping_loaded of mapping
  | Mapping_unreadable

let load_mapping_state ~instance_dir : mapping_read_state =
  let path = mapping_path ~instance_dir in
  if not (Sys.file_exists path) then Mapping_missing
  else
    match load_mapping ~instance_dir with
    | Some mapping -> Mapping_loaded mapping
    | None -> Mapping_unreadable

(* A B227 fallback can reach the hook-backed launcher before this app-server
   path has written its fresh config/mapping.  Remove the exact dead target from
   the previous managed state first, so that fallback cannot reload it and issue
   the same failing [codex resume].  Both writes are best-effort: failure to
   clear persistence is uncertainty, never a reason to abort the fresh launch. *)
let clear_unpersisted_resume_target ~(name : string) ~(instance_dir : string)
    ~(thread_id : string) : unit =
  (try
     match C2c_start.load_config_opt name with
     | Some cfg when cfg.C2c_start.codex_resume_target = Some thread_id ->
         let resume_session_id =
           if cfg.C2c_start.resume_session_id = thread_id then cfg.session_id
           else cfg.resume_session_id
         in
         C2c_start.write_config
           { cfg with resume_session_id; codex_resume_target = None }
     | _ -> ()
   with _ -> ());
  try
    match load_mapping ~instance_dir with
    | Some mapping when mapping.thread_id = Some thread_id ->
        ignore (write_mapping ~instance_dir
          { mapping with thread_id = None; updated_at = Unix.gettimeofday () })
    | _ -> ()
  with _ -> ()

(* #24 write-side guard: does a DIFFERENT, still-alive managed instance already
   own [thread_id]? Mirrors the [bound_other_thread] predicate shape used by the
   adopt-existing path (c2c_cli_helpers.sole_alive_codex_app_server_session) plus
   a liveness check. Pure read of sibling mappings + broker registry — no
   mutation. A DEAD prior owner returns false (its identity is gone; reclaim it
   freely). This is orthogonal to the "never steal a thread already registered
   by vanilla codex" guard elsewhere: here we only stop two *managed* units from
   both minting a binding for one thread. *)
let live_sibling_owns_thread ~broker_root ~self_name ~thread_id : (bool, unit) result =
  let instances_dir = C2c_mcp_helpers_post_broker.managed_instances_dir () in
  if not (Sys.file_exists instances_dir) then Ok false
  else
    try
      if not (Sys.is_directory instances_dir) then Error ()
      else
        let regs =
          C2c_mcp.Broker.list_registrations
            (C2c_mcp.Broker.create ~root:broker_root)
        in
        let entries = Array.to_list (Sys.readdir instances_dir) in
        let rec check = function
          | [] -> Ok false
          | entry :: rest
            when entry = self_name || entry = ".codex-thread-ownership.lock" ->
              check rest
          | entry :: rest ->
              let dir = Filename.concat instances_dir entry in
              if not (Sys.file_exists dir) then check rest
              else if not (Sys.is_directory dir) then Error ()
              else
                match load_mapping_state ~instance_dir:dir with
                | Mapping_missing -> check rest
                | Mapping_unreadable -> Error ()
                | Mapping_loaded m when m.thread_id <> Some thread_id -> check rest
                | Mapping_loaded m ->
                    (match
                       List.find_opt
                         (fun (r : C2c_mcp.registration) ->
                           r.session_id = m.session_id)
                         regs
                     with
                     | Some r when C2c_mcp.Broker.registration_is_alive r -> Ok true
                     | Some _ | None -> check rest)
        in
        check entries
    with _ -> Error ()

(* Returns [true] when the thread is (or was already) bound to this unit, and
   [false] when persistence was REFUSED because a live managed sibling already
   owns [thread_id] (#24). On refusal this unit stays thread-less and the caller
   records the degraded delivery signal — minting a second binding is exactly
   the split-brain that strands DMs forever. *)
let thread_ownership_lock_path () =
  C2c_mcp_helpers_post_broker.managed_instances_dir () // ".codex-thread-ownership.lock"

let with_thread_ownership_lock f =
  try
    let path = thread_ownership_lock_path () in
    C2c_io.mkdir_p (Filename.dirname path);
    let fd = Unix.openfile path [ Unix.O_CREAT; Unix.O_RDWR ] 0o600 in
    Fun.protect
      ~finally:(fun () -> try Unix.close fd with _ -> ())
      (fun () -> Unix.lockf fd Unix.F_LOCK 0; f ())
  with _ -> false

let persist_discovered_thread_with_hook ~before_mapping_write
    ~instance_dir ~name ~broker_root ~thread_id : bool =
  let repair_config () =
    match C2c_start.load_config_opt name with
    | Some cfg when cfg.codex_resume_target <> Some thread_id
                    || cfg.resume_session_id <> thread_id ->
        C2c_start.write_config
          { cfg with resume_session_id = thread_id;
                     codex_resume_target = Some thread_id }
    | _ -> ()
  in
  (* #31 (nit 2): config.json repair is a SIDE REPAIR, not part of the binding
     verdict. It goes through C2c_start.write_config (mkdir_p + open_out), which
     can raise on ENOSPC/EACCES/EROFS; letting that escape would make the
     deliver loop's fail-closed latch mark a unit permanently degraded even
     though its binding was written correctly. Swallow it here so only genuine
     binding-state uncertainty fails closed. (live_sibling_owns_thread raising
     is deliberately NOT swallowed — that IS binding-state uncertainty.) *)
  let repair_config () = try repair_config () with _ -> () in
  let result = with_thread_ownership_lock (fun () ->
    let mapping_state = load_mapping_state ~instance_dir in
    match mapping_state with
    | Mapping_unreadable -> false
    | Mapping_loaded mapping when mapping.thread_id = Some thread_id -> true
    | (Mapping_missing | Mapping_loaded _) ->
      (match live_sibling_owns_thread ~broker_root ~self_name:name ~thread_id with
       | Error () | Ok true -> false
       | Ok false ->
         match mapping_state with
         | Mapping_loaded m ->
          before_mapping_write ();
          write_mapping ~instance_dir
            { m with thread_id = Some thread_id;
                     updated_at = Unix.gettimeofday () }
         | Mapping_missing ->
          (* A fresh daemon remote TUI has no codex-session.json yet. The
             SessionStart hook is the first trusted observer of its native
             thread, so create the durable mapping from the launcher's already
             persisted config. *)
          (match C2c_start.load_config_opt name with
           | Some cfg when cfg.client = "codex"
                        && String.trim cfg.session_id <> ""
                        && String.trim cfg.alias <> "" ->
               before_mapping_write ();
               write_mapping ~instance_dir
                 { session_id = cfg.session_id; alias = cfg.alias;
                   thread_id = Some thread_id; created_at = cfg.created_at;
                   updated_at = Unix.gettimeofday () }
           | _ -> false)
         | Mapping_unreadable -> false))
  in
  if result then repair_config ();
  result

let persist_discovered_thread ~instance_dir ~name ~broker_root ~thread_id : bool =
  persist_discovered_thread_with_hook ~before_mapping_write:(fun () -> ())
    ~instance_dir ~name ~broker_root ~thread_id

(* --------------------------------- run ------------------------------------ *)

type launch_mode =
  | Start
  | New
  | Resume of string

let use_color () = Sys.getenv_opt "NO_COLOR" = None && Unix.isatty Unix.stderr
let red () = if use_color () then "\027[1;31m" else ""
let yellow () = if use_color () then "\027[1;33m" else ""
let reset () = if use_color () then "\027[0m" else ""

(* B176: every [c2c codex app-server] line gets a local [HH:MM:SS] stamp. *)
let emit_app_server_log (body : string) : unit =
  Printf.eprintf "%s\n%!" (format_app_server_log ~color:(use_color ()) body)

(* A saved alias is "taken" by a DIFFERENT owner when an instance mapping exists
   under that alias whose session seed differs from ours. Used both for the
   collision predicate (fresh derivation) and the --alias conflict check. *)
let mapping_for_alias (alias : string) : mapping option =
  load_mapping ~instance_dir:(C2c_start.instance_dir alias)

let alias_taken_by_other ~(our_session_id : string) (alias : string) : bool =
  match mapping_for_alias alias with
  | Some m -> m.session_id <> our_session_id
  | None ->
      (* Also treat a live managed instance dir with no codex mapping as taken. *)
      Sys.file_exists (C2c_start.config_path alias)

let gen_session_id () =
  Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ())

(* Operator-facing follow-up after a structured app-server startup failure.
   Pure so tests can assert we only suggest "upgrade codex" for real version/
   capability gaps (B175) — not for readiness timeouts or process exits when
   the installed Codex already meets the minimum. *)
let diagnostic_followup (d : C2c_codex_app_server.diagnostic) : string =
  let min_str =
    let (a, b, c) = codex_min_version in Printf.sprintf "%d.%d.%d" a b c
  in
  let version_line =
    match d.C2c_codex_app_server.codex_version, d.C2c_codex_app_server.min_codex_version with
    | Some cur, Some min ->
        Printf.sprintf "  codex version %s; minimum supported for app-server mode is %s.\n" cur min
    | Some cur, None ->
        Printf.sprintf "  codex version %s; minimum supported for app-server mode is %s.\n" cur min_str
    | None, Some min ->
        Printf.sprintf "  minimum supported for app-server mode is %s.\n" min
    | None, None -> ""
  in
  let advice =
    match d.C2c_codex_app_server.code with
    | C2c_codex_app_server.Codex_version_unsupported
    | C2c_codex_app_server.Codex_capability_unsupported
    | C2c_codex_app_server.Codex_not_found ->
        Printf.sprintf
          "  falling back to the hook-backed Codex launch automatically. To get\n\
          \  arrival-time app-server delivery, upgrade codex (>= %s) and relaunch.\n"
          min_str
    | C2c_codex_app_server.Readiness_timeout ->
        "  falling back to the hook-backed Codex launch automatically. The installed\n\
        \  Codex meets the version gate; this was a readiness timeout (slow cold start\n\
        \  or hung app-server). Retry, raise C2C_CODEX_APP_SERVER_READINESS_TIMEOUT_S,\n\
        \  or inspect the app-server log path in the message above.\n"
    | C2c_codex_app_server.Server_died_before_ready ->
        "  falling back to the hook-backed Codex launch automatically. The installed\n\
        \  Codex meets the version gate; the app-server process exited before it was\n\
        \  ready. Inspect the exit status and app-server log in the message above.\n"
    | _ ->
        "  falling back to the hook-backed Codex launch automatically. The installed\n\
        \  Codex version is not the issue — see the diagnostic code/message above.\n\
        \  After fixing the failure, relaunch for arrival-time app-server delivery.\n"
  in
  version_line ^ advice

(* Print T002's structured diagnostic in an operator-actionable form and point
   at the hook fallback. B176: first line uses emit_app_server_log timestamps. *)
let report_diagnostic (d : C2c_codex_app_server.diagnostic) : unit =
  let j = C2c_codex_app_server.diagnostic_to_json d in
  emit_app_server_log (Printf.sprintf "startup failed: %s" d.C2c_codex_app_server.message);
  Printf.eprintf "%s" (diagnostic_followup d);
  Printf.eprintf "  diagnostic: %s\n%!" (Yojson.Safe.to_string j)

type resolved = {
  r_name : string;          (* managed instance key (== alias) *)
  r_session_id : string;    (* stable identity seed *)
  r_alias : string;         (* published/routing alias *)
  r_thread_id : string option;
}

(* Pure identity resolution. [lookup] returns the saved mapping for an alias and
   [config_exists] reports whether a non-app-server managed instance owns it —
   both injected so this is unit-testable without touching the filesystem, and
   returns a [result] (the CLI layer decides how to surface an [Error]). *)
let resolve_identity ~(mode : launch_mode) ~(alias_override : string option)
    ~(thread_id : string option) ~(lookup : string -> mapping option)
    ~(config_exists : string -> bool) : (resolved, string) result =
  let taken_by_other ~our_session_id a =
    match lookup a with
    | Some m -> m.session_id <> our_session_id
    | None -> config_exists a
  in
  let fresh_sid () =
    match thread_id with Some t when String.trim t <> "" -> t | _ -> gen_session_id ()
  in
  let mk name sid alias th = Ok { r_name = name; r_session_id = sid; r_alias = alias; r_thread_id = th } in
  let from_saved (m : mapping) =
    let alias_res =
      match alias_override with
      | Some a when a <> m.alias ->
          if taken_by_other ~our_session_id:m.session_id a then
            Error (Printf.sprintf "--alias %s is already owned by a different session." a)
          else Ok a
      | _ -> Ok m.alias
    in
    match alias_res, reconcile_thread ~requested:thread_id ~saved:m.thread_id with
    | Error e, _ | _, Error e -> Error e
    | Ok alias, Ok th -> mk alias m.session_id alias th
  in
  match mode with
  | Resume alias -> (
      match lookup alias with
      | Some m -> from_saved m
      | None ->
          Error (Printf.sprintf
            "no saved codex app-server session for alias '%s'. \
             Start one with `c2c codex --alias %s` or `c2c new codex`." alias alias))
  | Start -> (
      (* Existing `start` semantics: resume the saved instance only when it is
         explicitly selected (an --alias naming an existing mapping). *)
      match alias_override with
      | Some a -> (
          match lookup a with
          | Some m -> from_saved m
          | None ->
              if config_exists a then
                Error (Printf.sprintf
                  "alias '%s' is already owned by a non-app-server managed instance." a)
              else let sid = fresh_sid () in mk a sid a thread_id)
      | None ->
          let sid = fresh_sid () in
          let alias = derive_alias ~session_id:sid ~taken:(taken_by_other ~our_session_id:sid) in
          mk alias sid alias thread_id)
  | New ->
      (* Always a fresh identity — never resume, even if --alias names a saved
         mapping (that is a conflict). *)
      let sid = fresh_sid () in
      (match alias_override with
       | Some a ->
           if taken_by_other ~our_session_id:sid a then
             Error (Printf.sprintf
               "--alias %s is already owned by a different session; \
                `new` refuses to reuse it." a)
           else mk a sid a thread_id
       | None ->
           let alias = derive_alias ~session_id:sid ~taken:(taken_by_other ~our_session_id:sid) in
           mk alias sid alias thread_id)

(* Read the (possibly None) thread id off a live handle via its persisted view. *)
let handle_thread (h : C2c_codex_app_server.handle) : string option =
  (C2c_codex_app_server.persisted_of h).C2c_codex_app_server.thread_id

(* B131: append a structured, secret-free deliver-pass metric line to the
   instance's delivery log (JSONL). The T007 pass_outcome JSON contains NO body,
   NO credential, NO composer state (redacted recipient only). *)
let log_deliver_pass ~(instance_dir : string) (po : C2c_codex_autoturn.pass_outcome) : unit =
  try
    let path = instance_dir // "codex-deliver.log" in
    let line =
      `Assoc [ ("ts", `Float (Unix.gettimeofday ()));
               ("pass", C2c_codex_autoturn.pass_outcome_to_json po) ]
      |> Yojson.Safe.to_string
    in
    C2c_io.append_jsonl path line
  with _ -> ()

(* Drive the B131 delivery loop for a live, attached app-server session. Wires
   the C2c_codex_deliver_loop seams to the real ingress/turn clients + broker,
   installs SIGTERM/SIGINT teardown, and returns the terminal supervision
   result. Registration lifetime is bound to the loop (register on entry,
   deregister in the loop's finally + the signal path). *)
let register_managed_app_server_identity ~(broker_root : string)
    ~(session_id : string) ~(alias : string) ~(pid : int) : unit =
  (* Publish as soon as the authenticated app-server unit is running.  The
     remote frontend's first hook must find this exact row before it processes
     a user turn; otherwise it creates a second identity and its inbox is not
     the one watched by the delivery loop (B167). *)
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  C2c_mcp.Broker.register broker ~session_id ~alias
    ~pid:(Some pid)
    ~pid_start_time:(C2c_mcp.Broker.read_pid_start_time pid)
    ~client_type:(Some "codex-app-server") ~from_auto_gen:true ()

let run_delivery_loop ~(handle : C2c_codex_app_server.handle) ~(name : string)
    ~(session_id : string) ~(alias : string) ~(instance_dir : string)
    ~(cleanup_failed : bool ref)
    : C2c_codex_deliver_loop.outcome =
  (* Unlock the real WS clients in THIS launcher process only (the frontend was
     already spawned with its env captured, so this does not leak into it). *)
  Unix.putenv "C2C_CODEX_INGRESS_LIVE" "1";
  let broker_root = try C2c_start.broker_root () with _ -> "" in
  (* B138: the delivery-status record is stamped with THIS unit's generation id
     so a stale record from a prior run on a reused instance dir is never
     trusted. *)
  let unit_id = C2c_codex_app_server.unit_id_of handle in
  let endpoint = C2c_codex_app_server.endpoint_of handle in
  let token_provider () =
    match C2c_codex_app_server.raw_token_of handle with "" -> None | t -> Some t
  in
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let turn_client = C2c_codex_autoturn.real_turn_client () in
  let my_pid = Unix.getpid () in
  let my_pid_start_time = C2c_mcp.Broker.read_pid_start_time my_pid in
  let remove_outer_records () =
    match my_pid_start_time with
    | Some start_time ->
        C2c_start.remove_pid_record_pair_confirmed
          ~pid_path:(C2c_start.outer_pid_path name)
          ~start_time_path:(C2c_start.outer_pid_start_time_path name)
          ~pid:my_pid ~start_time
    | None -> false
  in
  let register () =
    (* The remote frontend receives [session_id] in C2C_MCP_SESSION_ID.  The
       broker row and delivery loop must use that same id: using the managed
       instance [name] here made the advertised alias unreachable to the
       frontend hook, which then minted a second identity (B167). *)
    register_managed_app_server_identity ~broker_root ~session_id ~alias
      ~pid:my_pid;
    (* Swarm onboarding parity: join the social room like other managed sessions. *)
    (let rooms =
       C2c_swarm_config.swarm_config_social_room ()
       |> String.split_on_char ',' |> List.map String.trim |> List.filter ((<>) "")
     in
     List.iter
       (fun room_id ->
         try ignore (C2c_mcp.Broker.join_room broker ~room_id ~alias ~session_id)
         with _ -> ())
       rooms)
  in
  let deregistered = ref false in
  let registered = ref false in
  let deregister () =
    if !deregistered then true
    else
      let ok =
        try
          C2c_start.clear_registration_pid_if_owner ~broker_root ~session_id
            ~pid:my_pid ~pid_start_time:my_pid_start_time
        with _ -> false
      in
      if ok then deregistered := true else cleanup_failed := true;
      ok
  in
  let deps : C2c_codex_deliver_loop.deps =
    { broker_root;
      session_id;
      managed_identity = alias;
      endpoint;
      token_provider;
      inject_client = C2c_codex_ingress.real_client ();
      turn_client;
      discover_threads =
        (fun () ->
          match token_provider () with
          | None -> []
          | Some token -> C2c_codex_ingress.real_loaded_threads ~endpoint ~token);
      supervise_step = (fun () -> C2c_codex_app_server.supervise_step handle);
      session_active =
        (fun () -> C2c_codex_app_server.current_state handle = C2c_codex_app_server.Running);
      is_dnd = (fun () -> try C2c_mcp.Broker.is_dnd broker ~session_id with _ -> false);
      register = (fun () -> register (); registered := true);
      deregister = (fun () -> ignore (deregister ()));
      on_pass =
        (* Collapse runs of identical passes into a single log line — log only
           when the structured outcome CHANGES. An idle session polls once/sec and
           each idle pass returns the same benign outcome; logging every one grows
           codex-deliver.log unbounded (~86k lines/day). Dedup-on-change keeps
           every state transition while dropping the steady-state repeats.
           (po_injected_count is a session cumulative, so it cannot be used as a
           per-pass "did work" signal — hence compare the whole outcome.)
           B131 review (2026-07-12). *)
        (let last_pass = ref "" in
         fun po ->
           (* Exclude continuously-growing age from the dedup key (B168) so an
              idle session with a stuck eligible message does not log every
              poll; state transitions still log. *)
           let key =
             match C2c_codex_autoturn.pass_outcome_to_json po with
             | `Assoc fields ->
                 Yojson.Safe.to_string
                   (`Assoc
                      (List.filter
                         (fun (k, _) -> k <> "oldest_eligible_age_s")
                         fields))
             | j -> Yojson.Safe.to_string j
           in
           if key <> !last_pass then begin
             last_pass := key;
             log_deliver_pass ~instance_dir po
           end);
      on_degraded =
        (* B138: persist the deliver-loop degraded signal (stamped with the
           attached unit_id) so `c2c doctor`/`c2c health` can read it. Fired true
           at loop start, false once a frontend thread loads. Best-effort —
           write_delivery_degraded never raises.
           #31: [binding_refused] discriminates the two degraded shapes so
           doctor/health can give the right remediation — a refused binding
           HAS a loaded thread, so "open a thread" would be unfollowable. *)
        (fun ~degraded ~binding_refused ->
          let reason = if binding_refused then Dr_binding_refused else Dr_no_thread in
          write_delivery_degraded ~reason ~instance_dir ~unit_id degraded);
      on_thread_discovered =
        (fun thread_id ->
          (* Independent from mapping freshness: an earlier launch can already
             have persisted the thread in codex-session.json while config.json
             still lacks the restart target. Repair each durable surface on
             its own predicate. #24: refuses (returns false) when a live managed
             sibling already owns this thread — do not mint a second binding;
             instead record the degraded delivery signal for doctor/health.
             #31: the verdict is also RETURNED to the deliver loop, which
             latches it so the following (and every subsequent heartbeat)
             degraded stamp cannot overwrite this refusal with [false]. *)
          let persisted =
            persist_discovered_thread ~instance_dir ~name ~broker_root ~thread_id
          in
          if not persisted then
            write_delivery_degraded ~reason:Dr_binding_refused ~instance_dir
              ~unit_id true;
          persisted);
      restart_requested =
        (fun ~thread_id ->
          match consume_restart_request ~instance_dir with
          | None -> None
          | Some req when req.rr_force ->
              (match resolve_restart_executable () with
               | None ->
                   write_restart_result ~instance_dir ~request_id:req.rr_id
                     ~result:"skipped-executable-unavailable";
                   None
               | Some exe ->
                   write_restart_result ~instance_dir ~request_id:req.rr_id
                     ~result:"restarting";
                   Some exe)
          | Some req ->
              (match token_provider () with
               | None ->
                   write_restart_result ~instance_dir ~request_id:req.rr_id
                     ~result:"skipped-unknown";
                   emit_app_server_log "restart skipped: app-server status unknown";
                   None
               | Some token ->
                   match turn_client.C2c_codex_autoturn.thread_status
                           ~endpoint ~token ~thread_id with
                   | `Idle ->
                       (match resolve_restart_executable () with
                        | None ->
                            write_restart_result ~instance_dir ~request_id:req.rr_id
                              ~result:"skipped-executable-unavailable";
                            None
                        | Some exe ->
                            write_restart_result ~instance_dir ~request_id:req.rr_id
                              ~result:"restarting";
                            Some exe)
                   | status ->
                       write_restart_result ~instance_dir ~request_id:req.rr_id
                         ~result:(match status with `Active -> "skipped-active" | _ -> "skipped-unknown");
                       emit_app_server_log
                         (Printf.sprintf "restart skipped: thread is %s (use --force to override)"
                            (C2c_codex_autoturn.thread_status_to_string status));
                       None));
      global_broker_root =
        (* B141: cross-repo (sessions-broker) mail for this session is
           delivered by the loop's inject-only global pass. None when the
           rendezvous root can't resolve — global delivery just stays off. *)
        (try Some (C2c_repo_fp.resolve_sessions_broker_root ()) with _ -> None);
      on_global_pass =
        (* Same dedup-on-change policy as on_pass: an idle session's global
           pass returns the same health snapshot every second. *)
        (let last_global = ref "" in
         fun gh ->
           let key =
             (* Exclude the continuously-growing pending ages from the dedup
                key — a stuck-pending message would otherwise produce a new
                "changed" snapshot (and a log line) every pass. *)
             Yojson.Safe.to_string
               (match C2c_codex_ingress.health_to_json gh with
                | `Assoc fields ->
                    `Assoc
                      (List.filter
                         (fun (k, _) ->
                            k <> "oldest_pending_age_s"
                            && k <> "stale_forced_count")
                         fields)
                | j -> j)
           in
           if key <> !last_global then begin
             last_global := key;
             try
               let line =
                 `Assoc [ ("ts", `Float (Unix.gettimeofday ()));
                          ("global_pass", C2c_codex_ingress.health_to_json gh) ]
                 |> Yojson.Safe.to_string
               in
               C2c_io.append_jsonl (instance_dir // "codex-deliver.log") line
             with _ -> ()
           end);
      on_ingress_health =
        (fun health ->
          match health.C2c_codex_ingress.last_error with
          | Some "fallback:unsupported" ->
              ignore
                (C2c_start.mark_codex_hook_fallback ~broker_root ~session_id)
          | _ -> ());
      stop_requested = (fun () -> false);
      now = Unix.gettimeofday;
      sleep = (fun s -> try Unix.sleepf s with _ -> ());
      poll_interval_s = 1.0;
      discover_interval_s = 2.0;
      max_wall_s = infinity }
  in
  (* Hard-termination path: a SIGTERM/SIGINT to the launcher must reap the
     app-server unit AND clear the registration (Fun.protect finally does not run
     on exit). Idempotent with the loop's own deregister. *)
  let prev_term = Sys.signal Sys.sigterm (Sys.Signal_handle (fun _ ->
      (try C2c_codex_app_server.stop handle with _ -> ());
      let ok = !registered && deregister () in
      let records_removed = ok && remove_outer_records () in
      exit (if records_removed then 0 else 1))) in
  let prev_int = Sys.signal Sys.sigint (Sys.Signal_handle (fun _ ->
      (try C2c_codex_app_server.stop handle with _ -> ());
      let ok = !registered && deregister () in
      let records_removed = ok && remove_outer_records () in
      exit (if records_removed then 0 else 1))) in
  let restore () =
    (try Sys.set_signal Sys.sigterm prev_term with _ -> ());
    (try Sys.set_signal Sys.sigint prev_int with _ -> ())
  in
  Fun.protect ~finally:restore (fun () ->
      let o =
        try C2c_codex_deliver_loop.run deps with e ->
          (try C2c_codex_app_server.stop handle with _ -> ());
          if !registered && deregister () then begin
            if not (remove_outer_records ()) then cleanup_failed := true
          end else if not !registered then begin
            (* Registration itself failed or was never confirmed.  Preserve
               the outer generation records for retry/recovery. *)
            cleanup_failed := true
          end;
          raise e
      in
      (* #31: the two degraded shapes are operationally different — say which
         one happened. Claiming "no frontend thread was ever loaded" for a
         binding-refused run is simply false: a thread loaded and mail WAS
         injected into it; what failed is the durable binding. *)
      if o.C2c_codex_deliver_loop.degraded then
        emit_app_server_log
          (if o.C2c_codex_deliver_loop.binding_refused then
             Printf.sprintf
               "delivery loop ran DEGRADED: a live managed sibling already owns \
                the discovered thread, so this unit's durable thread binding was \
                REFUSED (#24 split-brain guard). Mail was injected into the \
                discovered thread this session, but the binding is not recorded \
                and will not survive a restart — resolve the sibling instance \
                (`c2c dev instances`). c2c-alias=%s"
               alias
           else
             Printf.sprintf
               "delivery loop ran DEGRADED: no frontend thread was ever loaded, \
                so c2c mail was not auto-delivered this session (session was \
                still supervised). c2c-alias=%s"
               alias);
      o)

(* Read the exact native thread handoff emitted by the daemon frontend's
   SessionStart hook. The parent PID and its kernel start-time generation bind
   the payload to this launch's frontend; a mere membership in
   thread/loaded/list is insufficient under concurrent TUIs. *)
let daemon_thread_handoff_matches ~path ~frontend_pid : string option =
  match C2c_start.read_regular_file_nofollow path with
  | C2c_start.Regular_file_contents contents ->
    (try
    match Yojson.Safe.from_string contents with
    | `Assoc fields ->
        let string_field key =
          match List.assoc_opt key fields with
          | Some (`String s) when String.trim s <> "" -> Some (String.trim s)
          | _ -> None
        in
        let int_field key =
          match List.assoc_opt key fields with
          | Some (`Int n) -> Some n
          | _ -> None
        in
        (match string_field "thread_id", int_field "parent_pid",
               int_field "parent_pid_start_time",
               C2c_mcp.Broker.read_pid_start_time frontend_pid with
         | Some thread_id, Some parent_pid, Some expected, Some actual
           when parent_pid = frontend_pid && expected = actual -> Some thread_id
         | _ -> None)
    | _ -> None
    with _ -> None)
  | C2c_start.Regular_file_missing
  | C2c_start.Regular_file_unreadable _ -> None

let run_daemon_attach ~name ~session_id ~alias ~thread ~yolo ~extra_args
    ~model_override ~instance_dir:_ () : int =
  match C2c_codex_daemon_sidecar.default_control_socket () with
  | None -> 1
  | Some sock ->
      (match C2c_codex_daemon_sidecar.unix_endpoint sock with
       | None -> 1
       | Some ep ->
           (* A bare Codex [--remote] TUI starts a fresh native thread when it
              receives an empty prompt. Starting that thread through the
              daemon first is insufficient: [thread/start] creates an
              in-memory thread with no rollout, and [codex resume] rejects it
              until the TUI has written the empty rollout. The frontend's
              SessionStart hook supplies the native thread id and its exact
              parent PID; loaded-list membership is only a final liveness check. *)
           (try Unix.putenv "C2C_CODEX_INGRESS_LIVE" "1" with _ -> ());
           let fresh = Option.is_none thread in
           (* Codex rejects permission/model overrides on [resume ... --remote],
              so strip them from an existing-thread frontend while preserving
              unrelated passthrough flags. Fresh TUI startup receives them. *)
           let rec drop_options = function
             | [] -> []
             | x :: xs when x = "--dangerously-bypass-approvals-and-sandbox" ->
                 drop_options xs
             | x :: _v :: xs when x = "--sandbox" || x = "-s" || x = "--model" || x = "-m" ->
                 drop_options xs
             | x :: xs when List.exists (fun n -> String.length x > String.length n
                                      && String.sub x 0 (String.length n + 1) = n ^ "=")
                           [ "--sandbox"; "--model" ] ->
                 drop_options xs
             | x :: xs -> x :: drop_options xs
           in
           let frontend_extra = drop_options extra_args in
           let remote = C2c_codex_app_server.endpoint_uri ep in
           let bin =
             match Sys.getenv_opt "C2C_CODEX_BIN" with
             | Some b when String.trim b <> "" -> String.trim b
             | _ -> "codex"
           in
           let model_args =
             match model_override with
             | Some m when String.trim m <> "" -> [ "--model"; m ]
             | _ -> []
           in
           let fresh_frontend_extra =
             frontend_extra_args ~yolo ~extra:(model_args @ extra_args)
           in
           let frontend_extra = if fresh then fresh_frontend_extra else frontend_extra in
           let cwd = try Unix.realpath (Sys.getcwd ()) with _ -> Sys.getcwd () in
           let loaded_before =
             C2c_codex_ingress.real_loaded_threads ~endpoint:ep ~token:""
           in
           let argv_list =
             let cmd =
               match thread with
               | Some t when String.trim t <> "" -> [ bin; "resume"; t ]
               | _ -> [ bin ]
             in
             cmd @ daemon_frontend_workspace_args ~cwd @ [ "--remote"; remote ]
             @ frontend_extra
             @ if fresh then [ "" ] else []
           in
           let argv = Array.of_list argv_list in
           let handoff_path = C2c_start.codex_daemon_thread_handoff_path name in
           C2c_start.remove_pidfile handoff_path;
           let env = child_env
               ((daemon_frontend_env ~session_id ~alias ~instance_name:name)
                @ [ "C2C_CODEX_THREAD_HANDOFF_PATH=" ^ handoff_path ]) in
           let terminal = capture_terminal_foreground () in
           emit_app_server_log
             (Printf.sprintf "daemon attach %s (c2c-alias=%s)" remote alias);
           let now = Unix.gettimeofday () in
           let created_at =
             match C2c_start.load_config_opt name with
             | Some c -> c.C2c_start.created_at
             | None -> now
           in
           C2c_start.write_config
             { C2c_start.name; client = "codex"; session_id;
               resume_session_id = Option.value thread ~default:session_id;
               codex_resume_target = thread; alias; extra_args; created_at;
               last_launch_at = Some now; last_exit_code = None;
               last_exit_reason = None;
               broker_root = (try C2c_start.broker_root () with _ -> "");
               auto_join_rooms = C2c_swarm_config.swarm_config_social_room ();
               binary_override = None; model_override; agent_name = None };
           C2c_start.write_pid_generation
             ~pid_path:(C2c_start.outer_pid_path name)
             ~start_time_path:(C2c_start.outer_pid_start_time_path name)
             (Unix.getpid ());
           let outer_pid = Unix.getpid () in
           let outer_pid_start_time = C2c_mcp.Broker.read_pid_start_time outer_pid in
           let registration_ok =
             try
               register_managed_app_server_identity
                 ~broker_root:(C2c_start.broker_root ()) ~session_id ~alias
                 ~pid:outer_pid;
               true
             with e ->
               emit_app_server_log
                 (Printf.sprintf
                    "daemon attach registration failed for %s: %s; frontend not started"
                    alias (Printexc.to_string e));
               false
           in
           if not registration_ok then begin
             (* Registration is the durable owner handoff.  If it was not
                confirmed, retain the lifecycle records so recovery can
                inspect and retry this exact launch instead of erasing its
                ownership evidence. *)
             emit_app_server_log
               (Printf.sprintf
                  "retaining lifecycle records for failed registration %s"
                  alias);
             1
           end else begin
           let sidecar_lease = ref None in
           let frontend_pid = ref None in
           let frontend_pid_start_time = ref None in
           let frontend_sentinel = ref None in
           let teardown_record =
             C2c_start.instance_dir name // "frontend-teardown.json"
           in
           let write_teardown_record () =
             match !frontend_pid with
             | None -> ()
             | Some pid ->
                 let start_time = C2c_mcp.Broker.read_pid_start_time pid in
                 let sentinel =
                   match !frontend_sentinel with
                   | Some (p, Some st) ->
                       [ ("sentinel_pid", `Int p)
                       ; ("sentinel_start_time", `Int st) ]
                   | _ -> []
                 in
                 (match
                    C2c_io.write_file_atomic ~perm:0o600 teardown_record
                      (Yojson.Safe.to_string
                         (`Assoc
                           ([ ("frontend_pid", `Int pid)
                            ; ("frontend_pid_start_time",
                               match start_time with Some n -> `Int n | None -> `Null) ]
                            @ sentinel)) ^ "\n")
                  with
                  | Ok () -> ()
                  | Error reason ->
                      failwith
                        ("Codex frontend teardown record could not be published: "
                         ^ reason))
           in
           let cleaned = ref false in
           let stop_sidecar () =
             (* Stop through the lease owner path. It revalidates the sidecar's
                recorded PID generation before ever signaling a numeric PID. *)
             let ok =
               match !sidecar_lease with
               | Some lease ->
                   (try
                      C2c_codex_daemon_sidecar.stop_lease
                        ~owners_dir:(C2c_codex_daemon_sidecar.default_owners_dir ())
                        lease
                    with _ -> false)
               | None ->
                   (try
                      C2c_codex_daemon_sidecar.stop_for_session
                        ~owners_dir:(C2c_codex_daemon_sidecar.default_owners_dir ())
                        ~broker_session_id:session_id
                    with _ -> false)
             in
             if ok then sidecar_lease := None;
             ok
           in
           let cleanup () =
             if !cleaned then true
             else begin
               let frontend_ok =
                 match !frontend_pid with
                 | Some child ->
                     (try
                        match !frontend_sentinel with
                        | Some (sentinel, Some start_time) ->
                            stop_frontend_process ~sentinel_pid:sentinel
                              ~sentinel_start_time:start_time child
                        | _ ->
                            (match !frontend_pid_start_time with
                             | Some start_time ->
                                 stop_frontend_process
                                   ~owner_start_time:start_time child
                             | None -> false)
                      with _ -> false)
                 | None -> true
               in
               (* Reclaim the terminal even when ownership teardown failed, but
                  retain the generation-bound record, broker registration, and
                  outer pidfile so c2c stop can retry/report honestly. *)
               restore_terminal_foreground terminal;
               let sidecar_ok = if frontend_ok then stop_sidecar () else false in
               let teardown_record_removed =
                 frontend_ok && sidecar_ok
                 && C2c_start.remove_pidfile_confirmed teardown_record
               in
               let registration_cleared =
                 teardown_record_removed
                 && (try
                       C2c_start.clear_registration_pid_if_owner
                         ~broker_root:(C2c_start.broker_root ()) ~session_id
                         ~pid:outer_pid ~pid_start_time:outer_pid_start_time
                     with _ -> false)
               in
               if not frontend_ok || not sidecar_ok || not teardown_record_removed
                  || not registration_cleared then begin
                 Printf.eprintf
                   "c2c codex: frontend cleanup is incomplete; retaining %s for retry\n%!"
                   teardown_record;
                 false
               end else begin
                 let outer_pidfiles_removed =
                   C2c_start.remove_pidfile_confirmed (C2c_start.outer_pid_path name)
                   && C2c_start.remove_pidfile_confirmed
                        (C2c_start.outer_pid_start_time_path name)
                 in
                 if outer_pidfiles_removed then begin
                   cleaned := true;
                   frontend_pid := None;
                   true
                 end else begin
                   Printf.eprintf
                     "c2c codex: outer pidfile cleanup is incomplete; retaining state for retry\n%!";
                   false
                 end
               end
             end
           in
           let prev_term = Sys.signal Sys.sigterm (Sys.Signal_handle (fun _ ->
               if cleanup () then exit 0 else ())) in
           let prev_int = Sys.signal Sys.sigint (Sys.Signal_handle (fun _ ->
               if cleanup () then exit 0 else ())) in
           let restore_signals () =
             (try Sys.set_signal Sys.sigterm prev_term with _ -> ());
             (try Sys.set_signal Sys.sigint prev_int with _ -> ())
           in
           let child =
             try
               spawn_frontend_process ~bin ~argv ~env ~terminal
                 ~on_parent_fork:(fun pid ->
                   frontend_pid := Some pid;
                   frontend_pid_start_time :=
                     C2c_mcp.Broker.read_pid_start_time pid;
                   write_teardown_record ())
                 ~on_sentinel:(fun owner ->
                   frontend_sentinel := Some owner;
                   write_teardown_record ())
             with e ->
               restore_signals ();
               if cleanup () then raise e
               else begin
                 (* The first publication may itself have failed. Retry the
                    exact-generation cleanup synchronously and make one best
                    effort to publish a receipt before refusing to return. *)
                 (try write_teardown_record () with _ -> ());
                 let rec retry attempts =
                   if cleanup () then true
                   else if attempts = 0 then false
                   else (Unix.sleepf 0.05; retry (attempts - 1))
                 in
                 if retry 40 then raise e
                 else
                   raise
                     (Failure
                        (Printf.sprintf
                           "Codex frontend startup failed and exact frontend cleanup could not be confirmed: %s"
                           (Printexc.to_string e)))
               end
           in
           Fun.protect
             ~finally:(fun () ->
               restore_signals ();
               ignore (cleanup ()))
             (fun () ->
                 let bound_thread =
                  match thread with
                  | Some tid -> Some tid
                  | None ->
                      let deadline = Unix.gettimeofday () +. 30.0 in
                      let rec discover () =
                        let loaded_for_cwd =
                          C2c_codex_ingress.real_loaded_threads_for_cwd
                            ~endpoint:ep ~token:"" ~cwd
                        in
                        match select_new_loaded_thread
                                ~before:loaded_before ~candidates:loaded_for_cwd with
                        | Some tid -> Some tid
                        | _ ->
                            (match
                               daemon_thread_handoff_matches ~path:handoff_path
                                 ~frontend_pid:child
                             with
                             | Some tid
                               when List.mem tid
                                      (C2c_codex_ingress.real_loaded_threads
                                         ~endpoint:ep ~token:"" ) -> Some tid
                             | _ when Unix.gettimeofday () < deadline ->
                                 Unix.sleepf 0.2;
                                 discover ()
                             | _ -> None)
                      in
                      discover ()
                in
                match bound_thread with
                | None ->
                    emit_app_server_log
                      (Printf.sprintf
                         "daemon attach failed: fresh remote TUI did not expose a \
                          loaded thread (c2c-alias=%s)" alias);
                    ignore (cleanup ());
                    1
                | Some tid ->
                    let persisted =
                      persist_discovered_thread
                        ~instance_dir:(C2c_start.instance_dir name)
                        ~name
                        ~broker_root:(try C2c_start.broker_root () with _ -> "")
                        ~thread_id:tid
                    in
                    if not persisted then begin
                      emit_app_server_log
                        (Printf.sprintf
                           "daemon attach failed: durable thread ownership could not be persisted (c2c-alias=%s)"
                           alias);
                      ignore (cleanup ());
                      1
                    end else
                    let armed =
                      try
                        match
                          C2c_codex_daemon_sidecar.arm ~instance_name:name ~thread_id:tid ~alias
                            ~broker_session_id:session_id
                            ~broker_root:(try C2c_start.broker_root () with _ -> "")
                            ()
                        with
                        | C2c_codex_daemon_sidecar.Armed { child_pid = _ } ->
                            sidecar_lease :=
                              C2c_codex_daemon_sidecar.peek
                                ~owners_dir:(C2c_codex_daemon_sidecar.default_owners_dir ())
                                ~socket_identity:ep.host ~thread_id:tid;
                            true
                        | C2c_codex_daemon_sidecar.Already_running l
                          when l.broker_session_id = session_id ->
                            sidecar_lease := Some l;
                            true
                        | C2c_codex_daemon_sidecar.Already_running _
                        | C2c_codex_daemon_sidecar.Claim_held _
                        | C2c_codex_daemon_sidecar.Socket_unavailable -> false
                        | C2c_codex_daemon_sidecar.Arm_failed reason ->
                            emit_app_server_log
                              (Printf.sprintf "daemon sidecar arm failed: %s" reason);
                            false
                        | C2c_codex_daemon_sidecar.Arm_failed_ownership_retained reason ->
                            emit_app_server_log
                              (Printf.sprintf
                                 "daemon sidecar arm retained ownership; fallback disabled: %s"
                                 reason);
                            false
                      with e ->
                        emit_app_server_log
                          (Printf.sprintf "daemon sidecar arm failed: %s"
                             (Printexc.to_string e));
                        false
                    in
                    if not armed then begin
                      ignore (cleanup ());
                      1
                    end else begin
                    C2c_start.write_config
                      { C2c_start.name; client = "codex"; session_id;
                        resume_session_id = tid; codex_resume_target = Some tid;
                        alias; extra_args; created_at; last_launch_at = Some now;
                        last_exit_code = None; last_exit_reason = None;
                        broker_root = (try C2c_start.broker_root () with _ -> "");
                        auto_join_rooms = C2c_swarm_config.swarm_config_social_room ();
                        binary_override = None; model_override; agent_name = None };
                    let exit_code = wait_child child in
                    exit_code
                    end)
           end)

let run_app_server ~(mode : launch_mode) ~(alias_override : string option)
    ~(thread_id : string option) ~(yolo : bool) ~(extra_args : string list)
    ?(model_override : string option)
    ?(backend : C2c_codex_app_server.backend option)
    ~(fallback : extra_args:string list -> unit -> int) () : int =
  let (name, session_id, alias, thread) =
    match resolve_identity ~mode ~alias_override ~thread_id
            ~lookup:mapping_for_alias
            ~config_exists:(fun a -> Sys.file_exists (C2c_start.config_path a)) with
    | Ok r -> (r.r_name, r.r_session_id, r.r_alias, r.r_thread_id)
    | Error msg -> Printf.eprintf "%serror:%s %s\n%!" (red ()) (reset ()) msg; exit 1
  in
  (* #34 review (fix 1): [resolve_identity] only guards a saved codex mapping
     ([lookup]) and a managed-instance config ([config_exists]). It is blind to a
     plain broker registry row — i.e. every MCP-registered vanilla Claude Code /
     hook-codex / relay peer, which is the common case. Without this precheck,
     `c2c start codex -n <live-peer-alias>` sails through and the refusal only
     lands inside [C2c_mcp.Broker.register] far below, AFTER write_config, the
     outer pidfile, the app-server and the TUI spawn — leaving an orphaned codex
     frontend with no broker row and a poisoned instance dir. Refuse here, before
     any side effect, while the terminal is still ours. *)
  (match (try Some (C2c_start.broker_root ()) with _ -> None) with
   | Some root when String.trim root <> "" ->
       C2c_start.check_registry_alias_alive ~broker_root:root ~name:alias
   | _ -> ());
  (* B227: a thread id survives in mappings/configs/restart requests even when
     Codex never persisted that thread (a zero-turn session writes no rollout).
     Resuming it hard-fails the frontend ("No saved session found") and strands
     the alias in a degraded relaunch — so preflight persistence and fall back
     to a fresh thread on the same alias. Scripted tests (injected [backend])
     skip the scan to stay hermetic UNLESS they opt in via the
     C2C_CODEX_SESSIONS_DIR seam; C2C_CODEX_SKIP_THREAD_PREFLIGHT=1 is the
     operator escape (mirrors the B224 preflight gates). *)
  let thread, discarded_thread =
    if not (should_preflight_resume_thread
              ~backend_is_injected:(Option.is_some backend)) then
      (thread, None)
    else begin
      let effective, log_body =
        effective_resume_thread
          ~persistence:(fun t ->
            thread_rollout_exists ~sessions_dir:(codex_sessions_dir ())
              ~thread_id:t)
          thread
      in
      (match log_body with Some body -> emit_app_server_log body | None -> ());
      let discarded =
        match thread, effective with
        | Some original, None when String.trim original <> "" -> Some original
        | _ -> None
      in
      (effective, discarded)
    end
  in
  let instance_dir = C2c_start.instance_dir name in
  (try C2c_io.mkdir_p instance_dir with _ -> ());
  (* Prefer the machine daemon only when its owner-bound cleanup prerequisites
     are available: the launcher has an exact PID generation and pidfd
     signalling. The launcher then attaches the TUI and arms the sidecar after
     discovering its exact native thread. Injected [backend] stays on the
     private-server path so hermetic tests do not touch the live daemon. *)
  if backend = None && daemon_attach_available () then
    run_daemon_attach ~name ~session_id ~alias ~thread ~yolo ~extra_args
      ~model_override ~instance_dir ()
  else begin
  (match discarded_thread with
   | Some dead_thread ->
       clear_unpersisted_resume_target ~name ~instance_dir ~thread_id:dead_thread
   | None -> ());
  if yolo then Printf.eprintf "%s%s%s\n%!" (yellow ()) yolo_warning (reset ());
  let model_args =
    match model_override with
    | Some m when String.trim m <> "" -> [ "--model"; m ]
    | _ -> []
  in
  let cfg =
    let base = C2c_codex_app_server.default_config
                 ~instance_name:name ~instance_dir ~cwd:(Sys.getcwd ()) in
    { base with
      C2c_codex_app_server.alias = Some alias;
      min_codex_version = codex_min_version;
      extra_frontend_args =
        frontend_extra_args ~yolo ~extra:(model_args @ extra_args);
      frontend_env = app_server_frontend_env ~session_id ~alias;
      resume_thread = thread;
      (* B176: progressive lifecycle feedback during (possibly slow) start.
         Bodies are pure helpers; emit_app_server_log stamps [HH:MM:SS] + paints
         the label. Phases fire inside start() at the true transition points so
         "ready" appears before the TUI owns the terminal. *)
      lifecycle_log =
        (function
         | C2c_codex_app_server.Launching ->
             emit_app_server_log (lifecycle_launching_body ~alias)
         | C2c_codex_app_server.Ready endpoint ->
             emit_app_server_log (lifecycle_ready_body ~endpoint)
         | C2c_codex_app_server.Tui_handoff endpoint ->
             (* Preserve B159 multi-segment color on the handoff body when the
                terminal supports it; label still painted by emit_app_server_log. *)
             emit_app_server_log
               (startup_banner ~color:(use_color ()) ~alias ~endpoint)) }
  in
  (* B166/B137: the remote frontend receives the launcher session id BEFORE it
     starts. Hooks adopt that identity and bare `c2c init` reuses its alias;
     the launcher owns registration/delivery, so neither path mints a second
     per-thread identity. [frontend_env] is child-scoped, so hook fallback and
     unrelated children never inherit this marker. *)
  (* IMPORTANT: no routable alias is published before start succeeds — a version
     or capability failure returns a diagnostic here, before any registration. *)
  let start cfg = match backend with
    | Some bk -> C2c_codex_app_server.start ~backend:bk cfg
    | None -> C2c_codex_app_server.start cfg
  in
  match start cfg with
  | Error diag ->
      (* No routable identity was persisted (start failed before Running), so
         nothing to clean up here. Best-effort remove the empty instance dir we
         created above so a fallback launch doesn't inherit a stray dir. *)
      (try if Sys.readdir instance_dir = [||] then Unix.rmdir instance_dir with _ -> ());
      report_diagnostic diag;
      (* Graceful fallback to the hook-backed launch (AC7). Do NOT forward
         session identity; the hook path owns its own alias handling. *)
      fallback ~extra_args:(hook_fallback_extra_args ~yolo ~extra:extra_args
                              ~codex_version:diag.C2c_codex_app_server.codex_version) ()
  | Ok handle ->
      (* B153: app-server launchers are first-class managed instances. Persist
         the same config/pid surfaces used by instances/restart, but keep the
         launcher itself as the outer process so its controlling TTY is never
         transferred to an unrelated caller. *)
      let now = Unix.gettimeofday () in
      let created_at =
        match C2c_start.load_config_opt name with
        | Some c -> c.C2c_start.created_at
        | None -> now
      in
      C2c_start.write_config
        { C2c_start.name; client = "codex"; session_id;
          resume_session_id = Option.value thread ~default:session_id;
          codex_resume_target = thread; alias; extra_args; created_at;
          last_launch_at = Some now; last_exit_code = None;
          last_exit_reason = None;
          broker_root = (try C2c_start.broker_root () with _ -> "");
          auto_join_rooms = C2c_swarm_config.swarm_config_social_room ();
          binary_override = None; model_override; agent_name = None };
           C2c_start.write_pid_generation
             ~pid_path:(C2c_start.outer_pid_path name)
             ~start_time_path:(C2c_start.outer_pid_start_time_path name)
             (Unix.getpid ());
      (* B138: the instant the unit is up (and therefore observable as
         online-attached by doctor/health), synchronously publish a fail-closed
         degraded record STAMPED with this unit's generation id — before the
         mapping is written and before the async deliver loop's first pass. This
         overwrites any stale [degraded=false] left by a prior healthy run on a
         reused instance dir, so there is no window in which doctor/health see a
         previous run's healthy signal for this new, no-thread-yet session. The
         deliver loop flips it to healthy once a frontend thread loads. *)
      (try
         let unit_id = C2c_codex_app_server.unit_id_of handle in
         write_delivery_degraded ~instance_dir ~unit_id true
       with _ -> ());
      (* Session is up and attached. Persist the identity mapping — the
         authoritative alias<->session record that `c2c instances`/status read.
         B131: the derived alias becomes a LIVE, routable broker alias below —
         [run_delivery_loop] registers it into the broker on entry and tears the
         registration down on TUI exit. The mapping persisted here is the durable
         identity record; the broker registration is the in-flight routing entry. *)
      let created =
        match load_mapping ~instance_dir with Some m -> m.created_at | None -> now in
      let mapping_persisted =
        write_mapping ~instance_dir
          { session_id; alias;
            thread_id = (match handle_thread handle with Some t -> Some t | None -> thread);
            created_at = created; updated_at = now }
      in
      if not mapping_persisted then begin
        (* A running private app-server without a durable identity is not a
           managed session: stop it before publishing any broker ownership. *)
        emit_app_server_log
          (Printf.sprintf
             "app-server launch failed: durable identity mapping could not be persisted (c2c-alias=%s)"
             alias);
        (try C2c_codex_app_server.stop handle with _ -> ());
        (match C2c_mcp.Broker.read_pid_start_time (Unix.getpid ()) with
         | Some start_time ->
             if not
                  (C2c_start.remove_pid_record_pair_confirmed
                     ~pid_path:(C2c_start.outer_pid_path name)
                     ~start_time_path:(C2c_start.outer_pid_start_time_path name)
                     ~pid:(Unix.getpid ()) ~start_time) then
               Printf.eprintf
                 "c2c codex: retaining lifecycle records after mapping failure; cleanup was not confirmed\n%!"
         | None ->
             Printf.eprintf
               "c2c codex: retaining lifecycle records after mapping failure; launcher generation unavailable\n%!");
        1
      end else begin
      (* B172: bind the banner alias into the broker before the operator can
         interact (init-equivalent of `c2c init --alias <generated> --no-setup`
         on the launcher session_id).  Do this immediately after start returns
         so first-turn CLI whoami/send resolve the same identity the banner
         prints.  The delivery loop refreshes the same row while attached. *)
      (* #34 review (fix 1, belt-and-braces): the pre-launch precheck above
         closes the realistic race, but [Broker.register] can still refuse
         (someone claimed the alias during startup) and it raises. Uncaught,
         that killed the launcher AFTER the TUI already owned the terminal —
         an orphaned frontend with no broker row and no delivery loop. Never
         let it escape; and because the TUI paints over the terminal, stderr
         alone is not loud (#40's lesson) — record it durably in broker.log. *)
      (try
         register_managed_app_server_identity
           ~broker_root:(C2c_start.broker_root ()) ~session_id ~alias
           ~pid:(Unix.getpid ())
       with e ->
         let detail = Printexc.to_string e in
         Printf.eprintf
           "%swarning:%s c2c could not publish broker alias '%s': %s\n\
            \  This session will NOT receive c2c mail. Exit it and retry with a \
            free alias (`c2c dev instances` / `c2c list`).\n%!"
           (red ()) (reset ()) alias detail;
         (try
            Broker_log.append_json
              ~broker_root:(try C2c_start.broker_root () with _ -> "")
              ~json:(`Assoc
                 [ ("event", `String "managed_registration_failed")
                 ; ("ts", `Float (Unix.gettimeofday ()))
                 ; ("client", `String "codex-app-server")
                 ; ("name", `String name)
                 ; ("session_id", `String session_id)
                 ; ("alias", `String alias)
                 ; ("detail", `String detail) ])
         with _ -> ());
         (try C2c_codex_app_server.stop handle with _ -> ());
         (* Registration was not confirmed.  Keep the outer generation pair
            and all retry metadata until ownership cleanup is proven. *)
         raise (Failure detail));
      (* B176: the pre-TUI handoff line (with alias + endpoint) is emitted inside
         start() via lifecycle_log immediately before spawn_frontend — do not
         reprint a second banner here (avoids duplicate/interleaved TUI noise). *)
      (* B131: drive the proven T003 ingress + T007 auto-turn pipeline against
         THIS live session while the frontend is attached. The loop registers a
         routable broker alias, discovers the frontend's loaded thread, injects
         inbound c2c mail as DATA + auto-turns eligible local mail, and tears the
         registration + loop down on TUI exit. Falls back to plain supervision
         (degraded) if no thread is ever loaded — never crashes the session. *)
      let delivery_cleanup_failed = ref false in
      let outer_pid = Unix.getpid () in
      let outer_pid_start_time = C2c_mcp.Broker.read_pid_start_time outer_pid in
      let remove_outer_records () =
        match outer_pid_start_time with
        | Some start_time ->
            C2c_start.remove_pid_record_pair_confirmed
              ~pid_path:(C2c_start.outer_pid_path name)
              ~start_time_path:(C2c_start.outer_pid_start_time_path name)
              ~pid:outer_pid ~start_time
        | None -> false
      in
      let final =
        run_delivery_loop ~handle ~name ~session_id ~alias ~instance_dir
          ~cleanup_failed:delivery_cleanup_failed
      in
      C2c_codex_app_server.stop handle;
      if not !delivery_cleanup_failed && remove_outer_records () then ()
      else
        Printf.eprintf
          "c2c codex: retaining outer pidfiles because lifecycle cleanup was not confirmed\n%!";
      (* Refresh the mapping's updated_at + thread on clean shutdown. *)
      (match load_mapping ~instance_dir with
       | Some m -> ignore (write_mapping ~instance_dir { m with updated_at = Unix.gettimeofday () })
       | None -> ());
      (match final.C2c_codex_deliver_loop.restart_executable,
             final.C2c_codex_deliver_loop.thread_id with
        | Some executable, Some exact_thread ->
            let argv =
              let passthrough =
                (match model_override with
                 | Some m when String.trim m <> "" -> [ "--model"; m ]
                 | _ -> [])
                @ extra_args
              in
              Array.of_list
                ([ executable; "resume"; "codex"; alias;
                   "--thread-id"; exact_thread ]
                 @ (if passthrough = [] then [] else "--" :: passthrough))
            in
            emit_app_server_log
              (Printf.sprintf "restarting in place on thread %s" exact_thread);
            Unix.execve argv.(0) argv (restart_environment ())
        | _ -> ());
      (match final.C2c_codex_deliver_loop.final with
       | C2c_codex_app_server.Sv_server_died ->
           emit_app_server_log "app-server died; session torn down.";
           1
       | _ -> 0)
      end
  end

(* The emergency hook-backed route bypasses [run_app_server], but it is still a
   real Codex launch.  For the two modes that can reuse an existing managed
   alias, give its saved target the same B227 preflight before the fallback
   reloads it through [C2c_start.cmd_start].  [New] always asks that fallback
   for a fresh session, while [Start] without an explicit alias has no saved
   instance selected. *)
let preflight_hook_fallback_resume_target ~(mode : launch_mode)
    ~(alias_override : string option) : unit =
  if not (should_preflight_resume_thread ~backend_is_injected:false) then ()
  else
    let name =
      match mode with
      | Resume alias -> Some alias
      | Start -> alias_override
      | New -> None
    in
    match name with
    | None -> ()
    | Some name ->
        (match C2c_start.load_config_opt name with
         | Some cfg ->
             (match cfg.C2c_start.codex_resume_target with
              | Some thread_id when String.trim thread_id <> "" ->
                  let effective, log_body =
                    effective_resume_thread
                      ~persistence:(fun t ->
                        thread_rollout_exists ~sessions_dir:(codex_sessions_dir ())
                          ~thread_id:t)
                      (Some thread_id)
                  in
                  (match effective, log_body with
                   | None, Some body ->
                       emit_app_server_log body;
                       clear_unpersisted_resume_target
                         ~name ~instance_dir:(C2c_start.instance_dir name)
                         ~thread_id
                   | _ -> ())
              | _ -> ())
         | None -> ())

let run ~(mode : launch_mode) ?(alias_override : string option)
    ?(thread_id : string option) ~(yolo : bool)
    ~(extra_args : string list) ?(model_override : string option)
    ?(backend : C2c_codex_app_server.backend option)
    ~(fallback : extra_args:string list -> unit -> int) () : int =
  (* B136: hook fallback still needs this inherited non-secret marker so its
     hooks suppress the vanilla app-server tip.  The app-server path uses the
     frontend-only environment assembled above, avoiding a launcher-env leak. *)
  (try Unix.putenv "C2C_CODEX_MANAGED" "1" with _ -> ());
  (* B224: preflight the machine-wide [mcp_servers.c2c] block before launching a
     real Codex. A stale block (removed opam build path / c2c-mcp-server off
     PATH) would otherwise drop the operator into a broken managed session with
     a failed MCP handshake. Only gate genuine launches: an injected [backend]
     means a scripted test with no real Codex reading the real config, so the
     check would be non-hermetic (it would read the host's live config) and is
     skipped. C2C_CODEX_SKIP_MCP_PREFLIGHT=1 is the operator escape. A MISSING
     block is not the failure mode (Codex simply launches without c2c tools), so
     only [Mcp_stale] blocks the launch. *)
  let skip_preflight =
    match Sys.getenv_opt "C2C_CODEX_SKIP_MCP_PREFLIGHT" with Some "1" -> true | _ -> false
  in
  let preflight_block =
    if backend = None && not skip_preflight then
      match preflight_codex_mcp_block () with
      | Mcp_stale reason ->
          Printf.eprintf "%s%!" (codex_mcp_preflight_diagnostic reason);
          Some codex_mcp_preflight_exit_code
      | Mcp_ok | Mcp_missing -> None
    else None
  in
  match preflight_block with
  | Some rc -> rc
  | None ->
    (* #27: warn (never abort) when a real managed launch has NO hook fallback,
       so the operator can restore it before the app-server bridge becomes a
       single point of silent-deaf failure. Only genuine launches are checked
       (an injected [backend] is a hermetic test with no real config), reading
       the same config the MCP preflight did (honours C2C_CODEX_CONFIG_PATH). A
       read error fails quiet (assume installed) rather than nagging spuriously.
       Suppressible with C2C_CODEX_SKIP_HOOK_PREFLIGHT=1. *)
    (if backend = None
        && Sys.getenv_opt "C2C_CODEX_SKIP_HOOK_PREFLIGHT" <> Some "1"
     then
       let hooks_installed =
         try C2c_start.codex_hooks_installed ~config_path:(codex_config_path ()) ()
         with _ -> true
       in
       match codex_hook_fallback_warning ~hooks_installed with
       | Some msg -> Printf.eprintf "%s%!" msg
       | None -> ());
    (* B131 / coordinator directive: the app-server transport is the DEFAULT and
       ONLY managed codex path for a supported codex. Unsupported codex (<0.144)
       or a genuine app-server startup failure returns a structured diagnostic
       from [run_app_server], which then falls back to the hook-backed launch
       automatically — hooks are the fallback, never a user-selectable mode. The
       hidden [C2C_CODEX_FORCE_HOOKS=1] escape skips the app-server path entirely
       (operator testing / emergency only; not a user-facing option). *)
    let force_hooks =
      match Sys.getenv_opt "C2C_CODEX_FORCE_HOOKS" with Some "1" -> true | _ -> false
    in
    if force_hooks then begin
      if backend = None then
        preflight_hook_fallback_resume_target ~mode ~alias_override;
      fallback ~extra_args:(frontend_extra_args ~yolo ~extra:extra_args) ()
    end
    else
      run_app_server ~mode ~alias_override ~thread_id ~yolo ~extra_args
        ?model_override ?backend ~fallback ()
