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

let app_server_log_label = "[c2c codex app-server]"

let online_attached_log_body ~(alias : string) ~(endpoint : string) : string =
  Printf.sprintf "online-attached: c2c-alias=%s endpoint=%s" alias endpoint

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

(* Best-effort persist of the deliver-loop degraded signal, stamped with the
   attached unit's [unit_id]. [degraded] = true means the app-server unit is
   supervised but no thread was discovered to inject into. Written fail-closed
   (true) at session start + loop start, flipped to false once a thread loads.
   Never raises (delivery health must never wedge the session). *)
let write_delivery_degraded ~instance_dir ~(unit_id : string) (degraded : bool) : unit =
  try
    (try if not (Sys.file_exists instance_dir) then C2c_io.mkdir_p instance_dir
     with _ -> ());
    let path = delivery_status_path ~instance_dir in
    let j =
      `Assoc [ ("unit_id", `String unit_id);
               ("degraded", `Bool degraded);
               ("thread_loaded", `Bool (not degraded));
               ("updated_at", `Float (Unix.gettimeofday ())) ]
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
let delivery_degraded_of_instance ~(instance_dir : string) ~(unit_id : string)
    : bool option =
  match C2c_io.read_json_opt (delivery_status_path ~instance_dir) with
  | Some (`Assoc a) ->
      let unit_matches =
        match List.assoc_opt "unit_id" a with
        | Some (`String u) -> u = unit_id
        | _ -> false
      in
      if not unit_matches then None
      else (match List.assoc_opt "degraded" a with Some (`Bool b) -> Some b | _ -> None)
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
let online_attached_delivery_degraded ~(instance_dir : string) : bool =
  match C2c_codex_app_server.load_persisted ~instance_dir with
  | Some p ->
      (match
         delivery_degraded_of_instance ~instance_dir
           ~unit_id:p.C2c_codex_app_server.unit_id
       with
       | Some b -> b
       | None -> true)
  | None -> true

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

