open Lwt.Infix

module T3 = C2c_t3_client
module State = C2c_t3_state

type failure = {
  item_id : string;
  run_id : string;
  source_thread_id : string option;
  status : string option;
  message : string option;
}

type candidate = {
  thread_id : string;
  run_id : string;
  error_ids : string list;
  error_fingerprint : string;
  provider_instance_id : string;
  model : string;
  request_id : string;
  key : string;
}

type decision = Eligible of candidate | Held of string

let lower = String.lowercase_ascii

let contains ~needle haystack =
  let needle = lower needle and haystack = lower haystack in
  let n = String.length needle and h = String.length haystack in
  n > 0 && n <= h
  && (let rec loop i =
         i + n <= h
         && (String.sub haystack i n = needle || loop (i + 1))
      in loop 0)

let any needle haystack = List.exists (fun n -> contains ~needle:n haystack) needle

let availability_message message =
  let denied =
    [ "auth"; "unauthor"; "permission"; "forbidden"; "account"; "access";
      "subscription"; "quota"; "usage limit"; "rate limit"; "billing";
      "context limit"; "token limit"; "workspace"; "configuration";
      "invalid model"; "connection"; "transport"; "timeout"; "approval" ]
  in
  let has_model = contains ~needle:"model" message in
  (* Keep this deliberately narrower than a generic provider retry matcher.
     The external T3 activity contract gives us message text, but no failure
     code or node attribution.  In particular, "model not found" and
     "unsupported model" are commonly permanent configuration errors. *)
  let unavailable = any [ "unavailable"; "not available" ] message in
  let temporary_capacity =
    (contains ~needle:"temporar" message || contains ~needle:"capacity" message)
    && any [ "overloaded"; "at capacity"; "busy" ] message
  in
  has_model && (unavailable || temporary_capacity) && not (any denied message)

(* The root-error invariant was measured against the external T3 0.1.0 and 0.1.1
   contract on both rollout hosts.  Unknown versions must hold recovery until
   their activity/error shape has been measured; normal c2c delivery remains
   available. *)
let supported_server_version = function
  | Some version -> List.mem (String.trim version) [ "0.1.0"; "0.1.1" ]
  | None -> false

let version_hold_reason = function
  | Some version when supported_server_version (Some version) -> None
  | Some version -> Some ("T3 server version is not verified for recovery: " ^ String.trim version)
  | None -> Some "T3 server version is unknown; recovery is held"

