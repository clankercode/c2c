(* `c2c t3`: operator CLI and foreground service for one local T3 Code home.

   The command is deliberately a thin adapter over the native client, durable
   state journal and service policy modules.  It never edits T3 state and never
   borrows a provider/native caller credential. *)

open C2c_cli_helpers
open Cmdliner.Term
open Cmdliner.Term.Syntax
open Lwt.Infix

module T3 = C2c_t3_client
module Service = C2c_t3_service
module State = C2c_t3_state
module Recovery = C2c_t3_recovery

let ( // ) = Filename.concat

let getenv_nonempty name =
  match Sys.getenv_opt name with Some value when String.trim value <> "" -> Some (String.trim value) | _ -> None

let home_dir () = Option.value (getenv_nonempty "HOME") ~default:"."
let t3_home () = Option.value (getenv_nonempty "T3CODE_HOME") ~default:(home_dir () // ".t3")
let config_dir () = Option.value (getenv_nonempty "C2C_T3_CONFIG_DIR") ~default:(home_dir () // ".c2c" // "t3")
let state_dir () = Option.value (getenv_nonempty "C2C_T3_STATE_DIR") ~default:(home_dir () // ".local" // "state" // "c2c" // "t3")

let now () = Unix.gettimeofday ()

let service_broker_root () =
  try C2c_repo_fp.resolve_sessions_broker_root () with _ -> resolve_broker_root ()

let run_lwt f =
  try Lwt_main.run f with exn -> Error (Printexc.to_string exn)

let run_t3 f =
  try Lwt_main.run f with exn -> Error (T3.Protocol (Printexc.to_string exn))

let run_lwt_exn f =
  try Lwt_main.run f with exn -> raise exn

let print_error error = Printf.eprintf "error: %s\n%!" error

let string_of_mode = function
  | `Auto -> "auto" | `Queue -> "queue" | `Steer -> "steer" | `Restart -> "restart"

let mode_of_string = function
  | "auto" -> Ok `Auto | "queue" -> Ok `Queue | "steer" -> Ok `Steer | "restart" -> Ok `Restart
  | value -> Error ("unknown delivery mode " ^ value ^ "; use auto, queue, steer, or restart")

let mode_arg =
  Cmdliner.Arg.enum [ ("auto", `Auto); ("queue", `Queue);
                      ("steer", `Steer); ("restart", `Restart) ]

(* See [send_cmd]: this is deliberately process-local rather than persisted.
   The T3 MCP client receives one request per invocation, while the durable
   service dispatcher owns replay identity for background deliveries. *)
let send_request_nonce = ref 0

let as_command term = Cmdliner.Term.(const (fun code -> exit code) $ term)

let t3_binary () =
  match getenv_nonempty "C2C_T3_BIN" with
  | Some path when Filename.is_relative path -> Error "C2C_T3_BIN must be an absolute path"
  | Some path -> Ok path
  | None ->
      let path_entries =
        String.split_on_char ':' (Option.value (Sys.getenv_opt "PATH") ~default:"")
      in
      match List.find_opt (fun dir -> Sys.file_exists (dir // "t3")) path_entries with
      | Some dir -> Ok (dir // "t3")
      | None -> Error "T3 CLI was not found; set C2C_T3_BIN to its absolute path"

let environment_id_of_home home =
  let home = try Unix.realpath home with _ -> home in
  let seed = "t3-home:" ^ home in
  "t3-env-" ^ String.sub (Digestif.SHA256.(to_hex (digest_string seed))) 0 32

let environment_id runtime = environment_id_of_home runtime.T3.t3_home

let authorized ?(rebind = false) () =
  match T3.authorize ~rebind ~config_dir:(config_dir ()) ~t3_home:(t3_home ()) () with
  | Error error -> Error (T3.error_to_string error)
  | Ok (client, runtime) ->
      (match run_t3 (T3.initialize client) with
       | Error error -> Error (T3.error_to_string error)
       | Ok () -> Ok (client, runtime))

let open_state () =
  State.open_state ~environment_id:(environment_id_of_home (t3_home ())) ~dir:(state_dir ()) ()

let with_state f =
  match open_state () with
  | Error error -> print_error (State.open_error_to_string error); 1
  | Ok state -> Fun.protect ~finally:(fun () -> State.close state) (fun () -> f state)

(* Sending is a read-only operation on connector state.  When the foreground
   service owns the singleton lock, use an immutable atomic snapshot instead of
   failing with Already_running; all mutating commands continue to require the
   writer handle above. *)
let with_send_mappings f =
  match open_state () with
  | Ok state ->
      Fun.protect ~finally:(fun () -> State.close state)
        (fun () -> f (State.mappings state))
  | Error State.Already_running ->
      (match
         State.open_read_only
           ~environment_id:(environment_id_of_home (t3_home ())) ~dir:(state_dir ()) ()
       with
       | Error error -> print_error (State.open_error_to_string error); 1
       | Ok snapshot -> f (State.read_only_mappings snapshot))
  | Error error -> print_error (State.open_error_to_string error); 1

let thread_mapping_json mapping =
  `Assoc
    [ ("threadId", `String mapping.State.thread_id);
      ("alias", `String mapping.alias);
      ("createdAt", `Float mapping.created_at);
      ("tombstone", match mapping.tombstone with
       | None -> `Null
       | Some tombstone -> `Assoc [ ("at", `Float tombstone.tombstoned_at); ("reason", `String tombstone.reason) ]) ]

let journal_payload_uncertain = function
  | `Assoc payload ->
      let submission_evidence =
        (match List.assoc_opt "attempts" payload with Some (`Int n) -> n > 0 | _ -> false)
        || List.mem_assoc "last_submission_at" payload
      in
      List.assoc_opt "uncertain" payload = Some (`Bool true)
      || List.assoc_opt "status" payload = Some (`String "uncertain")
      || List.assoc_opt "status" payload = Some (`String "in_flight")
      || (List.assoc_opt "status" payload = Some (`String "held")
          && submission_evidence)
  | _ -> false

let journal_payload_has_error = function
  | `Assoc payload ->
      List.assoc_opt "preflight_failed" payload = Some (`Bool true)
      || (match List.assoc_opt "last_error" payload with
       | Some (`String error) -> error <> ""
       | _ -> false)
  | _ -> false

let state_snapshot () =
  let directory = state_dir () in
  let path = directory // "state.json" in
  if not (Sys.file_exists directory) then
    `Assoc [ ("available", `Bool false); ("reason", `String "state directory is absent") ]
  else
    let private_ok () =
      try
        let st = Unix.lstat directory in
        st.Unix.st_kind = Unix.S_DIR && st.Unix.st_uid = Unix.geteuid ()
        && st.Unix.st_perm land 0o077 = 0
      with _ -> false
    in
    if not (private_ok ()) then
      `Assoc [ ("available", `Bool false); ("reason", `String "state directory ownership or permissions are unsafe") ]
    else if not (Sys.file_exists path) then
      `Assoc [ ("available", `Bool true); ("initialized", `Bool false); ("pending", `Int 0); ("mappings", `Int 0) ]
    else if Result.is_error (State.open_read_only
              ~environment_id:(environment_id_of_home (t3_home ())) ~dir:directory ()) then
      `Assoc [ ("available", `Bool false); ("reason", `String "state validation failed: malformed, foreign or unsafe state is preserved") ]
    else
      try
        let contents = match C2c_t3_systemd.read_owned_regular ~private_mode:true
            ~max_bytes:(128 * 1024 * 1024) path with
          | Ok contents -> contents | Error _ -> failwith "unsafe state snapshot" in
        match Yojson.Safe.from_string contents with
        | `Assoc fields ->
            let list key = match List.assoc_opt key fields with Some (`List values) -> values | _ -> [] in
            let journal = list "journal" in
            let length key = List.length (list key) in
            let oldest_at =
              List.filter_map (fun entry -> match entry with `Assoc values -> (match List.assoc_opt "at" values with Some (`Float at) -> Some at | Some (`Int at) -> Some (float_of_int at) | _ -> None) | _ -> None) journal
              |> List.sort Float.compare |> function [] -> None | value :: _ -> Some value
            in
            let count_payload predicate =
              List.fold_left (fun count entry -> match entry with
                | `Assoc values -> (match List.assoc_opt "payload" values with
                    | Some payload when predicate payload -> count + 1
                    | _ -> count)
                | _ -> count) 0 journal
            in
            let uncertain = count_payload journal_payload_uncertain in
            let retained_errors = count_payload journal_payload_has_error in
            `Assoc [ ("available", `Bool true); ("initialized", `Bool true); ("pending", `Int (length "journal")); ("mappings", `Int (length "mappings")); ("acked", `Int (length "acked")); ("uncertainEntries", `Int uncertain); ("retainedErrorEntries", `Int retained_errors); ("healthy", `Bool (uncertain = 0 && retained_errors = 0)); ("queueAgeSeconds", match oldest_at with Some at -> `Float (max 0. (now () -. at)) | None -> `Null); ("scanAgeSeconds", `Null) ]
        | _ -> `Assoc [ ("available", `Bool false); ("reason", `String "state.json is not an object") ]
      with _ -> `Assoc [ ("available", `Bool false); ("reason", `String "state.json is malformed") ]

let pair_cmd pairing_code replace json =
  match T3.resolve_home () with
  | Error error -> print_error (T3.error_to_string error); 1
  | Ok home ->
      (match T3.discover ~t3_home:home () with
       | Error error -> print_error (T3.error_to_string error); 1
       | Ok runtime ->
           let validate () =
             match T3.discover ~t3_home:home () with
             | Error error -> Error error
             | Ok current when current.origin = runtime.origin && current.proof = runtime.proof -> Ok ()
             | Ok _ -> Error (T3.Runtime_changed "T3 restarted while pairing")
           in
           let code_result =
             match pairing_code with
             | Some code -> Ok code
             | None ->
                 (match t3_binary () with
                  | Error message -> Error (T3.Discovery message)
                  | Ok binary -> run_t3 (T3.create_pairing_code ~runtime ~t3_bin:binary))
           in
           (match code_result with
            | Error error -> print_error (T3.error_to_string error); 1
            | Ok code ->
                (match pairing_code with
                 | None -> Printf.printf "Pairing code: %s\nEnter the code shown in T3 (or pass --pairing-code):\n%!" code
                 | Some _ -> ());
                let code =
                  match pairing_code with
                  | Some code -> code
                  | None ->
                      (try String.trim (input_line stdin) with End_of_file -> "")
                in
                if code = "" then (print_error "pairing code is empty"; 1)
                else
                  match run_t3
                          (T3.pair ~runtime ~validate ~pairing_code:code
                             ~client_name:"c2c-t3-connector" ~config_dir:(config_dir ()) ~replace ()) with
                  | Error error -> print_error (T3.error_to_string error); 1
                  | Ok credential ->
                      if json then
                        print_json (`Assoc [ ("ok", `Bool true); ("configDir", `String (config_dir ())); ("generation", `Int (T3.credential_generation credential)) ])
                      else Printf.printf "Paired with T3 at %s (credential generation %d).\n" runtime.origin (T3.credential_generation credential);
                      0))

let pair_term =
  let pairing_code = Cmdliner.Arg.(value & opt (some string) None & info [ "pairing-code" ] ~docv:"CODE" ~doc:"T3 pairing code. If omitted, create one and prompt for it.") in
  let replace = Cmdliner.Arg.(value & flag & info [ "replace" ] ~doc:"Replace an existing connector credential explicitly.") in
  let json = json_flag in
  as_command (const pair_cmd $ pairing_code $ replace $ json)

let list_cmd json =
  match authorized () with
  | Error error -> print_error error; 1
  | Ok (client, runtime) ->
      (* Listing is read-only.  The foreground service owns the writer lock,
         so read an immutable snapshot while it is running rather than
         reporting [Already_running] to the operator. *)
      with_send_mappings (fun mappings ->
        match run_t3 (Service.discover client) with
        | Error error -> print_error (T3.error_to_string error); 1
        | Ok scan ->
            let broker = C2c_mcp.Broker.create ~root:(service_broker_root ()) in
            let registrations = C2c_mcp.Broker.list_registrations broker in
            let service_registration_for mapping =
              let session_id =
                Service.service_session_id ~environment_id:(environment_id runtime)
                  ~thread_id:mapping.State.thread_id
              in
              List.find_opt
                (fun (registration : C2c_mcp.registration) ->
                  C2c_mcp.Broker.alias_casefold registration.alias
                    = C2c_mcp.Broker.alias_casefold mapping.alias
                  && registration.session_id = session_id
                  && registration.registered_by = Some Service.service_registered_by)
                registrations
            in
            let status_for ~thread ~mapping =
              match mapping with
              | Some mapping when mapping.State.tombstone <> None ->
                  "retired", "thread has a durable tombstone"
              | _ ->
                  (match Service.eligibility ~credential_access:None thread with
                   | Service.Permission_ineligible reason -> "held", reason
                   | Service.Retired reason -> "retired", reason
                   | Service.Routable ->
                       (match mapping with
                        | None -> "held", "thread has not been published by the service"
                        | Some mapping ->
                            (match service_registration_for mapping with
                             | None -> "held", "service registration is absent"
                             | Some registration ->
                                 (match C2c_mcp.Broker.registration_liveness_state registration with
                                  | C2c_mcp.Broker.Alive -> "routable", ""
                                  | C2c_mcp.Broker.Dead -> "stale", "service registration process is not alive"
                                  | C2c_mcp.Broker.Unknown -> "stale", "service registration liveness is unknown"))))
            in
            let row_for_thread thread mapping =
              let status, reason = status_for ~thread ~mapping in
              `Assoc [ ("projectId", `String thread.Service.project_id); ("threadId", `String thread.thread_id);
                       ("title", `String thread.title); ("alias", match mapping with Some m -> `String m.alias | None -> `Null);
                       ("runtimeMode", match thread.runtime_mode with Some s -> `String s | None -> `Null);
                       ("status", `String status); ("statusReason", if reason = "" then `Null else `String reason) ]
            in
            let listed_ids = Hashtbl.create (List.length scan.listed) in
            List.iter (fun thread -> Hashtbl.replace listed_ids thread.Service.thread_id ()) scan.listed;
            let rows =
              List.map
                (fun thread ->
                  let mapping = List.find_opt (fun (m : State.mapping) -> m.thread_id = thread.Service.thread_id) mappings in
                  row_for_thread thread mapping)
                scan.listed
            in
            (* A mapping absent from the latest listing remains visible so
               operators can distinguish a stale route from a retired one. *)
            let missing_rows =
              mappings
              |> List.filter (fun (mapping : State.mapping) -> not (Hashtbl.mem listed_ids mapping.thread_id))
              |> List.map (fun mapping ->
                   let status, reason =
                     match mapping.State.tombstone with
                     | Some tombstone -> "retired", tombstone.reason
                     | None ->
                         "stale",
                         if scan.complete then "thread was absent from the latest complete scan"
                         else "thread was absent from an incomplete scan"
                   in
                   `Assoc [ ("projectId", `String ""); ("threadId", `String mapping.thread_id);
                           ("title", `String ""); ("alias", `String mapping.alias);
                           ("runtimeMode", `Null); ("status", `String status);
                           ("statusReason", `String reason) ])
            in
            let rows = rows @ missing_rows in
            if json then print_json (`Assoc [ ("environmentId", `String (environment_id runtime)); ("complete", `Bool scan.complete); ("errors", `List (List.map (fun e -> `String e) scan.errors)); ("threads", `List rows) ])
            else begin
              List.iter (fun row ->
                match row with
                | `Assoc f ->
                    let get k = match List.assoc_opt k f with Some (`String s) -> s | _ -> "-" in
                    Printf.printf "%-10s  %-36s  %-12s  %s  %s\n" (get "status") (get "alias") (get "threadId") (get "runtimeMode") (get "title")
                | _ -> ()) rows;
              if not scan.complete then Printf.eprintf "warning: discovery incomplete; aliases were not retired.\n%!"
            end;
            0)

let list_term = as_command (const list_cmd $ json_flag)

let status_cmd json =
  let credential =
    match T3.load_credential ~config_dir:(config_dir ()) with
    | Ok value -> `Assoc [ ("present", `Bool true); ("generation", `Int (T3.credential_generation value)); ("scopes", `List (List.map (fun s -> `String s) (T3.credential_scopes value))) ]
    | Error error -> `Assoc [ ("present", `Bool false); ("error", `String (T3.error_to_string error)) ]
  in
  let runtime =
    match T3.discover ~t3_home:(t3_home ()) () with
    | Ok value -> `Assoc [ ("ready", `Bool true); ("origin", `String value.origin); ("pid", `Int value.pid); ("home", `String value.t3_home) ]
    | Error error -> `Assoc [ ("ready", `Bool false); ("error", `String (T3.error_to_string error)) ]
  in
  let state = state_snapshot () in
  let unit = `Assoc [ ("path", `String (C2c_t3_systemd.unit_path ())); ("active", `Bool (C2c_t3_systemd.unit_is_active ())); ("enabled", `Bool (C2c_t3_systemd.unit_is_enabled ())); ("mainPid", match C2c_t3_systemd.unit_main_pid () with Some pid -> `Int pid | None -> `Null) ] in
  let result = `Assoc [ ("configDir", `String (config_dir ())); ("stateDir", `String (state_dir ())); ("credential", credential); ("runtime", runtime); ("state", state); ("unit", unit) ] in
  if json then print_json result else Printf.printf "T3 connector: %s\n" (if runtime <> `Assoc [] then "see status --json" else "degraded");
  0

let status_term = as_command (const status_cmd $ json_flag)

let resolve_target ~mappings locator =
  let registered = List.map (fun (r : C2c_mcp.registration) -> r.alias) (C2c_mcp.Broker.list_registrations (C2c_mcp.Broker.create ~root:(service_broker_root ()))) in
  let find_by_alias alias =
    List.find_opt
      (fun (m : State.mapping) ->
        m.tombstone = None
        && C2c_mcp.Broker.alias_casefold m.alias = C2c_mcp.Broker.alias_casefold alias)
      mappings
  in
  match Service.resolve_locator ~mappings ~registered_aliases:registered locator with
  | Service.Alias alias -> Ok (find_by_alias alias)
  | Service.Thread_alias alias -> Ok (find_by_alias alias)
  | Service.Ambiguous_thread id -> Error ("thread locator is ambiguous: " ^ id)
  | Service.Unknown_thread id -> Error ("unknown T3 thread: " ^ id)

let send_cmd locator message mode json =
  match authorized () with
  | Error error -> print_error error; 1
  | Ok (client, _) ->
      with_send_mappings (fun mappings ->
        match resolve_target ~mappings locator with
        | Error error -> print_error error; 1
        | Ok None -> print_error ("no local T3 mapping for " ^ locator); 1
        | Ok (Some mapping) ->
            (match mode_of_string mode with
             | Error error -> print_error error; 1
             | Ok mode ->
                 (* A request id is an idempotency key for one operator
                    submission.  Text alone is not an identity: sending the
                    same message twice must create two T3 messages.  Include
                    a process-local nonce and wall-clock value so repeated
                    invocations cannot collapse into one request. *)
                 let request_id =
                   let nonce =
                     incr send_request_nonce;
                     Printf.sprintf "%d:%d:%.9f" (Unix.getpid ()) !send_request_nonce
                       (Unix.gettimeofday ())
                   in
                   "c2c-t3-cli-"
                   ^ String.sub
                       (Digestif.SHA256.(to_hex (digest_string
                          (mapping.thread_id ^ "\000" ^ message ^ "\000" ^ nonce)))) 0 32
                 in
                 match run_t3 (T3.send_message client ~thread_id:mapping.thread_id ~message ~mode ~client_request_id:request_id) with
                 | Error error -> print_error (T3.error_to_string error); 1
                 | Ok receipt ->
                     if json then print_json (`Assoc [ ("threadId", `String receipt.receipt_thread_id); ("messageId", `String receipt.message_id); ("runId", `String receipt.run_id); ("mode", `String (string_of_mode mode)) ])
                     else Printf.printf "sent to %s (message %s, run %s)\n" mapping.alias receipt.message_id receipt.run_id;
                     0))

let send_term =
  let locator = Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ALIAS" ~doc:"Local T3 alias or t3.<thread-id> locator.") in
  let message = Cmdliner.Arg.(required & pos 1 (some string) None & info [] ~docv:"MESSAGE" ~doc:"Message text sent as an agent-originated T3 message.") in
  let mode = Cmdliner.Arg.(value & opt mode_arg `Auto & info [ "mode" ] ~docv:"MODE" ~doc:"Delivery mode: auto, queue, steer, or restart.") in
  let mode = Cmdliner.Term.(const string_of_mode $ mode) in
  as_command (const send_cmd $ locator $ message $ mode $ json_flag)

let recovery_config_path () = config_dir () // "config.json"

let private_connector_dir path =
  (try
     match Unix.lstat path with
     | st when st.Unix.st_kind = Unix.S_DIR && st.Unix.st_uid = Unix.geteuid ()
                && st.Unix.st_perm land 0o077 = 0 -> Ok ()
     | _ -> Error (path ^ " is not a private directory owned by this user")
   with Unix.Unix_error (Unix.ENOENT, _, _) ->
     (try C2c_io.mkdir_p ~mode:0o700 path; Ok () with exn -> Error (Printexc.to_string exn))
      | exn -> Error (Printexc.to_string exn))

(* Repair is allowed to tighten a directory that this user owns, but it never
   follows a symlink or changes a foreign path.  The service state and
   connector credentials both require a 0700 boundary. *)
let repair_private_dir path =
  try
    match Unix.lstat path with
    | st when st.Unix.st_kind = Unix.S_DIR && st.Unix.st_uid = Unix.geteuid () ->
        Unix.chmod path 0o700; Ok ()
    | st when st.Unix.st_kind = Unix.S_LNK -> Error (path ^ " is a symlink")
    | st when st.Unix.st_kind <> Unix.S_DIR -> Error (path ^ " is not a directory")
    | _ -> Error (path ^ " is not owned by this user")
  with Unix.Unix_error (Unix.ENOENT, _, _) ->
    (try C2c_io.mkdir_p ~mode:0o700 path; Ok ()
     with exn -> Error (Printexc.to_string exn))
     | exn -> Error (Printexc.to_string exn)

let private_connector_file path =
  try
    match Unix.lstat path with
    | st when st.Unix.st_kind = Unix.S_REG && st.Unix.st_uid = Unix.geteuid ()
               && st.Unix.st_perm land 0o077 = 0 -> Ok ()
    | st when st.Unix.st_kind = Unix.S_LNK -> Error (path ^ " is a symlink")
    | st when st.Unix.st_kind <> Unix.S_REG -> Error (path ^ " is not a regular file")
    | _ -> Error (path ^ " is not a private file owned by this user")
  with Unix.Unix_error (Unix.ENOENT, _, _) -> Error (path ^ " does not exist")
     | exn -> Error (Printexc.to_string exn)

let check_private_connector_dir path =
  try
    match Unix.lstat path with
    | st when st.Unix.st_kind = Unix.S_DIR && st.Unix.st_uid = Unix.geteuid ()
               && st.Unix.st_perm land 0o077 = 0 -> Ok true
    | st when st.Unix.st_kind = Unix.S_LNK -> Error (path ^ " is a symlink")
    | st when st.Unix.st_kind <> Unix.S_DIR -> Error (path ^ " is not a directory")
    | _ -> Error (path ^ " is not a private directory owned by this user")
  with Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
     | exn -> Error (Printexc.to_string exn)

(* Read the operator's recovery switch without creating or repairing anything.
   A malformed or unsafe file is a hard disable.  The service calls this on
   every sweep so [recovery enable/disable] takes effect without a restart. *)
let configured_recovery () =
  let config = recovery_config_path () in
  match check_private_connector_dir (config_dir ()) with
  | Error error -> Error error
  | Ok false ->
      (match getenv_nonempty "C2C_T3_RECOVERY" with
       | None -> Ok true
       | Some ("0" | "false" | "off") -> Ok false
       | Some ("1" | "true" | "on") -> Ok true
       | Some value -> Error ("invalid C2C_T3_RECOVERY value " ^ value))
  | Ok true ->
      let file_value =
        match Unix.lstat config with
        | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
        | exception exn -> Error (Printexc.to_string exn)
        | st when st.Unix.st_kind <> Unix.S_REG -> Error (config ^ " is not a regular file")
        | st when st.Unix.st_uid <> Unix.geteuid () || st.Unix.st_perm land 0o077 <> 0 ->
            Error (config ^ " is not a private file owned by this user")
        | _ ->
            (try
               match Yojson.Safe.from_file config with
               | `Assoc fields ->
                   (match List.assoc_opt "recoveryEnabled" fields with
                    | None -> Ok None
                    | Some (`Bool enabled) -> Ok (Some enabled)
                    | Some _ -> Error "recoveryEnabled must be a boolean")
               | _ -> Error "T3 connector config must be a JSON object"
             with exn -> Error ("malformed T3 connector config: " ^ Printexc.to_string exn))
      in
      (match file_value with
       | Error _ as error -> error
       | Ok file_value ->
           match getenv_nonempty "C2C_T3_RECOVERY" with
           | None -> Ok (Option.value file_value ~default:true)
           | Some ("0" | "false" | "off") -> Ok false
           | Some ("1" | "true" | "on") -> Ok true
           | Some value -> Error ("invalid C2C_T3_RECOVERY value " ^ value))

let recovery_enabled () =
  match configured_recovery () with
  | Ok enabled -> enabled
  | Error _ -> false

let set_recovery_cmd enabled json =
  let path = recovery_config_path () in
  let existing =
    if not (Sys.file_exists path) then `Assoc []
    else
      try Yojson.Safe.from_file path
      with exn -> print_error ("refusing to overwrite malformed T3 config: " ^ Printexc.to_string exn); exit 1
  in
  let fields = match existing with `Assoc fields -> fields | _ -> print_error "refusing to overwrite non-object T3 config"; exit 1 in
  (match private_connector_dir (config_dir ()) with Ok () -> () | Error error -> print_error error; exit 1);
  (if Sys.file_exists path then
     match private_connector_file path with
     | Ok () -> ()
     | Error error -> print_error ("refusing to replace T3 connector config: " ^ error); exit 1);
  match C2c_io.write_file_atomic ~perm:0o600 path
          (Yojson.Safe.to_string (`Assoc (List.remove_assoc "recoveryEnabled" fields @ [ ("recoveryEnabled", `Bool enabled) ])) ^ "\n") with
  | Error error -> print_error error; 1
  | Ok () -> if json then print_json (`Assoc [ ("recoveryEnabled", `Bool enabled); ("path", `String path) ]) else Printf.printf "model-availability recovery %s\n" (if enabled then "enabled" else "disabled"); 0

let recovery_term enabled =
  as_command (const set_recovery_cmd $ const enabled $ json_flag)

let recovery_status_cmd json =
  if json then print_json (`Assoc [ ("recoveryEnabled", `Bool (recovery_enabled ())); ("path", `String (recovery_config_path ())) ])
  else Printf.printf "model-availability recovery: %s\n" (if recovery_enabled () then "enabled" else "disabled");
  0

