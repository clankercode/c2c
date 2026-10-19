(* Discovery and alias ownership for the native T3 connector.  The service
   owns the policy boundary here; delivery and recovery workers consume the
   resulting candidates later. *)

open Lwt.Infix

module T3 = C2c_t3_client
module State = C2c_t3_state
module Broker = C2c_mcp.Broker

type thread = {
  project_id : string;
  thread_id : string;
  title : string;
  parent_thread_id : string option;
  parent_known : bool;
  lifecycle_known : bool;
  archived : bool;
  settled : bool;
  deleted : bool;
  runtime_mode : string option;
  updated_at : string option;
}

let member key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let string_opt key json =
  match member key json with Some (`String value) -> Some value | _ -> None

let bool_opt key json =
  match member key json with Some (`Bool value) -> Some value | _ -> None

let string_required key json =
  match string_opt key json with
  | Some value when String.trim value <> "" -> Ok value
  | _ -> Error (Printf.sprintf "thread metadata missing non-empty %s" key)

let parent_field json =
  match member "parentThreadId" json with
  | Some `Null -> Ok (true, None)
  | Some (`String value) when String.trim value <> "" -> Ok (true, Some value)
  | Some _ -> Error "parentThreadId must be null or a non-empty string"
  | None -> Error "thread metadata missing parentThreadId"

