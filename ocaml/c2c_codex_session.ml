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
  Printf.sprintf "%s-%s" words.(i1) words.(i2)

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

(* --------------------------- identity mapping ----------------------------- *)

type mapping = {
  session_id : string;
  alias : string;
  thread_id : string option;
  created_at : float;
  updated_at : float;
}

let mapping_path ~instance_dir = instance_dir // "codex-session.json"

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
  Printf.eprintf "%s[codex app-server]%s startup failed: %s\n"
    (yellow ()) (reset ()) d.C2c_codex_app_server.message;
  (match d.C2c_codex_app_server.codex_version, d.C2c_codex_app_server.min_codex_version with
   | Some cur, Some min ->
       Printf.eprintf "  codex version %s; minimum supported for app-server mode is %s.\n" cur min
   | _ -> ());
  Printf.eprintf "  falling back to the hook-backed Codex launch. To require app-server mode,\n\
                 \  upgrade codex and retry, or run without --app-server for hooks.\n";
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
      fallback ~extra_args:(frontend_extra_args ~yolo ~extra:extra_args) ()
  | Ok handle ->
      (* Session is up and attached. Persist the identity mapping — the
         authoritative alias<->session record that `c2c instances`/status read.
         NOTE: auto-registering the interactive frontend into the broker under
         this alias needs the codex-hook env threaded into the frontend child at
         spawn time; that managed-env parity is T005's job (T002's frontend-env
         builder only injects the auth token). Until then the derived alias is
         the persisted, discoverable identity, not yet a live broker alias. *)
      let now = Unix.gettimeofday () in
      let created =
        match load_mapping ~instance_dir with Some m -> m.created_at | None -> now in
      write_mapping ~instance_dir
        { session_id; alias;
          thread_id = (match handle_thread handle with Some t -> Some t | None -> thread);
          created_at = created; updated_at = now };
      Printf.eprintf "%s[codex app-server]%s online-attached: alias=%s endpoint=%s\n%!"
        (yellow ()) (reset ()) alias
        (C2c_codex_app_server.endpoint_uri (C2c_codex_app_server.endpoint_of handle));
      let final = C2c_codex_app_server.supervise_until_exit handle in
      C2c_codex_app_server.stop handle;
      (* Refresh the mapping's updated_at + thread on clean shutdown. *)
      (match load_mapping ~instance_dir with
       | Some m -> write_mapping ~instance_dir { m with updated_at = Unix.gettimeofday () }
       | None -> ());
      (match final with
       | C2c_codex_app_server.Sv_server_died ->
           Printf.eprintf "%s[codex app-server]%s app-server died; session torn down.\n%!"
             (yellow ()) (reset ());
           1
       | _ -> 0)

let run ~(mode : launch_mode) ?(alias_override : string option)
    ?(thread_id : string option) ~(yolo : bool) ~(app_server : bool)
    ~(extra_args : string list) ?(model_override : string option)
    ?(backend : C2c_codex_app_server.backend option)
    ~(fallback : extra_args:string list -> unit -> int) () : int =
  let engage =
    app_server || (match Sys.getenv_opt "C2C_CODEX_APP_SERVER" with Some "1" -> true | _ -> false)
  in
  if not engage then
    (* Legacy hook-backed path — the live default. --yolo still forwards the
       bypass flag; it is never persisted (extra_args is not saved on plain
       re-launch, per resolve_effective_extra_args). *)
    fallback ~extra_args:(frontend_extra_args ~yolo ~extra:extra_args) ()
  else
    run_app_server ~mode ~alias_override ~thread_id ~yolo ~extra_args
      ?model_override ?backend ~fallback ()