let recovery_status_term = as_command (const recovery_status_cmd $ json_flag)

let service_owner ~environment_id ~broker () =
  { Service.environment_id; broker; pid = Some (Unix.getpid ());
    pid_start_time = C2c_mcp.Broker.capture_pid_start_time (Some (Unix.getpid ())); cwd = Some (Sys.getcwd ()); opaque_host_id = None }

let service_once ~client ~runtime ~state ~mode ~cross_repo:_ ~recovery ~on_recovery =
  let broker = C2c_mcp.Broker.create ~root:(service_broker_root ()) in
  let owner = service_owner ~environment_id:(environment_id runtime) ~broker () in
  let recovery =
    recovery && Recovery.supported_server_version runtime.T3.server_version
  in
  match run_t3 (Service.discover client) with
  | Error error -> Error (T3.error_to_string error)
  | Ok scan ->
      let missing = Service.missing_bound_thread_ids ~scan ~mappings:(State.mappings state) in
      let point_reads =
        run_lwt_exn
          (Lwt_list.map_s
             (fun thread_id -> Service.read_bound_thread client ~thread_id >|= fun result -> (thread_id, result)) missing)
      in
      let point_reads =
        List.map
          (fun (thread_id, result) ->
             (thread_id,
              match result with
              | Ok point_read -> point_read
              | Error error -> Service.Failed (T3.error_to_string error)))
          point_reads
      in
      let plan = Service.plan_reconciliation ~scan ~mappings:(State.mappings state) ~point_reads () in
           let applied = Service.apply_plan ~owner ~state ~plan in
           (* All enrolled aliases live in the shared sessions broker, regardless
              of the provider worktree. Replies must explicitly select that
              broker too; an operator flag cannot determine the message scope. *)
           let acceptance_errors = ref [] in
           List.iter
             (fun candidate ->
               let accepted = Service.accept_inbox ~mode ~cross_repo:true ~owner ~state
                   ~mapping:(Option.get candidate.Service.mapping) () in
               acceptance_errors := accepted.Service.errors @ !acceptance_errors)
             applied.published;
           let thread_ids = List.map (fun candidate -> candidate.Service.thread.thread_id) applied.published in
           let recovery_result =
             run_lwt_exn (Recovery.sweep ~enabled:recovery ~client ~state ~environment_id:owner.environment_id
                        ~credential_generation:(T3.credential_generation_of client) ~thread_ids ~clock:now ())
           in
           on_recovery ~enabled:recovery ~thread_ids recovery_result;
           let preflight (entry : State.entry) =
             match entry.State.kind with
             | State.Inbound -> Lwt.return (Ok ())
             | State.Recovery ->
                 (match Recovery.candidate_of_entry entry with
                  | Error error -> Lwt.return (Error error)
                  | Ok candidate ->
                      Recovery.preflight_with
                        ~operations:
                          { Recovery.capabilities = (fun () -> T3.capabilities client);
                            read_activity = (fun thread_id -> T3.read_activity client ~thread_id ());
                            list_queue = (fun thread_id -> T3.list_queue client ~thread_id) }
                        ~environment_id:owner.environment_id
                        ~credential_generation:(T3.credential_generation_of client)
                        ~candidate ())
           in
           let dispatcher =
             Service.create_dispatcher ~state
               ~credential_identity:(fun () -> T3.credential_identity_of client)
               ~credential_generation:(fun () -> T3.credential_generation_of client)
               ~can_send:(Recovery.can_dispatch ~enabled:recovery)
               ~preflight
               ~send:(fun ~thread_id ~message ~mode ~client_request_id ->
                 T3.send_message client ~thread_id ~message ~mode ~client_request_id)
               ~clock:now ()
           in
           let dispatch_failed = ref false in
           let rec dispatch count =
             if count >= 16 then Lwt.return (Ok ())
             else Service.dispatch_once dispatcher >>= function
               | Service.Rebind_required reason -> Lwt.return (Error reason)
               | Service.Idle -> Lwt.return (Ok ())
               | Service.Submitted _ ->
                   dispatch (count + 1)
               | Service.Retained _ | Service.Held _ ->
                   (* Reasons may contain remote error details. Persist only
                      aggregate health here; journal diagnostics stay private. *)
                   dispatch_failed := true;
                   dispatch (count + 1)
               | Service.Waiting delay ->
                   Lwt_unix.sleep (min delay 60.) >>= fun () -> dispatch (count + 1)
           in
           (match run_lwt_exn (dispatch 0) with
            | Ok () ->
                if !acceptance_errors <> [] then
                  Error "inbound mailbox acceptance failed; delivery is degraded"
                else if recovery_result.Recovery.errors <> [] then
                  Error "model-availability checks failed; recovery is degraded"
                else if !dispatch_failed then
                  Error "delivery dispatch held or retained work; delivery is degraded"
                else if List.exists
                    (fun (entry : State.entry) -> journal_payload_uncertain entry.payload
                                                 || journal_payload_has_error entry.payload)
                    (State.journal_pending state) then
                  Error "unresolved delivery journal failures; delivery is degraded"
                else Ok (scan, applied)
            | Error reason -> Error reason)