let request_restart ~instance_dir ~(force : bool) : unit =
  let path = restart_request_path ~instance_dir in
  let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
  let oc = open_out tmp in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
      Yojson.Safe.to_channel oc
        (`Assoc [ ("force", `Bool force);
                  ("requested_at", `Float (Unix.gettimeofday ())) ]);
      output_string oc "\n");
  Unix.rename tmp path

let consume_restart_request ~instance_dir : bool option =
  let path = restart_request_path ~instance_dir in
  match C2c_io.read_json_opt path with
  | None -> None
  | Some (`Assoc fields) ->
      (try Sys.remove path with _ -> ());
      Some (match List.assoc_opt "force" fields with Some (`Bool b) -> b | _ -> false)
  | Some _ -> (try Sys.remove path with _ -> ()); Some false

let write_mapping ~instance_dir (m : mapping) : unit =
  (try if not (Sys.file_exists instance_dir) then C2c_io.mkdir_p instance_dir
   with _ -> ());
  let fields =
    [ ("session_id", `String m.session_id)
    ; ("alias", `String m.alias)
    ; ("created_at", `Float m.created_at)
    ; ("updated_at", `Float m.updated_at)
    ]
    @ (match m.thread_id with Some t -> [ ("thread_id", `String t) ] | None -> [])
  in
  let path = mapping_path ~instance_dir in
  let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
  let oc = open_out tmp in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () -> Yojson.Safe.pretty_to_channel oc (`Assoc fields); output_string oc "\n");
  (try Unix.rename tmp path with _ -> ())

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

(* --------------------------------- run ------------------------------------ *)

type launch_mode =
  | Start
  | New
  | Resume of string

let use_color () = Unix.isatty Unix.stderr
let red () = if use_color () then "\027[1;31m" else ""
let yellow () = if use_color () then "\027[1;33m" else ""
let reset () = if use_color () then "\027[0m" else ""

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

(* Print T002's structured diagnostic in an operator-actionable form and point
   at the hook fallback. *)
let report_diagnostic (d : C2c_codex_app_server.diagnostic) : unit =
  let j = C2c_codex_app_server.diagnostic_to_json d in
  Printf.eprintf "%s%s%s startup failed: %s\n"
    (yellow ()) app_server_log_label (reset ())
    d.C2c_codex_app_server.message;
  (match d.C2c_codex_app_server.codex_version, d.C2c_codex_app_server.min_codex_version with
   | Some cur, Some min ->
       Printf.eprintf "  codex version %s; minimum supported for app-server mode is %s.\n" cur min
   | _ -> ());
  Printf.eprintf "  falling back to the hook-backed Codex launch automatically. To get\n\
                 \  arrival-time app-server delivery, upgrade codex (>= %s) and relaunch.\n"
    (let (a, b, c) = codex_min_version in Printf.sprintf "%d.%d.%d" a b c);
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
let run_delivery_loop ~(handle : C2c_codex_app_server.handle) ~(name : string)
    ~(alias : string) ~(instance_dir : string) : C2c_codex_deliver_loop.outcome =
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
  let register () =
    (try
       C2c_mcp.Broker.register broker ~session_id:name ~alias
         ~pid:(Some my_pid)
         ~pid_start_time:(C2c_mcp.Broker.read_pid_start_time my_pid)
         ~client_type:(Some "codex-app-server") ()
     with _ -> ());
    (* Swarm onboarding parity: join the social room like other managed sessions. *)
    (let rooms =
       C2c_swarm_config.swarm_config_social_room ()
       |> String.split_on_char ',' |> List.map String.trim |> List.filter ((<>) "")
     in
     List.iter
       (fun room_id ->
         try ignore (C2c_mcp.Broker.join_room broker ~room_id ~alias ~session_id:name)
         with _ -> ())
       rooms)
  in
  let deregistered = ref false in
  let deregister () =
    if not !deregistered then begin
      deregistered := true;
      (try C2c_start.clear_registration_pid ~broker_root ~session_id:name with _ -> ())
    end
  in
  let deps : C2c_codex_deliver_loop.deps =
    { broker_root;
      session_id = name;
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
      is_dnd = (fun () -> try C2c_mcp.Broker.is_dnd broker ~session_id:name with _ -> false);
      register;
      deregister;
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
           let key =
             Yojson.Safe.to_string (C2c_codex_autoturn.pass_outcome_to_json po)
           in
           if key <> !last_pass then begin
             last_pass := key;
             log_deliver_pass ~instance_dir po
           end);
      on_degraded =
        (* B138: persist the deliver-loop degraded signal (stamped with the
           attached unit_id) so `c2c doctor`/`c2c health` can read it. Fired true
           at loop start, false once a frontend thread loads. Best-effort —
           write_delivery_degraded never raises. *)
        (fun degraded -> write_delivery_degraded ~instance_dir ~unit_id degraded);
      on_thread_discovered =
        (fun thread_id ->
          match load_mapping ~instance_dir with
          | Some m when m.thread_id <> Some thread_id ->
              write_mapping ~instance_dir
                { m with thread_id = Some thread_id;
                         updated_at = Unix.gettimeofday () };
              (match C2c_start.load_config_opt name with
               | Some cfg ->
                   C2c_start.write_config
                     { cfg with resume_session_id = thread_id;
                                codex_resume_target = Some thread_id }
               | None -> ())
          | _ -> ());
      restart_requested =
        (fun ~thread_id ->
          match consume_restart_request ~instance_dir with
          | None -> false
          | Some true -> true
          | Some false ->
              (match token_provider () with
               | None ->
                   Printf.eprintf "%s restart skipped: app-server status unknown\n%!"
                     app_server_log_label;
                   false
               | Some token ->
                   match turn_client.C2c_codex_autoturn.thread_status
                           ~endpoint ~token ~thread_id with
                   | `Idle -> true
                   | status ->
                       Printf.eprintf "%s restart skipped: thread is %s (use --force to override)\n%!"
                         app_server_log_label
                         (C2c_codex_autoturn.thread_status_to_string status);
                       false));
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
             (* Exclude the continuously-growing pending age from the dedup
                key — a stuck-pending message would otherwise produce a new
                "changed" snapshot (and a log line) every pass. *)
             Yojson.Safe.to_string
               (match C2c_codex_ingress.health_to_json gh with
                | `Assoc fields ->
                    `Assoc
                      (List.filter
                         (fun (k, _) -> k <> "oldest_pending_age_s")
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
      (try C2c_codex_app_server.stop handle with _ -> ()); deregister (); exit 0)) in
  let prev_int = Sys.signal Sys.sigint (Sys.Signal_handle (fun _ ->
      (try C2c_codex_app_server.stop handle with _ -> ()); deregister (); exit 0)) in
  let restore () =
    (try Sys.set_signal Sys.sigterm prev_term with _ -> ());
    (try Sys.set_signal Sys.sigint prev_int with _ -> ())
  in
  Fun.protect ~finally:restore (fun () ->
      let o = C2c_codex_deliver_loop.run deps in
      if o.C2c_codex_deliver_loop.degraded then
        Printf.eprintf
          "%s%s%s delivery loop ran DEGRADED: no frontend thread \
           was ever loaded, so c2c mail was not auto-delivered this session \
           (session was still supervised). c2c-alias=%s\n%!"
          (yellow ()) app_server_log_label (reset ()) alias;
      o)

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
  let instance_dir = C2c_start.instance_dir name in
  (try C2c_io.mkdir_p instance_dir with _ -> ());
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
        frontend_extra_args ~yolo ~extra:(model_args @ extra_args) }
  in
  (* B137: hand this managed app-server session's broker session id to the hooks
     the stock frontend will fire. [build_frontend_env] snapshots
     [Unix.environment ()], so exporting here — BEFORE [start] spawns the
     frontend — makes every hook that frontend fires inherit the marker. The
     hook adopts it as its identity (the app-server deliver loop owns this
     session's registration + delivery) instead of self-registering a SECOND
     per-thread identity. [name] is exactly the session id [run_delivery_loop]
     registers under. Reset on the fallback path below so a hook-fallback launch
     never inherits it (there the hook owns registration/delivery itself). *)
  (try Unix.putenv "C2C_CODEX_APPSERVER_SESSION" name with _ -> ());
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
      (* B137: clear the app-server identity marker before falling back to the
         hook path — the fallback child re-snapshots the env, and a stale marker
         would make its hook abstain from the registration/delivery it now owns.
         Unix has no unsetenv; an empty value reads as unset (hooks trim-guard). *)
      (try Unix.putenv "C2C_CODEX_APPSERVER_SESSION" "" with _ -> ());
      (try if Sys.readdir instance_dir = [||] then Unix.rmdir instance_dir with _ -> ());
      report_diagnostic diag;
      (* Graceful fallback to the hook-backed launch (AC7). Do NOT forward
         session identity; the hook path owns its own alias handling. *)
      fallback ~extra_args:(frontend_extra_args ~yolo ~extra:extra_args) ()
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
      let pid_oc = open_out (C2c_start.outer_pid_path name) in
      Fun.protect ~finally:(fun () -> close_out pid_oc)
        (fun () -> Printf.fprintf pid_oc "%d\n" (Unix.getpid ()); flush pid_oc);
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
      write_mapping ~instance_dir
        { session_id; alias;
          thread_id = (match handle_thread handle with Some t -> Some t | None -> thread);
          created_at = created; updated_at = now };
      let endpoint =
        C2c_codex_app_server.endpoint_uri
          (C2c_codex_app_server.endpoint_of handle)
      in
      Printf.eprintf "%s%s%s %s\n%!"
        (yellow ()) app_server_log_label (reset ())
        (online_attached_log_body ~alias ~endpoint);
      (* B131: drive the proven T003 ingress + T007 auto-turn pipeline against
         THIS live session while the frontend is attached. The loop registers a
         routable broker alias, discovers the frontend's loaded thread, injects
         inbound c2c mail as DATA + auto-turns eligible local mail, and tears the
         registration + loop down on TUI exit. Falls back to plain supervision
         (degraded) if no thread is ever loaded — never crashes the session. *)
      let final =
        run_delivery_loop ~handle ~name ~alias ~instance_dir
      in
      C2c_codex_app_server.stop handle;
      (* Refresh the mapping's updated_at + thread on clean shutdown. *)
      (match load_mapping ~instance_dir with
       | Some m -> write_mapping ~instance_dir { m with updated_at = Unix.gettimeofday () }
       | None -> ());
      if final.C2c_codex_deliver_loop.restart_requested then begin
        match final.C2c_codex_deliver_loop.thread_id with
        | Some exact_thread ->
            let argv =
              Array.of_list
                ([ Sys.executable_name; "resume"; "codex"; alias;
                   "--thread-id"; exact_thread ]
                 @ (match model_override with
                    | Some m when String.trim m <> "" -> [ "--model"; m ]
                    | _ -> [])
                 @ (if extra_args = [] then [] else "--" :: extra_args))
            in
            Printf.eprintf "%s restarting in place on thread %s\n%!"
              app_server_log_label exact_thread;
            Unix.execve argv.(0) argv (Unix.environment ())
        | None -> ()
      end;
      (match final.C2c_codex_deliver_loop.final with
       | C2c_codex_app_server.Sv_server_died ->
           Printf.eprintf "%s%s%s app-server died; session torn down.\n%!"
             (yellow ()) app_server_log_label (reset ());
           1
       | _ -> 0)

let run ~(mode : launch_mode) ?(alias_override : string option)
    ?(thread_id : string option) ~(yolo : bool)
    ~(extra_args : string list) ?(model_override : string option)
    ?(backend : C2c_codex_app_server.backend option)
    ~(fallback : extra_args:string list -> unit -> int) () : int =
  (* B136: publish an inherited, non-secret marker so hooks fired BY a managed
     codex session (the app-server frontend/core OR the hook-fallback child) can
     detect they are managed and suppress the vanilla "use `c2c new codex`"
     app-server nudge. Set here — before any codex child is spawned (both the
     app-server path's frontend/server env and the hook-fallback child's env are
     snapshots of [Unix.environment ()] taken later) — because
     [C2C_CODEX_INGRESS_LIVE] is exported only AFTER the frontend spawns (in
     [run_delivery_loop]) and so never reaches those hooks. The nudge's
     [codex_session_is_managed] gate reads this. *)
  (try Unix.putenv "C2C_CODEX_MANAGED" "1" with _ -> ());
  (* B131 / coordinator directive: the app-server transport is the DEFAULT and
     ONLY managed codex path for a supported codex. Unsupported codex (<0.144) or
     a genuine app-server startup failure returns a structured diagnostic from
     [run_app_server], which then falls back to the hook-backed launch
     automatically — hooks are the fallback, never a user-selectable mode. The
     hidden [C2C_CODEX_FORCE_HOOKS=1] escape skips the app-server path entirely
     (operator testing / emergency only; not a user-facing option). *)
  let force_hooks =
    match Sys.getenv_opt "C2C_CODEX_FORCE_HOOKS" with Some "1" -> true | _ -> false
  in
  if force_hooks then
    fallback ~extra_args:(frontend_extra_args ~yolo ~extra:extra_args) ()
  else
    run_app_server ~mode ~alias_override ~thread_id ~yolo ~extra_args
      ?model_override ?backend ~fallback ()