let member key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let string_at keys json =
  List.find_map
    (fun key -> match member key json with Some (`String s) -> Some s | _ -> None)
    keys

let item_type json = string_at [ "itemType"; "type"; "kind" ] json

let failure_object json =
  match member "failure" json with Some (`Assoc _ as f) -> Some f | _ -> None

let failure_of_json ~thread_id json =
  match item_type json with
  | Some kind when lower kind = "error" ->
      let nested = Option.value (failure_object json) ~default:json in
      let run_id = string_at [ "runId"; "run_id" ] json in
      let item_id = string_at [ "itemId"; "id" ] json in
      (match item_id, run_id with
       | Some item_id, Some run_id ->
           Some
             { item_id; run_id;
               source_thread_id = string_at [ "sourceThreadId"; "threadId"; "source_thread_id" ] json;
               status = (match string_at [ "status" ] nested with
                         | Some _ as value -> value
                         | None -> string_at [ "status" ] json);
               message = (match string_at [ "message" ] nested with
                          | Some _ as value -> value
                          | None -> string_at [ "message"; "errorMessage"; "text" ] json) }
       | _ -> None)
  | _ -> None

let failures_of_activity ~thread_id (activity : T3.activity) =
  List.filter_map (failure_of_json ~thread_id) activity.items

let has_malformed_error activity =
  List.exists
    (fun item ->
      match item_type item with
      | Some kind when lower kind = "error" -> failure_of_json ~thread_id:"" item = None
      | _ -> false)
    activity.T3.items

let digest seed = Digestif.SHA256.(to_hex (digest_string seed))

let frame value = string_of_int (String.length value) ^ ":" ^ value

let identity ~environment_id ~thread_id ~run_id =
  digest (frame environment_id ^ frame thread_id ^ frame run_id)

let candidate ~environment_id ~credential_generation:_ ~thread_id ~run_id
    ~provider_instance_id ~model ~error_ids ~error_fingerprint =
  let error_ids = List.sort_uniq String.compare error_ids in
  let key = "recovery:" ^ identity ~environment_id ~thread_id ~run_id in
  let request_id = "c2c-t3-recovery-" ^ String.sub (digest (key ^ error_fingerprint)) 0 32 in
  { thread_id; run_id; error_ids; error_fingerprint; provider_instance_id; model; request_id; key }

let candidate_equal left right =
  left.thread_id = right.thread_id
  && left.run_id = right.run_id
  && left.error_fingerprint = right.error_fingerprint
  && left.provider_instance_id = right.provider_instance_id
  && left.model = right.model
  && List.sort_uniq String.compare left.error_ids
     = List.sort_uniq String.compare right.error_ids

let candidate_of_entry (entry : State.entry) =
  let required_string key =
    match string_at [ key ] entry.payload with
    | Some value when String.trim value <> "" -> Ok value
    | _ -> Error ("recovery journal entry missing " ^ key)
  in
  let error_ids =
    match member "error_ids" entry.payload with
    | Some (`List values) ->
        let ids = List.filter_map (function `String value -> Some value | _ -> None) values in
        if List.length ids = List.length values && ids <> [] then Ok ids
        else Error "recovery journal entry has invalid error_ids"
    | _ -> Error "recovery journal entry missing error_ids"
  in
  match required_string "thread_id", required_string "run_id",
        required_string "provider_instance_id", required_string "model",
        required_string "error_fingerprint", error_ids with
  | Ok thread_id, Ok run_id, Ok provider_instance_id, Ok model,
    Ok error_fingerprint, Ok error_ids ->
      Ok { thread_id; run_id; error_ids = List.sort_uniq String.compare error_ids;
           error_fingerprint;
           provider_instance_id; model;
           request_id = Option.value (string_at [ "request_id" ] entry.payload)
             ~default:("c2c-t3-recovery-" ^ String.sub (digest (entry.key ^ error_fingerprint)) 0 32);
           key = entry.key }
  | Error error, _, _, _, _, _ | _, Error error, _, _, _, _
  | _, _, Error error, _, _, _ | _, _, _, Error error, _, _
  | _, _, _, _, Error error, _ | _, _, _, _, _, Error error -> Error error

let known_bool = function T3.Known b -> Some b | T3.Unknown -> None
let known_string = function T3.Known s -> Some s | T3.Unknown -> None
let known_opt_string = function T3.Known value -> value | T3.Unknown -> None
let option_for_all predicate = function None -> true | Some value -> predicate value

let run_status run = known_string run.T3.status |> Option.map lower

let latest_run activity =
  match activity.T3.recent_runs with
  | [] -> Error "no bounded run history"
  | run :: _ ->
      (* The MCP contract returns recentRuns in newest-first order.  Refuse a
         bounded list at its limit because an older page may hide a newer run
         on servers that truncate this collection. *)
      if not activity.T3.runs_complete then Error "run history is truncated"
      else Ok run

let activity_hold activity =
  let bool_hold name = function
    | T3.Known true -> Some (name ^ " is set")
    | T3.Known false -> None
    | T3.Unknown -> Some (name ^ " is unknown")
  in
  let int_hold name = function
    | T3.Known n when n = 0 -> None
    | T3.Known _ -> Some (name ^ " is non-zero")
    | T3.Unknown -> Some (name ^ " is unknown")
  in
  let string_hold name = function
    | T3.Known value when lower value = "" -> Some (name ^ " is empty")
    | T3.Known _ -> None
    | T3.Unknown -> Some (name ^ " is unknown")
  in
  List.find_map Fun.id
    [ (match activity.T3.active_run_id with
       | T3.Known None -> None
       | T3.Known (Some _) -> Some "thread has an active run"
       | T3.Unknown -> Some "active run is unknown");
      int_hold "pending request count" activity.T3.pending_request_count;
      bool_hold "settled" activity.T3.settled;
      bool_hold "archived" activity.T3.archived;
      bool_hold "deleted" activity.T3.deleted;
      bool_hold "snooze" activity.T3.snoozed;
      string_hold "runtime mode" activity.T3.runtime_mode;
      (match activity.T3.runtime_mode with
       | T3.Known mode when lower mode = "full-access" -> Some "full-access root is ineligible"
       | _ -> None);
      (if activity.T3.complete then None else Some "activity history is incomplete");
      (if activity.T3.text_truncated then Some "activity error text is truncated" else None) ]

let has_stop_marker ~thread_id ~run_id activity =
  List.exists
    (fun item ->
      let kind = string_at [ "itemType"; "type"; "kind" ] item in
      let item_run = string_at [ "runId"; "run_id" ] item in
      (match kind with
       | Some value ->
           let value = lower value in
           value = "run_interrupt_request" || value = "run-interrupt-request"
       | None -> false)
      && item_run = Some run_id
      && (match string_at [ "threadId"; "sourceThreadId" ] item with
          | None -> true
          | Some value -> value = thread_id))
    activity.T3.items

let decide ~environment_id ~credential_generation ~thread_id ~driver_kind
    ~provider_instance_id ~model (activity : T3.activity) (queue : T3.queue) =
  let hold reason = Held reason in
  let evaluate provider_instance_id model =
    match provider_instance_id, model with
    | Some provider_instance_id, Some model
      when String.trim provider_instance_id <> "" && String.trim model <> "" ->
        (match latest_run activity with
         | Error reason -> hold reason
         | Ok run ->
             (match run_status run with
              | Some "failed" ->
                  let failures = failures_of_activity ~thread_id activity in
                  let same_run = List.filter (fun (f : failure) -> f.run_id = run.run_id) failures in
                  if has_stop_marker ~thread_id ~run_id:run.run_id activity then
                    hold "thread has a stop marker"
                  else if has_malformed_error activity then
                    hold "activity contains an unparseable error row"
                  else if same_run = [] then hold "failed run has no local error evidence"
                  else if List.exists (fun (f : failure) -> f.source_thread_id <> Some thread_id) same_run then
                    hold "failed run has child or foreign error evidence"
                  else if List.exists (fun (f : failure) -> f.status <> Some "failed") same_run then
                    hold "failed run has retrying or unknown error status"
                  else if List.exists (fun (f : failure) -> option_for_all (fun m -> not (availability_message m)) f.message) same_run then
                    hold "failed run has non-availability error evidence"
                  else
                    Eligible
                      (candidate ~environment_id ~credential_generation ~thread_id
                         ~run_id:run.run_id ~provider_instance_id ~model
                         ~error_ids:(List.map (fun (f : failure) -> f.item_id) same_run)
                         ~error_fingerprint:
                           (digest
                              (String.concat "\000"
                                 (List.sort String.compare
                                    (List.map
                                       (fun (f : failure) ->
                                         f.item_id ^ "\000" ^ Option.value ~default:"" f.status
                                         ^ "\000" ^ Option.value ~default:"" f.message)
                                       same_run)))))
              | Some "active" | Some "running" | Some "queued" -> hold "latest run is not failed"
              | Some status -> hold ("latest run status is " ^ status)
              | None -> hold "latest run status is unknown"))
    | Some _, Some _ -> hold "provider identity or model is invalid"
    | _ -> hold "provider identity or model is unknown"
  in
  match driver_kind with
  | Some kind when lower kind = "codex" ->
      (match activity.T3.parent_thread_id with
       | T3.Known (Some _) -> hold "thread has a parent"
       | T3.Unknown -> hold "thread lineage is unknown"
       | T3.Known None ->
           (match activity_hold activity with
            | Some reason -> hold reason
            | None ->
                (match queue.T3.queue_complete, queue.T3.queued_run_ids with
                 | false, _ -> hold "queue state is incomplete"
                 | true, _ :: _ -> hold "thread has queued work"
                 | true, [] -> evaluate provider_instance_id model)))
  | Some _ -> hold "thread provider is not Codex"
  | None -> hold "thread provider is unknown"

let enqueue ~state ~environment_id ~credential_generation ~now candidate =
  let payload =
    `Assoc
      [ ("version", `Int 1); ("kind", `String "recovery"); ("status", `String "pending");
        ("environment_id", `String environment_id); ("thread_id", `String candidate.thread_id);
        ("run_id", `String candidate.run_id); ("error_ids", `List (List.map (fun s -> `String s) candidate.error_ids));
        ("error_fingerprint", `String candidate.error_fingerprint);
        ("provider_instance_id", `String candidate.provider_instance_id);
        ("model", `String candidate.model); ("message", `String "Continue");
        ("formatted", `String "Continue"); ("mode", `String "queue");
        ("request_id", `String candidate.request_id); ("attempts", `Int 0);
        ("next_attempt_at", `Float now); ("credential_generation", `Int credential_generation) ]
  in
  match State.journal_append state ~kind:State.Recovery ~key:candidate.key ~payload with
  | Error error -> Error error
  | Ok State.Duplicate -> Ok `Duplicate
  | Ok (State.Appended _) -> Ok `Appended

let can_dispatch ~enabled (entry : State.entry) = enabled || entry.State.kind <> State.Recovery

let float_member key json =
  match member key json with
  | Some (`Float value) -> Some value
  | Some (`Int value) -> Some (float_of_int value)
  | _ -> None

let recovery_thread entry = string_at [ "thread_id" ] entry.State.payload

let hold_reason ~state ~thread_id ~candidate ~now =
  let different_pending =
    List.exists
      (fun (entry : State.entry) ->
        entry.kind = State.Recovery
        && recovery_thread entry = Some thread_id
        && entry.key <> candidate.key)
      (State.journal_pending state)
  in
  if different_pending then Some "recovery intent already pending for thread"
  else
    let submitted_at_from_pending =
      List.filter_map
        (fun (entry : State.entry) ->
          if entry.kind = State.Recovery && recovery_thread entry = Some thread_id then
            float_member "last_submission_at" entry.payload
          else None)
        (State.journal_pending state)
    in
    let submitted_at_from_acked =
      List.filter_map
        (fun (entry : State.acked_entry) ->
          match entry.kind, entry.result with
          | State.Recovery, Some result
            when string_at [ "thread_id" ] result = Some thread_id ->
              float_member "submitted_at" result
          | _ -> None)
        (State.journal_acked ~kind:State.Recovery state)
    in
    let latest =
      List.fold_left
        (fun acc value -> Some (max value (Option.value ~default:neg_infinity acc)))
        None (submitted_at_from_pending @ submitted_at_from_acked)
    in
    match latest with
    | Some at when now < at +. 60. -> Some "recovery thread cool-down is active"
    | _ -> None

type sweep_result = {
  checked : int;
  enqueued : candidate list;
  duplicates : candidate list;
  held : (string * string) list;
  errors : (string * string) list;
}

type operations = {
  capabilities : unit -> (T3.capabilities, T3.error) result Lwt.t;
  read_activity : string -> (T3.activity, T3.error) result Lwt.t;
  list_queue : string -> (T3.queue, T3.error) result Lwt.t;
}

let activity_thread_id activity =
  string_at [ "threadId"; "thread_id"; "id" ] activity.T3.thread_raw

let preflight_with ~operations ~environment_id ~credential_generation ~candidate () =
  operations.capabilities () >>= function
  | Error error -> Lwt.return (Error (T3.error_to_string error))
  | Ok capabilities ->
      let provider_for id =
        List.find_map
          (fun (p : T3.provider) ->
             if known_string p.provider_instance_id = Some id then
               known_string p.driver_kind
             else None)
          capabilities.T3.providers
      in
      operations.read_activity candidate.thread_id >>= function
      | Error error -> Lwt.return (Error (T3.error_to_string error))
      | Ok activity ->
          (* The typed client receives a requested thread ID, so also validate
             the raw authoritative identity when the server supplies it.  A
             mismatched object must never be treated as a fresh root read. *)
          (match activity_thread_id activity with
           | Some id when id <> candidate.thread_id ->
               Lwt.return (Error "preflight thread identity changed")
           | None -> Lwt.return (Error "preflight thread identity is missing")
           | Some _ ->
               operations.list_queue candidate.thread_id >>= function
               | Error error -> Lwt.return (Error (T3.error_to_string error))
               | Ok queue ->
                   let provider_id = known_opt_string activity.T3.provider_instance_id in
                   let driver_kind = Option.bind provider_id provider_for in
                   let model = known_opt_string activity.T3.model in
                   (match decide ~environment_id ~credential_generation
                            ~thread_id:candidate.thread_id ~driver_kind
                            ~provider_instance_id:provider_id ~model activity queue with
                    | Held reason -> Lwt.return (Error ("preflight: " ^ reason))
                    | Eligible fresh when candidate_equal candidate fresh ->
                        Lwt.return (Ok ())
                    | Eligible _ ->
                        Lwt.return (Error "preflight evidence or provider identity changed")))

let sweep_with ?(enabled = true) ~operations ~state ~environment_id ~credential_generation
    ~thread_ids ~clock () =
  if not enabled then
    Lwt.return { checked = 0; enqueued = []; duplicates = []; held = []; errors = [] }
  else
    operations.capabilities () >>= function
    | Error error ->
        Lwt.return { checked = 0; enqueued = []; duplicates = []; held = [];
                     errors = [ ("<capabilities>", T3.error_to_string error) ] }
    | Ok capabilities ->
        let provider_for id =
          List.find_map
            (fun (p : T3.provider) ->
              if known_string p.provider_instance_id = Some id then known_string p.driver_kind else None)
            capabilities.T3.providers
        in
        let rec loop checked enqueued duplicates held errors = function
          | [] -> Lwt.return { checked; enqueued = List.rev enqueued; duplicates = List.rev duplicates;
                               held = List.rev held; errors = List.rev errors }
          | thread_id :: rest ->
              operations.read_activity thread_id >>= function
              | Error error -> loop checked enqueued duplicates held
                  ((thread_id, T3.error_to_string error) :: errors) rest
              | Ok activity ->
                  operations.list_queue thread_id >>= function
                  | Error error -> loop (checked + 1) enqueued duplicates held
                      ((thread_id, T3.error_to_string error) :: errors) rest
                  | Ok queue ->
                      let provider_id = known_opt_string activity.T3.provider_instance_id in
                      let driver_kind = Option.bind provider_id provider_for in
                      let model = known_opt_string activity.T3.model in
                      (match decide ~environment_id ~credential_generation ~thread_id
                               ~driver_kind ~provider_instance_id:provider_id ~model activity queue with
                       | Held reason -> loop (checked + 1) enqueued duplicates ((thread_id, reason) :: held) errors rest
                       | Eligible candidate ->
                           let now = clock () in
                           (match hold_reason ~state ~thread_id ~candidate ~now with
                            | Some reason -> loop (checked + 1) enqueued duplicates ((thread_id, reason) :: held) errors rest
                            | None ->
                                (match enqueue ~state ~environment_id ~credential_generation
                                         ~now candidate with
                                 | Error error -> loop (checked + 1) enqueued duplicates held
                                     ((thread_id, error) :: errors) rest
                                 | Ok `Appended -> loop (checked + 1) (candidate :: enqueued) duplicates held errors rest
                                 | Ok `Duplicate -> loop (checked + 1) enqueued (candidate :: duplicates) held errors rest)))
        in
        loop 0 [] [] [] [] (List.sort_uniq String.compare thread_ids)

let sweep ?(enabled = true) ~client ~state ~environment_id ~credential_generation
    ~thread_ids ~clock () =
  sweep_with ~enabled
    ~operations:
      { capabilities = (fun () -> T3.capabilities client);
        read_activity = (fun thread_id -> T3.read_activity client ~thread_id ());
        list_queue = (fun thread_id -> T3.list_queue client ~thread_id) }
    ~state ~environment_id ~credential_generation ~thread_ids ~clock ()

type cadence = { interval : float; mutable next_at : float; mutable running : bool }

let create_cadence ?(interval = 60.) ?(initial_delay = 0.) ~clock () =
  if interval <= 0. then invalid_arg "recovery cadence interval must be positive";
  { interval; next_at = clock () +. initial_delay; running = false }

let cadence_due cadence ~now =
  if cadence.running then `Running
  else if now >= cadence.next_at then `Due
  else `Waiting (cadence.next_at -. now)

let cadence_start cadence ~now =
  match cadence_due cadence ~now with
  | `Due -> cadence.running <- true; true
  | `Waiting _ | `Running -> false

let cadence_finish cadence ~now =
  (* Always schedule from completion.  A slow sweep therefore cannot create a
     catch-up burst of immediate sweeps. *)
  cadence.running <- false;
  cadence.next_at <- now +. cadence.interval