(* A private operational snapshot is separate from routing/dedupe state. It
   cannot authorize delivery. Exact PID generation prevents a prior owner's
   final heartbeat from looking like a running monitor after a restart. *)
let service_status_path () = state_dir () // "service-status.json"

let write_service_status ~started_at ~finished_at ~interval ~recovery ~recovery_hold ~recovery_checks ~healthy =
  let json_float = function None -> `Null | Some value -> `Float value in
  let generation = C2c_pid_identity.read_pid_generation (Unix.getpid ()) in
  let fields =
    [ ("environmentId", `String (environment_id_of_home (t3_home ())));
      ("pid", `Int (Unix.getpid ()));
      ("pidGeneration", match generation with C2c_pid_identity.Generation n -> `Int n | _ -> `Null);
      ("lastSweepAt", `Float started_at);
      ("completedAt", json_float finished_at);
      ("nextSweepAt", json_float (Option.map (fun at -> at +. interval) finished_at));
      ("intervalSeconds", `Float interval);
      ("recoveryRequested", `Bool recovery);
      ("recoveryEnabled", `Bool (recovery && recovery_hold = None));
      ("recoveryHold", match recovery_hold with Some reason -> `String reason | None -> `Null);
      ("recoveryChecks", recovery_checks);
      ("healthy", `Bool healthy) ]
  in
  match C2c_io.write_file_atomic ~perm:0o600 (service_status_path ())
          (Yojson.Safe.to_string (`Assoc fields) ^ "\n") with
  | Ok () -> ()
  | Error _ -> Printf.eprintf "warning: unable to persist T3 monitor status\n%!"