let lifecycle_bool ~require_lifecycle key json default =
  match member key json with
  | Some (`Bool value) -> Ok value
  | None when not require_lifecycle -> Ok default
  | None -> Error (Printf.sprintf "thread metadata missing %s" key)
  | Some _ -> Error (Printf.sprintf "thread metadata %s must be boolean" key)

let thread_of_json ~project_id ~require_lifecycle json =
  let ( let* ) = Result.bind in
  let* thread_id =
    match string_opt "threadId" json with
    | Some value when String.trim value <> "" -> Ok value
    | _ -> string_required "id" json
  in
  let* parent_known, parent_thread_id = parent_field json in
  (* [settled] is present in both list and detail contracts. Treating a
     missing value as false would advertise a thread whose lifecycle we did
     not actually observe. *)
  let* settled = lifecycle_bool ~require_lifecycle:true "settled" json false in
  let* archived = lifecycle_bool ~require_lifecycle "archived" json false in
  let deleted =
    match member "deleted" json with
    | Some (`Bool value) -> value
    | _ -> Option.is_some (member "deletedAt" json) && member "deletedAt" json <> Some `Null
  in
  Ok
    { project_id;
      thread_id;
      title = Option.value (string_opt "title" json) ~default:"";
      parent_thread_id;
      parent_known;
      lifecycle_known = require_lifecycle;
      archived;
      settled;
      deleted;
      runtime_mode = string_opt "runtimeMode" json;
      updated_at = string_opt "updatedAt" json }

let thread_of_activity ~project_id (activity : T3.activity) =
  let project_id =
    match string_opt "projectId" activity.thread_raw with
    | Some value when value <> "" -> value
    | _ -> project_id
  in
  match thread_of_json ~project_id ~require_lifecycle:true activity.thread_raw with
  | Error _ as error -> error
  | Ok thread when thread.thread_id <> activity.thread_id ->
      Error "thread activity id does not match requested thread"
  | Ok thread -> Ok thread

let is_open_root thread =
  thread.parent_known
  && thread.lifecycle_known
  && thread.parent_thread_id = None
  && not thread.archived
  && not thread.settled
  && not thread.deleted

type eligibility =
  | Routable
  | Permission_ineligible of string
  | Retired of string

let eligibility ~credential_access thread =
  if not (is_open_root thread) then
    let reason =
      if thread.parent_thread_id <> None then "thread has a parent"
      else if thread.deleted then "thread is deleted"
      else if thread.archived then "thread is archived"
      else if thread.settled then "thread is settled"
      else "thread lineage is incomplete"
    in
    Retired reason
  else
    match thread.runtime_mode, credential_access with
    | None, _ -> Permission_ineligible "thread runtime mode is unknown"
    | Some "full-access", Some access when access <> "full-access" ->
        Permission_ineligible "full-access root exceeds connector access"
    | Some "full-access", None ->
        Permission_ineligible "full-access root access is unknown"
    | _ -> Routable

type scan = {
  listed : thread list;
  project_ids : string list;
  complete : bool;
  errors : string list;
}

let project_id_of_json json =
  match string_opt "id" json with
  | Some value when String.trim value <> "" -> Ok value
  | _ -> string_required "projectId" json

let unique_by_thread_id threads =
  let seen = Hashtbl.create (List.length threads) in
  List.filter
    (fun thread ->
      if Hashtbl.mem seen thread.thread_id then false
      else (Hashtbl.add seen thread.thread_id (); true))
    threads

let unique_strings values =
  let seen = Hashtbl.create (List.length values) in
  List.filter
    (fun value ->
      if Hashtbl.mem seen value then false
      else (Hashtbl.add seen value (); true))
    values

let discover (client : T3.client) =
  client |> T3.list_projects >>= function
  | Error error -> Lwt.return (Error error)
  | Ok project_page ->
      let hydrate listed errors complete project_ids =
        let rec loop remaining hydrated errors complete =
          match remaining with
          | [] ->
              Lwt.return
                (Ok
                   { listed = List.rev hydrated;
                     project_ids;
                     complete;
                     errors = List.sort_uniq String.compare errors })
          | listed_thread :: rest ->
              T3.read_activity client ~thread_id:listed_thread.thread_id () >>= function
              | Error error ->
                  (* A new root is not advertised from a stale list row when
                     its authoritative lifecycle read failed. *)
                  loop rest hydrated
                    (T3.error_to_string error :: errors) false
              | Ok activity ->
                  (match thread_of_activity ~project_id:listed_thread.project_id activity with
                   | Ok thread -> loop rest (thread :: hydrated) errors complete
                   | Error message -> loop rest hydrated (message :: errors) false)
        in
        loop listed [] errors complete
      in
      let project_ids, project_errors =
        List.fold_left
          (fun (ids, errors) project ->
            match project_id_of_json project with
            | Ok project_id -> (ids @ [ project_id ], errors)
            | Error message -> (ids, errors @ [ message ]))
          ([], []) project_page.items
      in
      let rec collect ids listed errors complete =
        match ids with
        | [] ->
            hydrate (unique_by_thread_id (List.rev listed)) (List.rev errors)
              complete project_ids
        | project_id :: rest ->
            T3.list_threads client ~project_id ~include_subagents:false () >>= function
            | Error error ->
                collect rest listed
                  (T3.error_to_string error :: errors) false
            | Ok page ->
                let parsed, parse_errors =
                  List.fold_left
                    (fun (threads, errors) json ->
                      match thread_of_json ~project_id ~require_lifecycle:false json with
                      | Ok thread -> (thread :: threads, errors)
                      | Error message -> (threads, errors @ [ message ]))
                    ([], []) page.items
                in
                collect rest (List.rev_append parsed listed)
                  (List.rev_append parse_errors errors)
                  (complete && page.complete && parse_errors = [])
      in
      collect project_ids [] project_errors
        (project_page.complete && project_errors = [])

let missing_bound_thread_ids ~(scan : scan) ~(mappings : State.mapping list) =
  if not scan.complete then []
  else
    let listed_ids =
      List.map (fun thread -> thread.thread_id) scan.listed
    in
    mappings
    |> List.filter (fun (mapping : State.mapping) -> mapping.tombstone = None)
    |> List.filter (fun (mapping : State.mapping) ->
         not (List.mem mapping.thread_id listed_ids))
    |> List.map (fun (mapping : State.mapping) -> mapping.thread_id)
    |> List.sort String.compare

type point_read =
  | Present of thread
  | Not_found_same_environment
  | Failed of string

let same_environment_not_found = function
  (* OrchestratorMcpService's external contract uses exactly
     [thread_not_found] for t3_thread_read. Do not broaden this to generic
     HTTP/RPC not-found responses: those can describe an endpoint or project
     failure rather than this same environment's thread. *)
  | T3.Tool_rejected { tool = "t3_thread_read"; code } ->
      String.lowercase_ascii code = "thread_not_found"
  | _ -> false

let error_is_same_environment_not_found = same_environment_not_found

let read_bound_thread (client : T3.client) ~thread_id =
  T3.read_activity client ~thread_id () >|= function
  | Ok activity ->
      (match thread_of_activity ~project_id:"" activity with
       | Ok thread -> Ok (Present thread)
       | Error message -> Ok (Failed message))
  | Error error when same_environment_not_found error -> Ok Not_found_same_environment
  | Error error -> Ok (Failed (T3.error_to_string error))

type candidate = { thread : thread; mapping : State.mapping option }

type plan = {
  routable : candidate list;
  unroutable : (candidate * string) list;
  retire : (State.mapping * string) list;
  degraded : string list;
}

let sort_candidates candidates =
  List.sort (fun a b -> String.compare a.thread.thread_id b.thread.thread_id) candidates

let sort_unroutable values =
  List.sort
    (fun (a, _) (b, _) -> String.compare a.thread.thread_id b.thread.thread_id)
    values

let sort_retire values =
  List.sort
    (fun ((a : State.mapping), _) ((b : State.mapping), _) ->
      String.compare a.thread_id b.thread_id)
    values

let plan_reconciliation ?(credential_access = None) ~scan ~mappings ~point_reads () =
  let mapping_for id =
    List.find_opt
      (fun (mapping : State.mapping) -> mapping.thread_id = id)
      mappings
  in
  let listed_ids = List.map (fun thread -> thread.thread_id) scan.listed in
  let point_read_for id = List.assoc_opt id point_reads in
  let routable = ref [] in
  let unroutable = ref [] in
  let retire = ref [] in
  let degraded = ref scan.errors in
  let add_thread thread mapping =
    match eligibility ~credential_access thread with
    | Routable -> routable := { thread; mapping } :: !routable
    | Permission_ineligible reason ->
        unroutable := ({ thread; mapping }, reason) :: !unroutable
    | Retired reason ->
        (match mapping with
         | Some mapping when mapping.tombstone = None -> retire := (mapping, reason) :: !retire
         | _ -> ())
  in
  List.iter (fun thread -> add_thread thread (mapping_for thread.thread_id)) scan.listed;
  List.iter
    (fun (mapping : State.mapping) ->
      if mapping.tombstone = None && not (List.mem mapping.thread_id listed_ids) then
        if not scan.complete then
          degraded :=
            (Printf.sprintf "incomplete scan retained bound thread %s" mapping.thread_id)
            :: !degraded
        else
          match point_read_for mapping.thread_id with
          | Some (Present thread) -> add_thread thread (Some mapping)
          | Some Not_found_same_environment ->
              retire := (mapping, "thread not found in same T3 environment") :: !retire
          | Some (Failed message) ->
              degraded :=
                (Printf.sprintf "point read failed for %s: %s" mapping.thread_id message)
                :: !degraded
          | None ->
              degraded :=
                (Printf.sprintf "missing point read for bound thread %s" mapping.thread_id)
                :: !degraded)
    mappings;
  { routable = sort_candidates !routable;
    unroutable = sort_unroutable !unroutable;
    retire = sort_retire !retire;
    degraded = List.sort_uniq String.compare !degraded }

type owner = {
  environment_id : string;
  broker : Broker.t;
  pid : int option;
  pid_start_time : int option;
  cwd : string option;
  opaque_host_id : string option;
}

let service_registered_by = "c2c-t3-service"

let service_session_id ~environment_id ~thread_id =
  let frame value = string_of_int (String.length value) ^ ":" ^ value in
  let digest =
    Digestif.SHA256.(to_hex (digest_string (frame environment_id ^ frame thread_id)))
  in
  "t3-svc-" ^ String.sub digest 0 24

let registration_for owner (mapping : State.mapping) =
  let session_id =
    service_session_id ~environment_id:owner.environment_id ~thread_id:mapping.thread_id
  in
  List.find_opt
    (fun (registration : C2c_mcp.registration) ->
      Broker.alias_casefold registration.alias = Broker.alias_casefold mapping.alias)
    (Broker.list_registrations owner.broker),
  session_id

let publish_mapping ~owner ~mapping =
  match owner.pid, owner.pid_start_time with
  | None, _ | _, None -> Error "T3 service registration requires PID and start-time ownership"
  | Some _, Some _ ->
      let existing, session_id = registration_for owner mapping in
      (match existing with
       | Some registration
         when registration.session_id <> session_id
              || registration.registered_by <> Some service_registered_by ->
           Error
             (Printf.sprintf
                "refusing to take over foreign registration for alias %s"
                mapping.alias)
       | _ ->
           try
             Broker.register owner.broker ~session_id ~alias:mapping.alias ~pid:owner.pid
               ~pid_start_time:owner.pid_start_time ~client_type:(Some "t3")
               ~cwd:owner.cwd ~metadata_opt_out:true
               ~registered_by:(Some service_registered_by)
               ~opaque_host_id:owner.opaque_host_id ~from_auto_gen:true ();
             Ok ()
           with
           | Invalid_argument message -> Error message
           | exn -> Error ("could not publish T3 alias: " ^ Printexc.to_string exn))

let unpublish_mapping ~owner ~mapping =
  let existing, session_id = registration_for owner mapping in
  match existing with
  | None -> Ok ()
  | Some registration
    when registration.session_id = session_id
         && registration.registered_by = Some service_registered_by ->
      ignore (Broker.deregister owner.broker ~alias:mapping.alias);
      Ok ()
  | Some registration ->
      Error
        (Printf.sprintf "refusing to remove foreign registration for alias %s (session %s)"
           mapping.alias registration.session_id)

type apply_result = {
  published : candidate list;
  held : (candidate * string) list;
  retired : (State.mapping * string) list;
  errors : string list;
}

let active_mapping ~environment_id state candidate =
  match State.find_by_thread state ~thread_id:candidate.thread.thread_id with
  | Some mapping when mapping.tombstone <> None -> State.revive_mapping state ~thread_id:mapping.thread_id
  | Some mapping -> Ok mapping
  | None ->
      let alias =
        State.alias_of_environment_thread ~environment_id
          ~thread_id:candidate.thread.thread_id
      in
      State.ensure_mapping_with_alias state ~thread_id:candidate.thread.thread_id ~alias

let apply_plan ~owner ~state ~plan =
  let published = ref [] in
  let held = ref [] in
  let errors = ref [] in
  (* A prior crash may have removed the durable route after the state write
     but before broker cleanup. Reconcile any service-owned tombstone on every
     pass; never touch a foreign row. *)
  State.mappings state
  |> List.filter (fun (mapping : State.mapping) -> mapping.tombstone <> None)
  |> List.iter (fun mapping ->
       match unpublish_mapping ~owner ~mapping with
       | Ok () -> ()
       | Error message -> errors := message :: !errors);
  List.iter
    (fun candidate ->
      match active_mapping ~environment_id:owner.environment_id state candidate with
      | Error message -> held := (candidate, message) :: !held
      | Ok mapping ->
          (match publish_mapping ~owner ~mapping with
           | Ok () -> published := { candidate with mapping = Some mapping } :: !published
           | Error message -> held := ({ candidate with mapping = Some mapping }, message) :: !held))
    plan.routable;
  List.iter
    (fun (candidate, reason) ->
      match candidate.mapping with
      | None -> ()
      | Some mapping ->
          (match unpublish_mapping ~owner ~mapping with
           | Ok () -> ()
           | Error message -> errors := message :: !errors))
    plan.unroutable;
  let retired = ref [] in
  List.iter
    (fun (mapping, reason) ->
      match unpublish_mapping ~owner ~mapping with
      | Error message -> errors := message :: !errors
      | Ok () ->
          (match State.tombstone state ~thread_id:mapping.thread_id ~reason with
           | Ok () -> retired := (mapping, reason) :: !retired
           | Error message -> errors := message :: !errors))
    plan.retire;
  { published = List.rev !published;
    held = List.rev !held;
    retired = List.rev !retired;
    errors = List.rev !errors }

type locator_result =
  | Alias of string
  | Thread_alias of string
  | Ambiguous_thread of string
  | Unknown_thread of string

let resolve_locator ~mappings ~registered_aliases locator =
  let canonical_alias () =
    List.find_opt
      (fun alias -> String.lowercase_ascii alias = String.lowercase_ascii locator)
      registered_aliases
  in
  match canonical_alias () with
  | Some alias -> Alias alias
  | None when String.length locator >= 3 && String.sub locator 0 3 = "t3." ->
      let thread_id = String.sub locator 3 (String.length locator - 3) in
      let matches =
        List.filter
          (fun (mapping : State.mapping) ->
            mapping.tombstone = None && mapping.thread_id = thread_id)
          mappings
      in
      (match matches with
       | [ mapping ] -> Thread_alias mapping.alias
       | [] -> Unknown_thread thread_id
       | _ -> Ambiguous_thread thread_id)
  | None -> Alias locator