let read_service_status () =
  try
    let filename = service_status_path () in
    let st = Unix.lstat filename in
    if st.Unix.st_kind <> Unix.S_REG || st.Unix.st_uid <> Unix.geteuid ()
       || st.Unix.st_perm land 0o077 <> 0 || st.Unix.st_size > 65536 then
      `Assoc [ ("running", `Bool false) ]
    else match Yojson.Safe.from_file filename with
    | `Assoc fields ->
        let running =
          match List.assoc_opt "environmentId" fields, List.assoc_opt "pid" fields,
                List.assoc_opt "pidGeneration" fields with
          | Some (`String env), Some (`Int pid), Some (`Int generation)
              when env = environment_id_of_home (t3_home ()) ->
              C2c_pid_identity.read_pid_generation pid = C2c_pid_identity.Generation generation
          | _ -> false
        in
        `Assoc (("running", `Bool running) :: fields)
    | _ -> `Assoc [ ("running", `Bool false) ]
  with _ -> `Assoc [ ("running", `Bool false) ]

let foreground_cmd foreground once interval mode cross_repo recovery_override =
  if not foreground && not once then Printf.eprintf "starting c2c T3 connector in foreground (Ctrl-C to stop)\n%!";
  if not (Float.is_finite interval) || interval < 1. then
    (print_error "service interval must be finite and at least one second"; exit 1);
  with_state (fun state ->
    let rec loop () =
      let recovery, configuration_healthy =
        match configured_recovery () with
        | Ok configured -> Option.value recovery_override ~default:configured, true
        | Error _ ->
            (* Never leave recovery enabled when its durable configuration is
               malformed or unsafe.  Continue serving already accepted mail,
               but hold new model-availability actions until repair. *)
            Printf.eprintf "warning: model-availability recovery configuration is invalid or unsafe; inspect c2c t3 service doctor --json\n%!";
            false, false
      in
      let recovery_hold = ref (if configuration_healthy then None
        else Some "recovery configuration is invalid or unsafe; repair owned permissions or correct the config") in
      let started_at = now () in
      let recovery_report = ref None in
      let on_recovery ~enabled ~thread_ids result =
        recovery_report := Some (enabled, thread_ids, result) in
      write_service_status ~started_at ~finished_at:None ~interval ~recovery ~recovery_hold:!recovery_hold ~recovery_checks:`Null ~healthy:false;
      let healthy =
        match authorized ~rebind:true () with
        | Error error -> Printf.eprintf "warning: T3 service degraded: %s\n%!" error; false
        | Ok (client, runtime) ->
            if recovery then recovery_hold := Recovery.version_hold_reason runtime.T3.server_version;
            (match service_once ~client ~runtime ~state ~mode ~cross_repo ~recovery ~on_recovery with
             | Error error -> Printf.eprintf "warning: T3 service degraded: %s\n%!" error; false
             | Ok (scan, applied) -> scan.Service.complete && applied.Service.errors = []
                                    && configuration_healthy && !recovery_hold = None)
      in
      let finished_at = now () in
      let recovery_checks = match !recovery_report with
        | None -> `Null
        | Some (enabled, thread_ids, result) ->
            Recovery.sweep_diagnostics ~enabled ~thread_ids
              ~next_due_at:(finished_at +. interval) result in
      write_service_status ~started_at ~finished_at:(Some finished_at) ~interval ~recovery ~recovery_hold:!recovery_hold ~recovery_checks ~healthy;
      if once then 0 else (ignore (Unix.select [] [] [] interval); loop ())
    in
    loop ())

let foreground_term =
  let foreground = Cmdliner.Arg.(value & flag & info [ "foreground" ] ~doc:"Run in the foreground (the default for this command).") in
  let once = Cmdliner.Arg.(value & flag & info [ "once" ] ~doc:"Run one discovery/delivery/recovery sweep and exit (fixture/operator use).") in
  let interval = Cmdliner.Arg.(value & opt float 60. & info [ "interval" ] ~docv:"SECONDS" ~doc:"Seconds between serialized service sweeps (default 60).") in
  let mode = Cmdliner.Arg.(value & opt mode_arg `Auto & info [ "mode" ] ~docv:"MODE" ~doc:"Inbound delivery mode: auto, queue, steer, or restart.") in
  let cross_repo = cross_repo_flag in
  let recovery = Cmdliner.Arg.(value & opt (some bool) None & info [ "recovery" ] ~docv:"BOOL" ~doc:"Override durable model-availability Continue recovery for this process.") in
  as_command (const foreground_cmd $ foreground $ once $ interval $ mode $ cross_repo $ recovery)

let doctor_cmd json =
  let runtime_result = T3.discover ~t3_home:(t3_home ()) () in
  let runtime =
    match runtime_result with
    | Ok r ->
        `Assoc [ ("ready", `Bool true); ("origin", `String r.origin);
                 ("pid", `Int r.pid); ("home", `String r.t3_home);
                 ("serverVersion", match r.server_version with Some v -> `String v | None -> `Null) ]
    | Error e -> `Assoc [ ("ready", `Bool false); ("error", `String (T3.error_to_string e)) ]
  in
  let credential_result = T3.load_credential ~config_dir:(config_dir ()) in
  let credential =
    match credential_result with
    | Ok c -> `Assoc [ ("present", `Bool true); ("generation", `Int (T3.credential_generation c));
                       ("scopes", `List (List.map (fun s -> `String s) (T3.credential_scopes c))) ]
    | Error error -> `Assoc [ ("present", `Bool false); ("error", `String (T3.error_to_string error)) ]
  in
  let api_result =
    match runtime_result, credential_result with
    | Ok _, Ok _ ->
        (match authorized () with
         | Error error -> Error error
         | Ok (client, _) ->
             (match run_t3 (T3.capabilities client) with
              | Ok caps -> Ok caps
              | Error error -> Error (T3.error_to_string error)))
    | _ -> Error "runtime or credential is unavailable"
  in
  let api, permission_ceiling, api_ready =
    match api_result with
    | Ok caps ->
        (`Assoc [ ("ready", `Bool true);
                  ("runtimeMode", match caps.T3.runtime_mode with T3.Known value -> `String value | T3.Unknown -> `Null);
                  ("interactionMode", match caps.T3.interaction_mode with T3.Known value -> `String value | T3.Unknown -> `Null) ],
         (match caps.T3.runtime_mode with T3.Known value -> `String value | T3.Unknown -> `Null), true)
    | Error error -> (`Assoc [ ("ready", `Bool false); ("error", `String error) ], `Null, false)
  in
  let state = state_snapshot () in
  let state_healthy = match state with
    | `Assoc fields -> List.assoc_opt "available" fields = Some (`Bool true)
                       && List.assoc_opt "healthy" fields <> Some (`Bool false)
    | _ -> false
  in
  let monitor = read_service_status () in
  let monitor_validation = match monitor with
    | `Assoc fields when List.assoc_opt "running" fields = Some (`Bool true) ->
        let ( let* ) = Result.bind in
        let* pid = match List.assoc_opt "pid" fields with
          | Some (`Int pid) -> Ok pid | _ -> Error "connector monitor PID is unavailable" in
        let* c2c_path = C2c_t3_systemd.c2c_path () in
        let* generation = C2c_t3_systemd.check_process ~pid ~c2c_path
            ~t3_home:(t3_home ()) ~config_dir:(config_dir ()) ~state_dir:(state_dir ()) () in
        C2c_t3_systemd.check_monitor ~pid ~generation ~t3_home:(t3_home ()) ~state_dir:(state_dir ()) ()
    | _ -> Error "connector monitor is not running; run c2c t3 service or c2c t3 service install"
  in
  let monitor_healthy = Result.is_ok monitor_validation in
  let monitor = match monitor with
    | `Assoc fields -> `Assoc (("verifiedHealthy", `Bool monitor_healthy)
        :: ("readinessError", match monitor_validation with Ok () -> `Null | Error reason -> `String reason) :: fields)
    | _ -> monitor in
  let runtime_ready = match runtime with `Assoc fields -> List.assoc_opt "ready" fields = Some (`Bool true) | _ -> false in
  let credential_present = match credential with `Assoc fields -> List.assoc_opt "present" fields = Some (`Bool true) | _ -> false in
  let recovery_configuration = configured_recovery () in
  let recovery_enabled_value = match recovery_configuration with
    | Error _ -> false
    | Ok configured ->
        (match monitor with
         | `Assoc fields when List.assoc_opt "running" fields = Some (`Bool true) ->
             (match List.assoc_opt "recoveryRequested" fields with
              | Some (`Bool requested) -> requested | _ -> configured)
         | _ -> configured)
  in
  let recovery_reason =
    match recovery_configuration with
    | Error _ -> Some "recovery configuration is invalid or unsafe; repair owned permissions or correct the config"
    | Ok _ when not recovery_enabled_value -> None
    | Ok _ ->
        (match runtime_result with
         | Ok r -> Recovery.version_hold_reason r.server_version
         | Error _ -> Some "T3 runtime is unavailable")
  in
  let unit_active = C2c_t3_systemd.unit_is_active () in
  let unit_enabled = C2c_t3_systemd.unit_is_enabled () in
  let configured_ready = runtime_ready && credential_present && api_ready
                         && state_healthy && recovery_reason = None in
  let effective_recovery_reason = match recovery_reason, monitor_validation with
    | (Some _ as reason), _ -> reason
    | None, Error reason when recovery_enabled_value -> Some reason
    | _ -> None in
  let result =
    `Assoc [ ("healthy", `Bool (configured_ready && monitor_healthy));
             ("configuredReady", `Bool configured_ready);
             ("runtime", runtime); ("credential", credential); ("api", api);
             ("permissionCeiling", permission_ceiling); ("state", state);
             ("recoveryRequested", `Bool recovery_enabled_value);
             ("recoveryEnabled", `Bool (recovery_enabled_value && effective_recovery_reason = None));
             ("recoveryConfigurationValid", `Bool (Result.is_ok recovery_configuration));
             ("recoveryHold", match effective_recovery_reason with Some reason -> `String reason | None -> `Null);
             ("recoveryCadenceSeconds", `Int 60);
             ("monitor", monitor);
             ("unit", `Assoc [ ("path", `String (C2c_t3_systemd.unit_path ())); ("active", `Bool unit_active);
                               ("enabled", `Bool unit_enabled);
                               ("mainPid", match C2c_t3_systemd.unit_main_pid () with Some pid -> `Int pid | None -> `Null) ]) ]
  in
  if json then print_json result else begin
    Printf.printf
      "T3 service doctor\n  runtime: %s\n  credential: %s\n  API: %s\n  access: %s\n  state: %s\n  recovery: %s\n  supervision: %s\n"
      (if runtime_ready then "ready" else "degraded")
      (if credential_present then "paired" else "unpaired")
      (if api_ready then "ready" else "degraded")
      (Yojson.Safe.to_string permission_ceiling)
      (Yojson.Safe.to_string state)
      (match effective_recovery_reason with Some reason -> "held: " ^ reason
       | None -> if recovery_enabled_value then "enabled" else "disabled by operator")
      (if unit_active then "active" else "inactive");
    (match monitor with
     | `Assoc fields ->
         (match List.assoc_opt "recoveryChecks" fields with
          | Some (`Assoc checks) ->
              (match List.assoc_opt "threads" checks with
               | Some (`List rows) -> List.iter (function
                   | `Assoc fields ->
                       (match List.assoc_opt "threadId" fields, List.assoc_opt "holdReason" fields with
                        | Some (`String id), Some (`String reason) ->
                            Printf.printf "  recovery thread %s: %s\n" id reason
                        | _ -> ())
                   | _ -> ()) rows
               | _ -> ())
          | _ -> ())
     | _ -> ())
  end;
  0

let doctor_term = as_command (const doctor_cmd $ json_flag)

type repair_change =
  | Create_directory of string
  | Tighten_mode of string * int * Unix.stats
  | Remove_stale_status of string * Unix.stats

let repair_change_json = function
  | Create_directory path -> `Assoc [ ("action", `String "create-directory"); ("path", `String path); ("mode", `String "0700") ]
  | Tighten_mode (path, mode, _) -> `Assoc [ ("action", `String "tighten-mode"); ("path", `String path); ("mode", `String (Printf.sprintf "%04o" mode)) ]
  | Remove_stale_status (path, _) -> `Assoc [ ("action", `String "remove-stale-status"); ("path", `String path) ]

let same_inode a b = a.Unix.st_dev = b.Unix.st_dev && a.Unix.st_ino = b.Unix.st_ino

let rec checked_directory_tree path =
  if path = "/" || path = "." || path = "" then Ok ()
  else match Unix.lstat path with
    | st when st.Unix.st_kind = Unix.S_DIR -> checked_directory_tree (Filename.dirname path)
    | _ -> Error (path ^ " is not a real directory; symlinks are refused")
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> checked_directory_tree (Filename.dirname path)
    | exception _ -> Error (path ^ " cannot be inspected safely")

let plan_private_path ~directory path =
  match checked_directory_tree (Filename.dirname path) with
  | Error _ as error -> error
  | Ok () ->
      try match Unix.lstat path with
        | st when st.Unix.st_uid <> Unix.geteuid () -> Error (path ^ " is not owned by this user")
        | st when st.Unix.st_kind <> (if directory then Unix.S_DIR else Unix.S_REG)
                  || (not directory && st.Unix.st_nlink <> 1) ->
            Error (path ^ " has an unsafe type or hard links; preserve it for manual inspection")
        | st ->
            let mode = if directory then 0o700 else 0o600 in
            Ok (if st.Unix.st_perm land 0o7777 = mode then [] else [ Tighten_mode (path, mode, st) ])
      with Unix.Unix_error (Unix.ENOENT, _, _) -> Ok (if directory then [ Create_directory path ] else [])
         | _ -> Error (path ^ " cannot be inspected safely")

let status_is_proven_stale path =
  match C2c_t3_systemd.read_owned_regular ~max_bytes:65536 path with
  | Error _ as error -> error
  | Ok text ->
      try
        let fields = match Yojson.Safe.from_string text with `Assoc fields -> fields | _ -> [] in
        match List.assoc_opt "environmentId" fields, List.assoc_opt "pid" fields,
              List.assoc_opt "pidGeneration" fields with
        | Some (`String env), Some (`Int pid), Some (`Int generation)
            when env = environment_id_of_home (t3_home ()) && pid > 0 && generation >= 0 ->
            (match C2c_pid_identity.read_pid_generation pid with
             | C2c_pid_identity.Absent -> Ok true
             | C2c_pid_identity.Generation actual -> Ok (generation <> actual)
             | C2c_pid_identity.Unreadable -> Error "monitor PID generation is unreadable; retain its status")
        | _ -> Error "monitor status has ambiguous ownership; retain it for manual inspection"
      with _ -> Error "monitor status is malformed; retain it for manual inspection"

let apply_repair_change change =
  try match change with
    | Create_directory path ->
        (match checked_directory_tree path with
         | Error _ as error -> error
         | Ok () -> C2c_t3_systemd.private_mkdir_p path; Ok ())
    | Tighten_mode (path, mode, expected) ->
        let fd = if expected.Unix.st_kind = Unix.S_REG then C2c_t3_systemd.open_regular_nofollow path
          else Unix.openfile path [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ] 0 in
        Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
          let actual = Unix.fstat fd in
          if not (same_inode expected actual) || actual.Unix.st_uid <> Unix.geteuid ()
             || actual.Unix.st_kind <> expected.Unix.st_kind then
            Error (path ^ " changed during repair; nothing was overwritten")
          else (Unix.fchmod fd mode; Ok ()))
    | Remove_stale_status (path, expected) ->
        (match status_is_proven_stale path with
         | Ok true when same_inode expected (Unix.lstat path) -> Unix.unlink path; Ok ()
         | _ -> Error "monitor status changed or no longer has proven-stale ownership; preserve it")
  with _ -> Error "owned metadata repair could not complete safely"

(* This is the same lock inode and POSIX lock used by State.open_state. Never
   unlink it, and never open/close a second fd for it while holding the lock:
   closing any fd for a POSIX lock inode releases this process's locks. *)
let acquire_repair_lock ~dry_run () =
  let path = state_dir () // "t3-state.lock" in
  try
    let before = try Some (Unix.lstat path) with Unix.Unix_error (Unix.ENOENT, _, _) -> None in
    if dry_run && before = None then Ok None
    else
      let fd = match before with
        | None -> Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ] 0o600
        | Some st when st.Unix.st_kind = Unix.S_REG && st.Unix.st_uid = Unix.geteuid () && st.Unix.st_nlink = 1 ->
            Unix.openfile path [ Unix.O_RDWR; Unix.O_NONBLOCK; Unix.O_CLOEXEC ] 0
        | Some _ -> failwith "unsafe singleton" in
      let checked =
        let actual = Unix.fstat fd in
        actual.Unix.st_kind = Unix.S_REG && actual.Unix.st_uid = Unix.geteuid ()
        && actual.Unix.st_nlink = 1 && same_inode actual (Unix.lstat path)
        && (match before with None -> true | Some before -> same_inode before actual) in
      if not checked then (Unix.close fd; Error "singleton path changed or has unsafe ownership")
      else
        (try Unix.lockf fd Unix.F_TLOCK 0;
             if not dry_run then Unix.fchmod fd 0o600;
             Ok (Some fd)
         with _ -> Unix.close fd; Error "live connector owns the singleton; stop only this connector before repairing private metadata")
  with _ -> Error "singleton cannot be acquired safely; no metadata was replaced"

let verify_owner_routes ~c2c_path () =
  let ( let* ) = Result.bind in
  let monitor = read_service_status () in
  let* pid = match monitor with
    | `Assoc fields when List.assoc_opt "running" fields = Some (`Bool true) ->
        (match List.assoc_opt "pid" fields with Some (`Int pid) -> Ok pid | _ -> Error "monitor has no owner PID")
    | _ -> Error "no live connector sweep to reconcile aliases; run c2c t3 service or c2c t3 service install" in
  let* () = C2c_t3_systemd.native_readiness ~c2c_path ~t3_home:(t3_home ())
      ~config_dir:(config_dir ()) ~state_dir:(state_dir ()) ~pid () in
  let* snapshot = State.open_read_only ~environment_id:(environment_id_of_home (t3_home ())) ~dir:(state_dir ()) ()
    |> Result.map_error State.open_error_to_string in
  let* registry_text = C2c_t3_systemd.read_owned_regular ~max_bytes:(8 * 1024 * 1024)
      (service_broker_root () // "registry.json") in
  let* registrations =
    try match Yojson.Safe.from_string registry_text with
      | `List rows -> Ok (List.map C2c_mcp.Broker.registration_of_json rows)
      | _ -> Error "broker registry is malformed; preserve it for its owner"
    with _ -> Error "broker registry cannot be inspected; preserve it for its owner" in
  let holds = State.read_only_holds snapshot in
  let mappings = State.read_only_mappings snapshot in
  let active mapping = mapping.State.tombstone = None && not (List.mem_assoc mapping.State.thread_id holds) in
  let generation = match C2c_pid_identity.read_pid_generation pid with C2c_pid_identity.Generation n -> Some n | _ -> None in
  let owned mapping (registration : C2c_mcp.registration) =
    registration.session_id = Service.service_session_id ~environment_id:(environment_id_of_home (t3_home ())) ~thread_id:mapping.State.thread_id
    && registration.registered_by = Some Service.service_registered_by
    && registration.client_type = Some "t3" in
  let valid mapping =
    match List.find_opt (fun (row : C2c_mcp.registration) -> String.lowercase_ascii row.alias = String.lowercase_ascii mapping.State.alias) registrations with
    | None -> not (active mapping)
    | Some row -> if active mapping then owned mapping row && row.pid = Some pid && row.pid_start_time = generation
                  else not (owned mapping row) in
  if not (List.for_all valid mappings) then
    Error "owned alias drift remains; wait for the connector's next healthy sweep, then rerun repair (foreign registrations are preserved)"
  else match Relay_activation.resolve () with
    | Relay_activation.Relay_inactive | Relay_activation.Relay_disabled _ -> Ok "verified owner sweep; local routes (relay inactive)"
    | Relay_activation.Relay_active _ ->
        (match C2c_relay_connector.read_connector_state (service_broker_root ()) with
         | Some state when Relay_doctor.connector_bridge_live ~state:(Some state) ~now:(now ())
                           && state.C2c_relay_connector.cs_errors = []
                           && List.for_all (fun mapping ->
                             List.assoc_opt mapping.State.alias state.cs_sessions =
                             Some (Service.service_session_id ~environment_id:(environment_id_of_home (t3_home ())) ~thread_id:mapping.thread_id))
                             (List.filter active mappings) -> Ok "verified owner sweep and recent relay lease reconciliation"
         | _ -> Error "relay lease reconciliation is incomplete; run c2c doctor --relay and use the existing relay-connect owner, then rerun repair")

let repair_cmd dry_run json =
  let planned = ref [] and applied = ref [] and holds = ref [] in
  let live_owner = ref false in
  let hold reason = holds := reason :: !holds in
  let inspect directory path = match plan_private_path ~directory path with
    | Ok changes -> planned := !planned @ changes | Error reason -> hold reason in
  List.iter (inspect true) [ config_dir (); state_dir () ];
  List.iter (inspect false) [ recovery_config_path (); state_dir () // "state.json"; service_status_path () ];
  (match Unix.lstat (service_status_path ()) with
   | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
   | exception _ -> hold "monitor status cannot be inspected"
   | st -> (match status_is_proven_stale (service_status_path ()) with
       | Ok true -> planned := List.filter (function Tighten_mode (path, _, _) -> path <> service_status_path () | _ -> true) !planned
                              @ [ Remove_stale_status (service_status_path (), st) ]
       | Ok false -> () | Error reason -> hold reason));
  let executable = C2c_t3_systemd.c2c_path () in
  let unit_plan = Result.bind executable (fun c2c_path ->
    C2c_t3_systemd.unit_plan ~c2c_path ~t3_home:(t3_home ()) ~config_dir:(config_dir ()) ~state_dir:(state_dir ()) ()) in
  (match unit_plan with Error reason -> hold reason | Ok _ -> ());
  let unit_result = ref "not verified" and routes_result = ref "not verified" in
  if !holds = [] then begin
    (* A missing directory cannot contain a live owner. Create only that
       boundary before acquiring the singleton; every other change is locked. *)
    if not dry_run && not (Sys.file_exists (state_dir ())) then
      (match apply_repair_change (Create_directory (state_dir ())) with
       | Ok () -> applied := [ Create_directory (state_dir ()) ]
       | Error reason -> hold reason);
    if !holds = [] then
      match acquire_repair_lock ~dry_run () with
      | Error reason ->
          live_owner := true;
          if !planned <> [] || unit_plan <> Ok `Current then hold reason
      | Ok lock ->
          Fun.protect ~finally:(fun () -> Option.iter C2c_singleton_lock.release lock) (fun () ->
            if not dry_run then List.iter (fun change ->
              if not (List.mem change !applied) then
                match apply_repair_change change with
                | Ok () -> applied := !applied @ [ change ] | Error reason -> hold reason) !planned;
            if not dry_run && Sys.file_exists (state_dir () // "state.json")
               && Result.is_error (State.open_read_only
                    ~environment_id:(environment_id_of_home (t3_home ())) ~dir:(state_dir ()) ()) then
              hold "state is malformed, foreign or unsafe; its bytes are preserved for manual reconciliation";
            if not dry_run && Result.is_error (configured_recovery ()) then
              hold "recovery configuration is invalid or unsafe; its bytes are preserved for manual correction")
  end;
  if dry_run then begin
    unit_result := (match unit_plan with Ok `Current -> "would verify owned unit and readiness" | Ok _ -> "would repair owned unit and verify readiness" | Error _ -> "held");
    routes_result := "would verify the live owner's alias sweep and activated relay leases; no short-lived registrations"
  end else if !holds = [] then begin
    (match executable with
     | Error reason -> hold reason
     | Ok c2c_path ->
         (match unit_plan with
          | Ok `Current when C2c_t3_systemd.unit_is_active () ->
              (* Do not rewrite a correct live unit just to inspect it. *)
              (match C2c_t3_systemd.unit_main_pid () with
               | Some pid -> (match C2c_t3_systemd.native_readiness ~c2c_path ~t3_home:(t3_home ()) ~config_dir:(config_dir ()) ~state_dir:(state_dir ()) ~pid () with
                   | Ok () -> unit_result := "ready" | Error reason -> unit_result := "held: " ^ reason; hold reason)
               | None -> hold "active owned unit has no verifiable MainPID")
          | Ok _ when !live_owner ->
              hold "foreground connector owns the singleton; preserve it and stop only that connector before enabling supervision"
          | Ok _ ->
              (match C2c_t3_systemd.install ~c2c_path ~t3_home:(t3_home ()) ~config_dir:(config_dir ()) ~state_dir:(state_dir ()) () with
               | C2c_t3_systemd.Installed _ -> unit_result := "ready"
               | C2c_t3_systemd.Skipped reason | C2c_t3_systemd.Failed reason -> unit_result := "held: " ^ reason; hold reason)
          | Error _ -> ());
         (match verify_owner_routes ~c2c_path () with
          | Ok value -> routes_result := value
          | Error reason -> routes_result := "held: " ^ reason; hold reason))
  end;
  let unit_actions = match unit_plan with
    | Ok `Missing -> [ `Assoc [ ("action", `String "install-owned-unit"); ("path", `String (C2c_t3_systemd.unit_path ())) ] ]
    | Ok `Drifted -> [ `Assoc [ ("action", `String "repair-owned-unit"); ("path", `String (C2c_t3_systemd.unit_path ())) ] ]
    | _ -> [] in
  let result = `Assoc [ ("complete", `Bool (!holds = [])); ("dryRun", `Bool dry_run);
    ("planned", `List (List.map repair_change_json !planned @ unit_actions));
    ("applied", `List (List.map repair_change_json !applied));
    ("holds", `List (List.map (fun s -> `String s) (List.rev !holds)));
    ("unit", `String !unit_result); ("routes", `String !routes_result);
    ("credentialPreserved", `Bool true); ("mailPreserved", `Bool true) ] in
  if json then print_json result else Printf.printf "%s\n" (Yojson.Safe.to_string result);
  if !holds = [] then 0 else 1

let repair_term =
  let dry_run = Cmdliner.Arg.(value & flag & info [ "dry-run" ] ~doc:"Report safe repairs without changing files.") in
  as_command (const repair_cmd $ dry_run $ json_flag)

let install_cmd dry_run =
  match C2c_t3_systemd.c2c_path () with
  | Error error -> print_error error; 1
  | Ok c2c_path ->
      match C2c_t3_systemd.install ~dry_run ~c2c_path ~t3_home:(t3_home ()) ~config_dir:(config_dir ()) ~state_dir:(state_dir ()) () with
      | C2c_t3_systemd.Installed path -> Printf.printf "%s %s\n" (if dry_run then "would install" else "installed") path; 0
      | Skipped reason -> Printf.eprintf "%s\n%!" reason; 1
      | Failed reason -> print_error reason; 1

let install_term = as_command (const install_cmd $ Cmdliner.Arg.(value & flag & info [ "dry-run" ] ~doc:"Show the unit path without writing or enabling it."))

let service_stop_cmd dry_run =
  match C2c_t3_systemd.stop ~dry_run ~t3_home:(t3_home ())
          ~config_dir:(config_dir ()) ~state_dir:(state_dir ()) () with
  | C2c_t3_systemd.Systemctl_ok ->
      Printf.printf "%s %s\n" (if dry_run then "would stop and disable" else "stopped") C2c_t3_systemd.unit_name; 0
  | C2c_t3_systemd.Systemctl_failed e -> print_error e; 1

let service_uninstall_cmd dry_run =
  match C2c_t3_systemd.uninstall ~dry_run ~t3_home:(t3_home ())
          ~config_dir:(config_dir ()) ~state_dir:(state_dir ()) () with
  | C2c_t3_systemd.Systemctl_ok ->
      Printf.printf "%s %s (state and queued mail retained)\n" (if dry_run then "would remove" else "removed") C2c_t3_systemd.unit_name; 0
  | C2c_t3_systemd.Systemctl_failed e -> print_error e; 1

let recovery_group =
  Cmdliner.Cmd.group ~default:recovery_status_term
    (Cmdliner.Cmd.info "recovery" ~doc:"Enable or disable durable model-availability Continue recovery.")
    [ Cmdliner.Cmd.v (Cmdliner.Cmd.info "enable" ~doc:"Enable recovery for future service sweeps.") (recovery_term true);
      Cmdliner.Cmd.v (Cmdliner.Cmd.info "disable" ~doc:"Hold recovery intents without deleting them.") (recovery_term false);
      Cmdliner.Cmd.v (Cmdliner.Cmd.info "status" ~doc:"Show the current durable recovery setting.") recovery_status_term ]

let service_group : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.group ~default:foreground_term
    (Cmdliner.Cmd.info "service" ~doc:"Run and supervise the native connector for one local T3 Code instance.")
    [ Cmdliner.Cmd.v (Cmdliner.Cmd.info "install" ~doc:"Install, enable, and start the owned user-systemd unit.") install_term;
      Cmdliner.Cmd.v (Cmdliner.Cmd.info "doctor" ~doc:"Read-only redacted readiness and health report.") doctor_term;
      Cmdliner.Cmd.v (Cmdliner.Cmd.info "repair" ~doc:"Repair owned metadata and unit drift, and verify the existing route owners; credentials and mail are preserved.") repair_term;
      recovery_group;
      Cmdliner.Cmd.v (Cmdliner.Cmd.info "stop" ~doc:"Stop and disable the owned user-systemd unit.") (as_command (const service_stop_cmd $ Cmdliner.Arg.(value & flag & info [ "dry-run" ] ~doc:"Do not call systemctl.")));
      Cmdliner.Cmd.v (Cmdliner.Cmd.info "uninstall" ~doc:"Remove the owned unit while retaining connector state and queued mail.") (as_command (const service_uninstall_cmd $ Cmdliner.Arg.(value & flag & info [ "dry-run" ] ~doc:"Do not remove the unit."))) ]

let t3_group =
  Cmdliner.Cmd.group
    (Cmdliner.Cmd.info "t3" ~doc:"Connect c2c to an unmodified local T3 Code service.")
    [ Cmdliner.Cmd.v (Cmdliner.Cmd.info "pair" ~doc:"Pair with T3 using its local PKCE pairing flow.") pair_term;
      Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List open root T3 threads and their stable c2c aliases.") list_term;
      Cmdliner.Cmd.v (Cmdliner.Cmd.info "status" ~doc:"Show connector readiness and durable queue status.") status_term;
      Cmdliner.Cmd.v (Cmdliner.Cmd.info "send" ~doc:"Send an operator-mode message to a local T3 thread.") send_term;
      service_group ]
