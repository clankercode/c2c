(** c2c relay connector — bridges a local broker root to a remote relay server.

    Replaces the Python c2c_relay_connector.py with a native OCaml implementation.

    Responsibilities:
    1. Register local aliases with the relay (on startup and on re-registration).
    2. Forward outbound remote-→local messages to the relay via POST /send.
    3. Pull local-→remote messages from the relay and deliver into local inboxes.
    4. Send periodic heartbeats to keep relay leases alive.

    Backend selection: controlled by C2C_RELAY_CONNECTOR_BACKEND env var.
    "ocaml" → native OCaml implementation (this module).
    Anything else → falls back to Python connector (c2c_relay_connector.py).

    {b Slices}
    1. Stub + config + backend flag
    2. Core sync loop (register, heartbeat, poll_inbox, deliver)
    3. Outbox forwarding
    4. CLI wiring
    5. Flip default to OCaml *)

let ( // ) = Filename.concat

let return = Lwt.return
let (>>=) = Lwt.Infix.(>>=)

(* ---------------------------------------------------------------------------
 * Backend selection
 * --------------------------------------------------------------------------- *)

let is_ocaml_backend () =
  match Sys.getenv_opt "C2C_RELAY_CONNECTOR_BACKEND" with
  | Some "python" -> false
  | _ -> true

(* ---------------------------------------------------------------------------
 * Types
 * --------------------------------------------------------------------------- *)

type sync_error = {
  err_op : string;
  err_detail : string;
  err_ts : float;
}

type sync_result = {
  registered : string list;
  (* B209: the exact (alias, session_id) bindings this connector has
     registered on the relay this sync. The relay keys each lease by
     (node_id, session_id) and enforces ONE lease row per alias
     (ON CONFLICT(alias) DO UPDATE), so a connector register moves the
     alias's live lease from the CLI convention (cli-<alias>/cli-<alias>)
     to (connector node_id, this session_id). Persisting the session_id
     lets a `c2c monitor` peek the EXACT binding the connector established
     instead of guessing cli-<alias> and hitting signature_invalid. *)
  registered_sessions : (string * string) list;
  heartbeated : string list;
  outbox_forwarded : int;
  outbox_failed : int;
  outbox_dlqed : int;  (* entries moved to local DLQ this sync *)
  inbound_delivered : int;
  inbound_rejected : int;  (* schema- or B196 policy-rejected rows this sync *)
  alerts_emitted : int;  (* B010: c2c-system alert messages injected this sync *)
  rate_limited : bool;
  (* B210: this sync pass observed a relay rate-limit rejection (HTTP 429 /
     error_code=rate_limit_exceeded). The run loops use this to grow a bounded,
     jittered backoff so N concurrent connectors on a shared host do not
     resynchronise into a machine-wide 429 storm. *)
  (* B244: max retry_after (seconds) observed on any 429 this pass, when the
     relay advertised one. Drives backoff pacing so NAT-shared IP buckets can
     refill instead of being re-hit every base interval. *)
  retry_after_s : float option;
  last_error : sync_error option;
}

(* B196: relay ingress is untrusted.  These limits are enforced locally,
   after polling but before any row is appended to a broker inbox.  A sliding
   window is deliberately used here: it is deterministic, bounded by the
   configured message count, and does not make the relay a policy authority. *)
type inbound_rate = {
  rate_messages : int;
  rate_window_s : float;
}

type inbound_action =
  | Inbound_allow
  | Inbound_deny

type inbound_sender_policy = {
  sender_action : inbound_action;
  sender_max_bytes : int;
  sender_rate : inbound_rate;
}

type inbound_recipient_policy = {
  recipient_enabled : bool;
  recipient_max_bytes : int;
  recipient_rate : inbound_rate;
}

type inbound_policy = {
  default_sender_action : inbound_action;
  default_max_bytes : int;
  default_sender_rate : inbound_rate;
  default_recipient_rate : inbound_rate;
  machine_rate : inbound_rate;
  sender_overrides : (string * inbound_sender_policy) list;
  recipient_overrides : (string * inbound_recipient_policy) list;
}

type inbound_rate_state = {
  mutable machine_events : float list;
  sender_events : (string, float list) Hashtbl.t;
  recipient_events : (string, float list) Hashtbl.t;
}

type inbound_rejection =
  | Inbound_schema
  | Inbound_policy
  | Inbound_sender_denied
  | Inbound_recipient_mismatch
  | Inbound_recipient_disabled
  | Inbound_oversize
  | Inbound_sender_rate
  | Inbound_recipient_rate
  | Inbound_machine_rate

let default_inbound_policy = {
  default_sender_action = Inbound_allow;
  default_max_bytes = 256 * 1024;
  default_sender_rate = { rate_messages = 60; rate_window_s = 60.0 };
  default_recipient_rate = { rate_messages = 120; rate_window_s = 60.0 };
  machine_rate = { rate_messages = 600; rate_window_s = 60.0 };
  sender_overrides = [];
  recipient_overrides = [];
}

let create_inbound_rate_state () = {
  machine_events = [];
  sender_events = Hashtbl.create 17;
  recipient_events = Hashtbl.create 17;
}

let inbound_policy_path broker_root =
  match Sys.getenv_opt "C2C_RELAY_INBOUND_POLICY_FILE" with
  | Some path when String.trim path <> "" -> path
  | _ -> broker_root // "relay-inbound-policy.json"

let inbound_config_error field detail =
  Error (Printf.sprintf "invalid relay inbound policy field %s: %s" field detail)

let validate_object_fields ~context ~allowed fields =
  let rec loop seen = function
    | [] -> Ok ()
    | (key, _) :: rest ->
        if List.mem key seen then inbound_config_error context ("duplicate key " ^ key)
        else if not (List.mem key allowed) then
          inbound_config_error context ("unknown key " ^ key)
        else loop (key :: seen) rest
  in
  loop [] fields

let positive_int fields field ~default =
  match List.assoc_opt field fields with
  | None -> Ok default
  | Some (`Int n) when n > 0 -> Ok n
  | Some _ -> inbound_config_error field "expected a positive integer"

let positive_float fields field ~default =
  match List.assoc_opt field fields with
  | None -> Ok default
  | Some (`Int n) when n > 0 -> Ok (float_of_int n)
  | Some (`Float n) when Float.is_finite n && n > 0.0 -> Ok n
  | Some _ -> inbound_config_error field "expected a positive finite number"

let bool_value fields field ~default =
  match List.assoc_opt field fields with
  | None -> Ok default
  | Some (`Bool b) -> Ok b
  | Some _ -> inbound_config_error field "expected a boolean"

let parse_inbound_action ~field ~default = function
  | None -> Ok default
  | Some (`String action) ->
      (match String.lowercase_ascii (String.trim action) with
       | "allow" -> Ok Inbound_allow
       | "deny" -> Ok Inbound_deny
       | _ -> inbound_config_error field "expected \"allow\" or \"deny\"")
  | Some _ -> inbound_config_error field "expected \"allow\" or \"deny\""

let parse_inbound_rate ~field ~default = function
  | None -> Ok default
  | Some (`Assoc fields) ->
      (match validate_object_fields ~context:field
               ~allowed:[ "messages"; "window_seconds" ] fields with
       | Error _ as e -> e
       | Ok () -> match positive_int fields "messages" ~default:default.rate_messages with
       | Error _ as e -> e
       | Ok rate_messages ->
           match positive_float fields "window_seconds"
                   ~default:default.rate_window_s with
           | Error _ as e -> e
           | Ok rate_window_s -> Ok { rate_messages; rate_window_s })
  | Some _ -> inbound_config_error field "expected an object"

let parse_inbound_sender ~default_action ~default_max_bytes ~default_rate alias = function
  | `Assoc fields ->
      (match validate_object_fields ~context:alias
               ~allowed:[ "action"; "max_bytes"; "rate" ] fields with
       | Error _ as e -> e
       | Ok () -> match parse_inbound_action ~field:(alias ^ ".action")
                          ~default:default_action (List.assoc_opt "action" fields) with
       | Error _ as e -> e
       | Ok sender_action ->
           match positive_int fields "max_bytes" ~default:default_max_bytes with
           | Error _ as e -> e
           | Ok sender_max_bytes ->
           match parse_inbound_rate ~field:(alias ^ ".rate")
                   ~default:default_rate (List.assoc_opt "rate" fields) with
           | Error _ as e -> e
           | Ok sender_rate -> Ok {
               sender_action;
               sender_max_bytes;
               sender_rate;
             })
  | _ -> inbound_config_error alias "expected an object"

let parse_inbound_recipient ~default_max_bytes ~default_rate alias = function
  | `Assoc fields ->
      (match validate_object_fields ~context:alias
               ~allowed:[ "enabled"; "max_bytes"; "rate" ] fields with
       | Error _ as e -> e
       | Ok () -> match bool_value fields "enabled" ~default:true with
       | Error _ as e -> e
       | Ok recipient_enabled ->
           match positive_int fields "max_bytes" ~default:default_max_bytes with
           | Error _ as e -> e
           | Ok recipient_max_bytes ->
               match parse_inbound_rate ~field:(alias ^ ".rate")
                       ~default:default_rate (List.assoc_opt "rate" fields) with
               | Error _ as e -> e
               | Ok recipient_rate -> Ok {
                   recipient_enabled;
                   recipient_max_bytes;
                   recipient_rate;
                 })
  | _ -> inbound_config_error alias "expected an object"

let parse_casefolded_overrides ~field ~parse_entry = function
  | None -> Ok []
  | Some (`Assoc entries) ->
      let rec parse acc = function
        | [] -> Ok (List.rev acc)
        | (alias, json) :: rest ->
            let alias = String.trim alias in
            let key = String.lowercase_ascii alias in
            if alias = "" then
              inbound_config_error field "alias is empty"
            else if List.mem_assoc key acc then
              inbound_config_error field
                ("duplicate case-insensitive alias " ^ alias)
            else
              match parse_entry alias json with
              | Error _ as e -> e
              | Ok policy -> parse ((key, policy) :: acc) rest
      in
      parse [] entries
  | Some _ -> inbound_config_error field "expected an object"

let parse_inbound_policy = function
  | `Assoc fields ->
      (match validate_object_fields ~context:"root"
               ~allowed:[ "default_sender_action"; "default_max_bytes";
                          "default_sender_rate"; "default_recipient_rate";
                          "machine_rate"; "senders"; "recipients" ] fields with
       | Error _ as e -> e
       | Ok () -> match parse_inbound_action ~field:"default_sender_action"
                          ~default:default_inbound_policy.default_sender_action
                          (List.assoc_opt "default_sender_action" fields) with
       | Error _ as e -> e
       | Ok default_sender_action ->
           match positive_int fields "default_max_bytes"
               ~default:default_inbound_policy.default_max_bytes with
       | Error _ as e -> e
       | Ok default_max_bytes ->
           match parse_inbound_rate ~field:"default_sender_rate"
                   ~default:default_inbound_policy.default_sender_rate
                   (List.assoc_opt "default_sender_rate" fields) with
           | Error _ as e -> e
           | Ok default_sender_rate ->
               match parse_inbound_rate ~field:"default_recipient_rate"
                       ~default:default_inbound_policy.default_recipient_rate
                       (List.assoc_opt "default_recipient_rate" fields) with
               | Error _ as e -> e
               | Ok default_recipient_rate ->
               match parse_inbound_rate ~field:"machine_rate"
                       ~default:default_inbound_policy.machine_rate
                       (List.assoc_opt "machine_rate" fields) with
               | Error _ as e -> e
               | Ok machine_rate ->
                   match parse_casefolded_overrides ~field:"senders"
                           ~parse_entry:(parse_inbound_sender
                             ~default_action:default_sender_action
                             ~default_max_bytes
                             ~default_rate:default_sender_rate)
                           (List.assoc_opt "senders" fields) with
                   | Error _ as e -> e
                   | Ok sender_overrides ->
                       match parse_casefolded_overrides ~field:"recipients"
                               ~parse_entry:(parse_inbound_recipient
                                 ~default_max_bytes
                                 ~default_rate:default_recipient_rate)
                               (List.assoc_opt "recipients" fields) with
                       | Error _ as e -> e
                       | Ok recipient_overrides -> Ok {
                           default_sender_action;
                           default_max_bytes;
                           default_sender_rate;
                           default_recipient_rate;
                           machine_rate;
                           sender_overrides;
                           recipient_overrides;
                         })
  | _ -> inbound_config_error "root" "expected an object"

let load_inbound_policy broker_root =
  let path = inbound_policy_path broker_root in
  if not (Sys.file_exists path) then Ok default_inbound_policy
  else
    match C2c_io.read_json_opt path with
    | None -> Error (Printf.sprintf "cannot parse relay inbound policy %s" path)
    | Some json -> parse_inbound_policy json

let inbound_rate_state_path broker_root =
  broker_root // "relay-inbound-rate-state.json"

let inbound_rate_lock_path broker_root =
  broker_root // "relay-inbound-rate-state.lock"

let with_inbound_rate_lock broker_root f =
  let fd =
    Unix.openfile (inbound_rate_lock_path broker_root)
      [ Unix.O_RDWR; Unix.O_CREAT ] 0o600
  in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
      (try Unix.close fd with _ -> ()))
    (fun () ->
      Unix.lockf fd Unix.F_LOCK 0;
      f ())

let json_float_list = function
  | `List items ->
      let rec parse acc = function
        | [] -> Ok (List.rev acc)
        | `Float n :: rest when Float.is_finite n -> parse (n :: acc) rest
        | `Int n :: rest -> parse (float_of_int n :: acc) rest
        | `Intlit s :: rest ->
            (match float_of_string_opt s with
             | Some n when Float.is_finite n -> parse (n :: acc) rest
             | _ -> Error "rate-state timestamp is not finite")
        | _ -> Error "rate-state timestamp list contains a non-number"
      in
      parse [] items
  | _ -> Error "rate-state timestamps must be a list"

let inbound_rate_state_of_json = function
  | `Assoc fields ->
      (match validate_object_fields ~context:"rate-state root"
               ~allowed:[ "machine"; "senders"; "recipients" ] fields with
       | Error e -> Error e
       | Ok () ->
           match List.assoc_opt "machine" fields,
                 List.assoc_opt "senders" fields with
           | Some machine, Some (`Assoc senders) ->
               (match json_float_list machine with
                | Error e -> Error e
                | Ok machine_events ->
                    let parse_event_table kind entries =
                      let table = Hashtbl.create (max 17 (List.length entries)) in
                      let rec parse seen = function
                        | [] -> Ok table
                        | (alias, events) :: rest ->
                            let alias = String.lowercase_ascii alias in
                            if alias = "" || List.mem alias seen then
                              Error ("rate-state contains an empty or duplicate " ^ kind)
                            else
                              match json_float_list events with
                              | Error e -> Error e
                              | Ok events ->
                                  Hashtbl.add table alias events;
                                  parse (alias :: seen) rest
                      in
                      parse [] entries
                    in
                    match parse_event_table "sender" senders with
                    | Error _ as e -> e
                    | Ok sender_events ->
                        let recipients =
                          match List.assoc_opt "recipients" fields with
                          | None -> Ok []
                          | Some (`Assoc recipients) -> Ok recipients
                          | Some _ -> Error "rate-state recipients must be an object"
                        in
                        match recipients with
                        | Error _ as e -> e
                        | Ok recipients ->
                            match parse_event_table "recipient" recipients with
                            | Error _ as e -> e
                            | Ok recipient_events -> Ok {
                                machine_events;
                                sender_events;
                                recipient_events;
                              })
           | _ -> Error "rate-state requires machine list and senders object")
  | _ -> Error "rate-state root must be an object"

let inbound_rate_state_to_json state =
  let times xs = `List (List.map (fun ts -> `Float ts) xs) in
  let event_table table =
    Hashtbl.to_seq table |> List.of_seq
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)
    |> List.map (fun (sender, events) -> sender, times events)
  in
  `Assoc [
    ("machine", times state.machine_events);
    ("senders", `Assoc (event_table state.sender_events));
    ("recipients", `Assoc (event_table state.recipient_events));
  ]

let load_inbound_rate_state broker_root =
  let path = inbound_rate_state_path broker_root in
  if not (Sys.file_exists path) then Ok (create_inbound_rate_state ())
  else
    match C2c_io.read_json_opt path with
    | None -> Error (Printf.sprintf "cannot parse relay inbound rate state %s" path)
    | Some json -> inbound_rate_state_of_json json

let save_inbound_rate_state broker_root state =
  let path = inbound_rate_state_path broker_root in
  let tmp = path ^ ".tmp" in
  try
    let oc =
      open_out_gen [ Open_wronly; Open_creat; Open_trunc; Open_text ] 0o600 tmp
    in
    Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
      output_string oc
        (Yojson.Safe.to_string (inbound_rate_state_to_json state) ^ "\n");
      flush oc);
    Unix.rename tmp path;
    Ok ()
  with exn -> Error (Printexc.to_string exn)

let inbound_sender_policy policy sender =
  let key = String.lowercase_ascii sender in
  match List.assoc_opt key policy.sender_overrides with
  | Some override -> override
  | None -> {
      sender_action = policy.default_sender_action;
      sender_max_bytes = policy.default_max_bytes;
      sender_rate = policy.default_sender_rate;
    }

let inbound_recipient_policy policy recipient =
  let key = String.lowercase_ascii recipient in
  match List.assoc_opt key policy.recipient_overrides with
  | Some override -> override
  | None -> {
      recipient_enabled = true;
      recipient_max_bytes = policy.default_max_bytes;
      recipient_rate = policy.default_recipient_rate;
    }

let prune_window ~now rate events =
  let cutoff = now -. rate.rate_window_s in
  List.filter (fun ts -> ts > cutoff && ts <= now) events

let inbound_row_fields = function
  | `Assoc fields ->
      (match List.assoc_opt "from_alias" fields,
             List.assoc_opt "to_alias" fields,
             List.assoc_opt "content" fields with
       | Some (`String sender), Some (`String recipient), Some (`String _) ->
           Some (sender, recipient)
       | _ -> None)
  | _ -> None

let inbound_row_size_bytes row = String.length (Yojson.Safe.to_string row)

(* Relay rows retain their wire destination for delivery metadata: a direct
   recipient may be [alias@host], and a room fanout copy is [alias#room]
   (optionally followed by [@host]).  Admission must bind either form to the
   trusted alias whose inbox was polled.  Do not use [recipient_identity]
   alone here: it is deliberately presentation-oriented and would also accept
   malformed delimiter ordering such as [alias@host#room]. *)
let canonical_inbound_recipient recipient =
  let direct, host = Relay_host_routing.split_alias_host recipient in
  let valid_host = function
    | None -> true
    | Some "relay" -> true
    | Some value -> C2c_name.is_opaque_host_id value
  in
  if not (valid_host host) then None
  else
    match String.index_opt direct '#' with
    | None -> if C2c_name.is_valid direct then Some direct else None
    | Some i ->
        let alias = String.sub direct 0 i in
        let room = String.sub direct (i + 1) (String.length direct - i - 1) in
        if not (C2c_name.is_valid alias)
           || not (Relay_common.valid_relay_room_id room)
        then None
        else Some alias

let filter_inbound_messages ?expected_recipient ~now policy state messages =
  (* Keep sender bookkeeping bounded by the aggregate machine window.  Without
     this cleanup, a long-running connector could retain one empty hash entry
     for every sender it had ever seen. *)
  Hashtbl.filter_map_inplace
    (fun sender events ->
       let sender_policy = inbound_sender_policy policy sender in
       match prune_window ~now sender_policy.sender_rate events with
       | [] -> None
       | live -> Some live)
    state.sender_events;
  Hashtbl.filter_map_inplace
    (fun recipient events ->
       let recipient_policy = inbound_recipient_policy policy recipient in
       match prune_window ~now recipient_policy.recipient_rate events with
       | [] -> None
       | live -> Some live)
    state.recipient_events;
  state.machine_events <- prune_window ~now policy.machine_rate state.machine_events;
  let accepted, rejected =
    List.fold_left
      (fun (accepted, rejected) row ->
         match inbound_row_fields row with
         | None -> (accepted, Inbound_schema :: rejected)
         | Some (sender, recipient) ->
             let sender_policy = inbound_sender_policy policy sender in
             let policy_recipient =
               match expected_recipient with
               | None -> Some recipient
               | Some expected ->
                   match canonical_inbound_recipient recipient with
                   | Some canonical
                     when String.equal (String.lowercase_ascii expected)
                            (String.lowercase_ascii canonical) -> Some expected
                   | Some _ | None -> None
             in
             match policy_recipient with
             | None -> (accepted, Inbound_recipient_mismatch :: rejected)
             | Some policy_recipient ->
             let recipient_policy =
               inbound_recipient_policy policy policy_recipient
             in
             if sender_policy.sender_action = Inbound_deny then
               (accepted, Inbound_sender_denied :: rejected)
             else if not recipient_policy.recipient_enabled then
               (accepted, Inbound_recipient_disabled :: rejected)
             else if inbound_row_size_bytes row >
                       min sender_policy.sender_max_bytes
                         recipient_policy.recipient_max_bytes then
               (accepted, Inbound_oversize :: rejected)
             else
               let sender_key = String.lowercase_ascii sender in
               let recipient_key = String.lowercase_ascii policy_recipient in
               let sender_events =
                 Hashtbl.find_opt state.sender_events sender_key
                 |> Option.value ~default:[]
                 |> prune_window ~now sender_policy.sender_rate
               in
               if List.length sender_events >=
                    sender_policy.sender_rate.rate_messages then begin
                 Hashtbl.replace state.sender_events sender_key sender_events;
                 (accepted, Inbound_sender_rate :: rejected)
               end else
                 let recipient_events =
                   Hashtbl.find_opt state.recipient_events recipient_key
                   |> Option.value ~default:[]
                   |> prune_window ~now recipient_policy.recipient_rate
                 in
                 if List.length recipient_events >=
                      recipient_policy.recipient_rate.rate_messages then begin
                   Hashtbl.replace state.recipient_events recipient_key
                     recipient_events;
                   (accepted, Inbound_recipient_rate :: rejected)
                 end else
                 let machine_events =
                   prune_window ~now policy.machine_rate state.machine_events
                 in
                 if List.length machine_events >= policy.machine_rate.rate_messages
                 then begin
                   state.machine_events <- machine_events;
                   (accepted, Inbound_machine_rate :: rejected)
                 end else begin
                   Hashtbl.replace state.sender_events sender_key
                     (now :: sender_events);
                   Hashtbl.replace state.recipient_events recipient_key
                     (now :: recipient_events);
                   state.machine_events <- now :: machine_events;
                   (row :: accepted, rejected)
                 end)
      ([], []) messages
  in
  List.rev accepted, List.rev rejected

let filter_inbound_messages_guarded ?expected_recipient ~now policy state messages =
  match policy with
  | Error _ -> [], List.map (fun _ -> Inbound_policy) messages
  | Ok policy ->
      filter_inbound_messages ?expected_recipient ~now policy state messages

let filter_inbound_messages_persisted ?expected_recipient ~now ~broker_root policy messages =
  match policy with
  | Error _ ->
      [], List.map (fun _ -> Inbound_policy) messages, None
  | Ok policy ->
      with_inbound_rate_lock broker_root (fun () ->
        match load_inbound_rate_state broker_root with
        | Error detail ->
            [], List.map (fun _ -> Inbound_policy) messages, Some detail
        | Ok state ->
            let accepted, rejected =
              filter_inbound_messages ?expected_recipient ~now policy state messages
            in
            match save_inbound_rate_state broker_root state with
            | Ok () -> accepted, rejected, None
            | Error detail ->
                [], List.map (fun _ -> Inbound_policy) messages,
                Some ("cannot persist relay inbound rate state: " ^ detail))

let inbound_rejection_name = function
  | Inbound_schema -> "schema"
  | Inbound_policy -> "policy"
  | Inbound_sender_denied -> "sender_denied"
  | Inbound_recipient_mismatch -> "recipient_mismatch"
  | Inbound_recipient_disabled -> "recipient_disabled"
  | Inbound_oversize -> "oversize"
  | Inbound_sender_rate -> "sender_rate"
  | Inbound_recipient_rate -> "recipient_rate"
  | Inbound_machine_rate -> "machine_rate"

let summarize_inbound_rejections reasons =
  let counts = Hashtbl.create 4 in
  List.iter
    (fun reason ->
       let name = inbound_rejection_name reason in
       Hashtbl.replace counts name
         (1 + Option.value ~default:0 (Hashtbl.find_opt counts name)))
    reasons;
  [ "schema"; "policy"; "sender_denied"; "recipient_mismatch";
    "recipient_disabled"; "oversize"; "sender_rate"; "recipient_rate";
    "machine_rate" ]
  |> List.filter_map (fun name ->
         Hashtbl.find_opt counts name
         |> Option.map (fun count -> Printf.sprintf "%s=%d" name count))
  |> String.concat ", "

type t = {
  relay_url : string;
  token : string option;
  identity : Relay_identity.t option;
  broker_root : string;
  node_id : string;
  heartbeat_ttl : float;
  interval : float;
  verbose : bool;
  mutable registered : string list;
  mutable active_ws_bindings : string list;
  mutable alert_state : C2c_relay_alert.state;  (* B010: edge-trigger dedup *)
}

(* ---------------------------------------------------------------------------
 * Local broker helpers
 * --------------------------------------------------------------------------- *)

let local_inbox_path broker_root session_id =
  broker_root // (session_id ^ ".inbox.json")

type local_registration = {
  lr_session_id : string;
  lr_alias : string;
  lr_client_type : string;
  lr_pid : int option;
  lr_pid_start_time : int option;
  lr_registered_at : float option;
  lr_last_activity_ts : float option;
  lr_registered_by : string option;
}

let read_pid_start_time_local pid =
  let path = Printf.sprintf "/proc/%d/stat" pid in
  try
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      let line = input_line ic in
      match String.rindex_opt line ')' with
      | None -> None
      | Some idx ->
          let tail = String.sub line (idx + 2) (String.length line - idx - 2) in
          String.split_on_char ' ' tail |> fun fields ->
          (match List.nth_opt fields 19 with
           | Some token -> int_of_string_opt token
           | None -> None))
  with Sys_error _ | End_of_file -> None

let env_truthy name =
  match Sys.getenv_opt name with
  | Some "1" | Some "true" | Some "yes" -> true
  | _ -> false

let is_hook_registration = function
  | Some source -> String.ends_with ~suffix:"-hook" source
  | None -> false

let relay_registration_is_eligible ~broker_root reg =
  if env_truthy "C2C_IN_DOCKER" then
    match reg.lr_pid with
    | None -> false
    | Some _ ->
        let lease = broker_root // ".leases" // reg.lr_session_id in
        (try Unix.gettimeofday () -. (Unix.stat lease).st_mtime <= 300.0
         with Unix.Unix_error _ -> false)
  else
    match reg.lr_pid with
    | Some pid ->
        (match reg.lr_pid_start_time, read_pid_start_time_local pid with
         | Some stored, Some current -> stored = current
         | _ -> false)
    | None when is_hook_registration reg.lr_registered_by ->
        (* Vanilla client hooks are short-lived and intentionally register no
           PID. Their bounded activity lease is the only positive liveness
           evidence; it preserves active Claude/Grok/Agy/Codex aliases without
           reviving old hook history indefinitely. *)
        let anchor = match reg.lr_last_activity_ts with
          | Some _ as ts -> ts
          | None -> reg.lr_registered_at
        in
        (match anchor with
         | Some ts -> Unix.gettimeofday () -. ts <= 24.0 *. 60.0 *. 60.0
         | None -> false)
    | None -> false

let read_local_registrations_with_skipped broker_root =
  let int_opt key fields = match List.assoc_opt key fields with
    | Some (`Int n) -> Some n | _ -> None in
  let float_opt key fields = match List.assoc_opt key fields with
    | Some (`Float f) -> Some f | Some (`Int n) -> Some (float_of_int n)
    | _ -> None in
  let string_opt key fields = match List.assoc_opt key fields with
    | Some (`String s) -> Some s | _ -> None in
  let parsed =
    match C2c_io.read_json_opt (broker_root // "registry.json") with
    | Some (`List rows) ->
        List.filter_map (function
          | `Assoc fields ->
              (match string_opt "session_id" fields, string_opt "alias" fields with
               | Some lr_session_id, Some lr_alias -> Some {
                   lr_session_id; lr_alias;
                   lr_client_type = Option.value (string_opt "client_type" fields)
                       ~default:"unknown";
                   lr_pid = int_opt "pid" fields;
                   lr_pid_start_time = int_opt "pid_start_time" fields;
                   lr_registered_at = float_opt "registered_at" fields;
                   lr_last_activity_ts = float_opt "last_activity_ts" fields;
                   lr_registered_by = string_opt "registered_by" fields;
                 }
               | _ -> None)
          | _ -> None) rows
    | _ -> []
  in
  List.fold_left
    (fun (eligible, skipped) reg ->
       if relay_registration_is_eligible ~broker_root reg then
         ((reg.lr_session_id, reg.lr_alias, reg.lr_client_type) :: eligible,
          skipped)
       else eligible, skipped + 1)
    ([], 0) parsed
  |> fun (eligible, skipped) -> List.rev eligible, skipped

let read_local_registrations broker_root =
  fst (read_local_registrations_with_skipped broker_root)

let retain_eligible_registered regs registered =
  let eligible_session_ids = List.map (fun (sid, _, _) -> sid) regs in
  List.filter (fun sid -> List.mem sid eligible_session_ids) registered

let append_to_local_inbox broker_root session_id messages =
  if messages = [] then 0
  else
    let path = local_inbox_path broker_root session_id in
    let existing_json =
      match C2c_io.read_json_opt path with
      | None -> `List []
      | Some json -> json in
    let existing = match existing_json with
      | `List lst -> lst
      | _ -> [] in
    let merged_json = `List (existing @ messages) in
    let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
    let oc = open_out tmp in
    Fun.protect ~finally:(fun () -> close_out oc)
      (fun () ->
        Yojson.Safe.to_channel oc merged_json ~std:false;
        close_out oc;
        Unix.rename tmp path);
    List.length messages

(* ---------------------------------------------------------------------------
 * S5c Phase B: Pseudo-registration storage (separate from registry.json)
 * Stored in pseudo_registrations.json — map of binding_id -> entry
 * --------------------------------------------------------------------------- *)

let pseudo_reg_path broker_root = broker_root // "pseudo_registrations.json"

type pseudo_registration = {
  pr_alias : string;
  pr_ed25519_pubkey : string;
  pr_x25519_pubkey : string;
  pr_machine_ed25519_pubkey : string;
  pr_provenance_sig : string;
  pr_bound_at : float;
}

let read_pseudo_registrations broker_root =
  let path = pseudo_reg_path broker_root in
  match C2c_io.read_json_opt path with
  | None -> []
  | Some json ->
      let open Yojson.Safe.Util in
      match json with
      | `Assoc bindings ->
          List.fold_left (fun acc (binding_id, entry) ->
            match entry with
            | `Assoc fields ->
                let get_str key = match List.assoc_opt key fields with Some (`String s) -> s | _ -> "" in
                let get_float key = match List.assoc_opt key fields with Some (`Float f) -> f | Some (`Int i) -> float_of_int i | _ -> 0.0 in
                let pr = {
                  pr_alias = get_str "alias";
                  pr_ed25519_pubkey = get_str "ed25519_pubkey";
                  pr_x25519_pubkey = get_str "x25519_pubkey";
                  pr_machine_ed25519_pubkey = get_str "machine_ed25519_pubkey";
                  pr_provenance_sig = get_str "provenance_sig";
                  pr_bound_at = get_float "bound_at";
                } in
                (binding_id, pr) :: acc
            | _ -> acc
          ) [] bindings
      | _ -> []

let write_pseudo_registrations broker_root entries =
  let path = pseudo_reg_path broker_root in
  let json = `Assoc (List.map (fun (binding_id, pr) ->
    binding_id, `Assoc [
      "alias", `String pr.pr_alias;
      "ed25519_pubkey", `String pr.pr_ed25519_pubkey;
      "x25519_pubkey", `String pr.pr_x25519_pubkey;
      "machine_ed25519_pubkey", `String pr.pr_machine_ed25519_pubkey;
      "provenance_sig", `String pr.pr_provenance_sig;
      "bound_at", `Float pr.pr_bound_at;
    ]
  ) entries) in
  let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
  let oc = open_out tmp in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () ->
      Yojson.Safe.to_channel oc json ~std:false;
      close_out oc;
      Unix.rename tmp path)

let upsert_pseudo_registration broker_root ~binding_id ~alias ~ed25519_pubkey ~x25519_pubkey ~machine_ed25519_pubkey ~provenance_sig ~bound_at =
  let entries = read_pseudo_registrations broker_root in
  let new_entry = {
    pr_alias = alias;
    pr_ed25519_pubkey = ed25519_pubkey;
    pr_x25519_pubkey = x25519_pubkey;
    pr_machine_ed25519_pubkey = machine_ed25519_pubkey;
    pr_provenance_sig = provenance_sig;
    pr_bound_at = bound_at;
  } in
  let entries = List.remove_assq binding_id entries in
  let entries = (binding_id, new_entry) :: entries in
  write_pseudo_registrations broker_root entries

let remove_pseudo_registration broker_root ~binding_id =
  let entries = read_pseudo_registrations broker_root in
  let entries = List.remove_assq binding_id entries in
  write_pseudo_registrations broker_root entries

(* S5c Phase B: Mobile bindings — local store of binding_ids this broker
   should connect to. Stored in mobile_bindings.json — list of binding_ids. *)

let mobile_bindings_path broker_root = broker_root // "mobile_bindings.json"

type mobile_binding = {
  mb_binding_id : string;
  mb_created_at : float;
}

let read_mobile_bindings broker_root =
  let path = mobile_bindings_path broker_root in
  match C2c_io.read_json_opt path with
  | None -> []
  | Some json ->
      let open Yojson.Safe.Util in
      match json with
      | `List ids ->
          List.filter_map (function
            | `Assoc fields ->
                let binding_id = match List.assoc_opt "binding_id" fields with Some (`String s) -> s | _ -> "" in
                let created_at = match List.assoc_opt "created_at" fields with Some (`Float f) -> f | Some (`Int i) -> float_of_int i | _ -> 0.0 in
                if binding_id <> "" then Some { mb_binding_id = binding_id; mb_created_at = created_at }
                else None
            | _ -> None)
          ids
      | _ -> []

let write_mobile_bindings broker_root entries =
  let path = mobile_bindings_path broker_root in
  let json = `List (List.map (fun mb ->
    `Assoc [
      "binding_id", `String mb.mb_binding_id;
      "created_at", `Float mb.mb_created_at;
    ])
  entries) in
  let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
  let oc = open_out tmp in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () ->
      Yojson.Safe.to_channel oc json ~std:false;
      close_out oc;
      Unix.rename tmp path)

let add_mobile_binding broker_root ~binding_id =
  let entries = read_mobile_bindings broker_root in
  let now = Unix.gettimeofday () in
  let new_entry = { mb_binding_id = binding_id; mb_created_at = now } in
  let entries = List.filter (fun e -> e.mb_binding_id <> binding_id) entries in
  let entries = new_entry :: entries in
  write_mobile_bindings broker_root entries

let remove_mobile_binding broker_root ~binding_id =
  let entries = read_mobile_bindings broker_root in
  let entries = List.filter (fun e -> e.mb_binding_id <> binding_id) entries in
  write_mobile_bindings broker_root entries

(* ---------------------------------------------------------------------------
 * Outbox (remote-outbox.jsonl) with retry + DLQ
 *
 * Gap #1+#6 fix: outbox entries now track attempts and enqueued_at.
 * - unknown_alias / recipient_dead errors → immediate DLQ
 * - connection_error → retry with backstop after MAX_ATTEMPTS or MAX_AGE_SECONDS
 * - local DLQ at remote-outbox-dlq.jsonl + DM to sender
 * --------------------------------------------------------------------------- *)

let outbox_path broker_root = broker_root // "remote-outbox.jsonl"
let dlq_path broker_root = broker_root // "remote-outbox-dlq.jsonl"
let outbox_lock_path broker_root = broker_root // "remote-outbox.lock"

(* Constants for retry backstop *)
let max_attempts = 60       (* ~30min at 30s interval *)
let max_age_seconds = 3600.0 (* 1 hour *)

(* POSIX fcntl lock on a sidecar — serialises the read+write window in sync
   against concurrent append_outbox_entry calls from MCP.
   Without this, sync's write_outbox (which opens with trunc) can clobber
   entries appended during the HTTP send loop (TOCTOU / silent message loss).
   Compatible with any other Unix flock holder on the same sidecar. *)
let with_outbox_lock broker_root f =
  let fd =
    Unix.openfile (outbox_lock_path broker_root) [ O_RDWR; O_CREAT ] 0o644
  in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
      (try Unix.close fd with _ -> ()))
    (fun () ->
      Unix.lockf fd Unix.F_LOCK 0;
      f ())

type outbox_entry = {
  ob_from : string;
  ob_to : string;
  ob_content : string;
  ob_msg_id : string option;
  ob_attempts : int;        (* cumulative send attempts *)
  ob_enqueued_at : float;    (* Unix.gettimeofday at creation *)
  ob_last_error : string option; (* most recent error class *)
}

let read_outbox broker_root =
  let path = outbox_path broker_root in
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    let now = Unix.gettimeofday () in
    let rec loop acc =
      match try Some (input_line ic) with End_of_file -> None with
      | None -> close_in ic; List.rev acc
      | Some line ->
          let trimmed = String.trim line in
          if trimmed = "" then loop acc
          else
            try
              let json = Yojson.Safe.from_string trimmed in
              let open Yojson.Safe.Util in
              let from = match json |> member "from_alias" with `String s -> s | _ -> "" in
              let to_ = match json |> member "to_alias" with `String s -> s | _ -> "" in
              let content = match json |> member "content" with `String s -> s | _ -> "" in
              let msg_id = match json |> member "message_id" with `String s -> Some s | _ -> None in
              (* New fields with defaults for backward compat.
                 Legacy entries (pre-fix) have no attempts/enqueued_at — default
                 attempts=0 (retry from scratch) and enqueued_at=now (don't
                 trigger max_age on upgrade if relay was briefly flaky). *)
              let attempts = match json |> member "attempts" with `Int i -> i | _ -> 0 in
              let enqueued_at =
                match json |> member "enqueued_at" with
                | `Float f -> f
                | `Int i -> float_of_int i  (* Yojson emits whole-second floats as Int *)
                | _ -> now
              in
              let last_error = match json |> member "last_error" with `String s -> Some s | _ -> None in
              loop ({ ob_from = from; ob_to = to_; ob_content = content;
                      ob_msg_id = msg_id; ob_attempts = attempts;
                      ob_enqueued_at = enqueued_at; ob_last_error = last_error } :: acc)
            with _ -> loop acc
    in
    loop []

let write_outbox broker_root entries =
  let path = outbox_path broker_root in
  if entries = [] then (try Sys.remove path with _ -> ())
  else
    let oc = open_out path in
    Fun.protect ~finally:(fun () -> close_out oc)
      (fun () ->
        List.iter (fun e ->
          let msg_id_assoc = match e.ob_msg_id with
            | Some m -> ["message_id", `String m]
            | None -> []
          in
          let extra = [
            "attempts", `Int e.ob_attempts;
            "enqueued_at", `Float e.ob_enqueued_at;
          ] in
          let extra = match e.ob_last_error with
            | Some err -> ("last_error", `String err) :: extra
            | None -> extra
          in
          let json = `Assoc (
            ["from_alias", `String e.ob_from;
             "to_alias", `String e.ob_to;
             "content", `String e.ob_content]
            @ msg_id_assoc @ extra
          ) in
          output_string oc (Yojson.Safe.to_string json ^ "\n")
        ) entries)

(* Append a single entry to the DLQ (append-only). *)
let append_dlq_entry broker_root entry ~reason =
  let path = dlq_path broker_root in
  let msg_id_assoc = match entry.ob_msg_id with
    | Some m -> ["message_id", `String m]
    | None -> []
  in
  let extra = [
    "attempts", `Int entry.ob_attempts;
    "enqueued_at", `Float entry.ob_enqueued_at;
    ("dlq_reason", `String reason);
  ] in
  let extra = match entry.ob_last_error with
    | Some err -> ("last_error", `String err) :: extra
    | None -> extra
  in
  let json = `Assoc (
    ["from_alias", `String entry.ob_from;
     "to_alias", `String entry.ob_to;
     "content", `String entry.ob_content]
    @ msg_id_assoc @ extra
  ) in
  let line = Yojson.Safe.to_string json ^ "\n" in
  let oc = open_out_gen [Open_text; Open_append; Open_creat] 0o644 path in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc line)

(* H10 item-5 hardening (B249): [Yojson.Safe.Util.member] RAISES Type_error
   on non-object JSON. The helpers below classify RELAY RESPONSES, which a
   misbehaving relay can make any JSON value — they must be total so a
   non-object response records a per-op sync error instead of aborting the
   whole sync pass (pre-fix, one non-object register response crashed sync
   for EVERY session; see test_connector_non_object_response_start_once). *)
let member_or_null key = function
  | `Assoc fields -> Option.value (List.assoc_opt key fields) ~default:`Null
  | _ -> `Null

(** Classify an error response from the relay/client.
    The relay's send error response is {{"ok":false,"error_code":"<code>","error":"<msg>"}}.
    HTTP-level connection failures produce {{"ok":false,"error_code":"connection_error","error":"<msg>"}}.
    We check error_code first; unknown codes fall through to "other". *)
let classify_error json =
  match member_or_null "error_code" json with
  | `String "unknown_alias" -> "unknown_alias"
  | `String "recipient_dead" -> "recipient_dead"
  | `String "connection_error" -> "connection_error"
  | `String _ -> "other"
  | _ -> "other"

(* ---------------------------------------------------------------------------
 * Connector state (connector-state.json) — B093
 *
 * A small status file written after every sync so `c2c doctor --relay` can
 * report last successful sync, last error, and live counts without grepping
 * broker files or attaching to the connector process. Atomic temp+rename;
 * absence of the file means the connector has never completed a sync here.
 * --------------------------------------------------------------------------- *)

let connector_state_path broker_root = broker_root // "connector-state.json"

type connector_state = {
  cs_last_sync_ts : float;
  cs_last_ok_ts : float;
  cs_last_error_op : string option;
  cs_last_error_detail : string option;
  cs_last_error_ts : float option;
  cs_registered : string list;
  cs_node_id : string option;  (* H3: connector node-id for monitor peek-key resolution *)
  (* B209: alias -> session_id for each relay-registered local session. The
     authoritative peek key for a connector-managed alias is
     (cs_node_id, cs_sessions[alias]); older state files without this field
     leave it empty and callers fall back to the local session-id. *)
  cs_sessions : (string * string) list;
  cs_pid : int option;  (* B181: writer PID for process≠bridge diagnostics *)
  cs_outbox_forwarded : int;
  cs_outbox_failed : int;
  cs_outbox_dlqed : int;
  cs_inbound_delivered : int;
  cs_inbound_rejected : int;  (* H9: schema-invalid poll rows dropped *)
}

let write_connector_state ?node_id broker_root (result : sync_result) =
  let now = Unix.gettimeofday () in
  let ok = result.last_error = None in
  let last_ok_ts = if ok then now else 0.0 in
  (* Preserve the previous last_ok_ts when this sync errored, so the doctor
     check can still report how long ago the last healthy sync was. *)
  let prev_ok_ts =
    match C2c_io.read_json_opt (connector_state_path broker_root) with
    | Some (`Assoc fs) ->
        (match List.assoc_opt "last_ok_ts" fs with
         | Some (`Float f) -> f
         | Some (`Int i) -> float_of_int i
         | _ -> 0.0)
    | _ -> 0.0
  in
  let last_ok_ts = if ok then now else prev_ok_ts in
  let err_assoc = match result.last_error with
    | Some e ->
        [ ("last_error_op", `String e.err_op)
        ; ("last_error_detail", `String e.err_detail)
        ; ("last_error_ts", `Float e.err_ts) ]
    | None ->
        [ ("last_error_op", `Null)
        ; ("last_error_detail", `Null)
        ; ("last_error_ts", `Null) ]
  in
  (* H3: record the connector's node_id so a `c2c monitor` on this broker can
     resolve the connector-managed relay peek key (node_id + local session-id)
     instead of the cli-<alias> convention. Additive/optional — older readers
     and connector-state files without it fall back to Host_id.compute_host_hash. *)
  let node_id_assoc = match node_id with
    | Some n when n <> "" -> [ ("node_id", `String n) ]
    | _ -> []
  in
  (* B209: record alias -> session_id so a monitor can peek the exact relay
     binding the connector established. Additive/optional. *)
  let sessions_assoc =
    match result.registered_sessions with
    | [] -> []
    | pairs ->
        [ ("sessions",
           `Assoc (List.map (fun (alias, sid) -> (alias, `String sid)) pairs)) ]
  in
  (* B244: persist rate_limited + retry_after so doctor/whoami can surface
     chronic 429s without grepping connector logs. *)
  let rl_assoc =
    ("rate_limited", `Bool result.rate_limited)
    :: (match result.retry_after_s with
        | Some ra -> [ ("retry_after_s", `Float ra) ]
        | None -> [ ("retry_after_s", `Null) ])
  in
  let json = `Assoc (
    [ ("last_sync_ts", `Float now)
    ; ("last_ok_ts", `Float last_ok_ts)
    ; ("pid", `Int (Unix.getpid ()))
    ; ("registered", `List (List.map (fun a -> `String a) result.registered))
    ; ("outbox_forwarded", `Int result.outbox_forwarded)
    ; ("outbox_failed", `Int result.outbox_failed)
    ; ("outbox_dlqed", `Int result.outbox_dlqed)
    ; ("inbound_delivered", `Int result.inbound_delivered)
    ; ("inbound_rejected", `Int result.inbound_rejected)
    ] @ rl_assoc @ node_id_assoc @ sessions_assoc @ err_assoc) in
  let path = connector_state_path broker_root in
  let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
  let oc = open_out tmp in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () ->
      Yojson.Safe.to_channel oc json ~std:false;
      close_out oc;
      Unix.rename tmp path)

let read_connector_state broker_root : connector_state option =
  match C2c_io.read_json_opt (connector_state_path broker_root) with
  | None -> None
  | Some json ->
      let open Yojson.Safe.Util in
      let get_float k = match json |> member k with
        | `Float f -> Some f
        | `Int i -> Some (float_of_int i)
        | _ -> None
      in
      let get_str k = match json |> member k with `String s -> Some s | _ -> None in
      let get_int k = match json |> member k with `Int i -> i | _ -> 0 in
      let get_int_opt k = match json |> member k with
        | `Int i -> Some i
        | _ -> None
      in
      let last_sync_ts = Option.value (get_float "last_sync_ts") ~default:0.0 in
      let last_ok_ts = Option.value (get_float "last_ok_ts") ~default:0.0 in
      let registered = match json |> member "registered" with
        | `List xs -> List.filter_map (function `String s -> Some s | _ -> None) xs
        | _ -> []
      in
      (* B209: alias -> session_id map (optional; absent in older state files). *)
      let sessions = match json |> member "sessions" with
        | `Assoc kvs ->
            List.filter_map
              (function (alias, `String sid) -> Some (alias, sid) | _ -> None)
              kvs
        | _ -> []
      in
      Some {
        cs_last_sync_ts = last_sync_ts;
        cs_last_ok_ts = last_ok_ts;
        cs_last_error_op = get_str "last_error_op";
        cs_last_error_detail = get_str "last_error_detail";
        cs_last_error_ts = get_float "last_error_ts";
        cs_registered = registered;
        cs_node_id = get_str "node_id";
        cs_sessions = sessions;
        cs_pid = get_int_opt "pid";
        cs_outbox_forwarded = get_int "outbox_forwarded";
        cs_outbox_failed = get_int "outbox_failed";
        cs_outbox_dlqed = get_int "outbox_dlqed";
        cs_inbound_delivered = get_int "inbound_delivered";
        cs_inbound_rejected = get_int "inbound_rejected";
      }

(** B209: the authoritative relay peek key for a connector-managed [alias].

    The relay enforces one lease row per alias and rekeys it on every register
    (ON CONFLICT(alias) DO UPDATE SET node_id, session_id), so once the machine
    connector registers a local session it OWNS the alias's live lease under
    (connector node_id, that session's session_id) — NOT the cli-<alias>/
    cli-<alias> convention a bare `c2c monitor` would otherwise peek. Peeking
    the stale cli-<alias> key then fails the relay's owner check with
    signature_invalid even though the alias/identity are healthy (B209).

    Returns [(node_id, session_id)] when [alias] is connector-managed:
    - node_id: the connector's persisted node_id, else [fallback_node_id]
      (the host hash the connector derives by default);
    - session_id: the connector's recorded session_id for this alias
      ([cs_sessions]), else [fallback_session_id] (the monitor's locally
      resolved session-id) for backward compatibility with older state files
      written before [cs_sessions] existed.
    Returns [None] when the alias is not connector-managed or no key can be
    resolved. Case-insensitive alias match (per the alias-comparison rule). *)
let connector_peek_key (cs : connector_state) ~alias
    ~fallback_node_id ~fallback_session_id : (string * string) option =
  let casefold = String.lowercase_ascii in
  let alias_cf = casefold alias in
  if not (List.exists (fun a -> casefold a = alias_cf) cs.cs_registered) then None
  else
    let node_id =
      match cs.cs_node_id with Some n when n <> "" -> n | _ -> fallback_node_id
    in
    if node_id = "" then None
    else
      let session_id =
        match
          List.find_opt (fun (a, _) -> casefold a = alias_cf) cs.cs_sessions
        with
        | Some (_, sid) when sid <> "" -> sid
        | _ -> fallback_session_id
      in
      if session_id = "" then None else Some (node_id, session_id)

(** Historical CLI-only inbox key used by `c2c relay register` and by
    poll/peek when no connector owns the alias. *)
let cli_inbox_key alias : string * string =
  let k = Printf.sprintf "cli-%s" alias in
  (k, k)

(** B231: resolve the (node_id, session_id) for CLI `relay dm poll` / `peek`.

    The relay lease is one-row-per-alias and SESSION-scoped. When
    `relay-connect` is running it re-registers under (connector node_id,
    local session_id), so a hard-coded [cli-<alias>/cli-<alias>] poll/peek
    gets signature_invalid ("verified signer does not own session"). Prefer
    the connector's recorded binding (same as monitor B209); fall back to
    the CLI convention only when the alias is not connector-managed.

    [env_node_id] / [env_session_id] (from C2C_RELAY_NODE_ID /
    C2C_RELAY_SESSION_ID) both-set win as an explicit operator override;
    a lone override is used only as connector_peek_key fallback. *)
let resolve_cli_dm_inbox_key ~alias
    ~(connector_state : connector_state option)
    ~fallback_node_id
    ~(env_node_id : string option)
    ~(env_session_id : string option)
    : string * string =
  match env_node_id, env_session_id with
  | Some n, Some s when n <> "" && s <> "" -> (n, s)
  | _ ->
      let fb_node =
        match env_node_id with Some n when n <> "" -> n | _ -> fallback_node_id
      in
      let fb_sid =
        match env_session_id with Some s when s <> "" -> s | _ -> ""
      in
      (match connector_state with
       | Some cs ->
           (match
              connector_peek_key cs ~alias
                ~fallback_node_id:fb_node ~fallback_session_id:fb_sid
            with
            | Some key -> key
            | None -> cli_inbox_key alias)
       | None -> cli_inbox_key alias)

(** Convenience wrapper: read connector-state from [broker_root] and resolve
    the B231 inbox key. Safe when the state file is missing or unreadable. *)
let resolve_cli_dm_inbox_key_at ~broker_root ~alias
    ~(env_node_id : string option)
    ~(env_session_id : string option)
    : string * string =
  let connector_state = read_connector_state broker_root in
  let fallback_node_id =
    try Host_id.compute_host_hash () with _ -> ""
  in
  resolve_cli_dm_inbox_key ~alias ~connector_state ~fallback_node_id
    ~env_node_id ~env_session_id

(** True when [connector-state.json] records a PID that still exists.
    Broker-owned process evidence that does not require argv --broker-root
    scoping (B181). Best-effort: missing pid field or unreadable /proc → false. *)
let connector_pid_alive (st : connector_state) : bool =
  match st.cs_pid with
  | None -> false
  | Some pid when pid <= 1 -> false
  | Some pid ->
      try
        Unix.kill pid 0;
        true
      with
      | Unix.Unix_error (Unix.ESRCH, _, _) -> false
      | Unix.Unix_error (Unix.EPERM, _, _) -> true (* exists, not signalable *)
      | _ -> false

(** Write a minimal connector-state.json recording that a sync raised an
    exception (B093). Lets `c2c doctor --relay` report the last error even
    when the connector's own sync loop catches and swallows it. Preserves the
    prior last_ok_ts so the doctor check can still report staleness. *)
let write_connector_state_error broker_root ~op ~detail =
  let now = Unix.gettimeofday () in
  let prev_ok_ts =
    match C2c_io.read_json_opt (connector_state_path broker_root) with
    | Some (`Assoc fs) ->
        (match List.assoc_opt "last_ok_ts" fs with
         | Some (`Float f) -> f
         | Some (`Int i) -> float_of_int i
         | _ -> 0.0)
    | _ -> 0.0
  in
  let json = `Assoc (
    [ ("last_sync_ts", `Float now)
    ; ("last_ok_ts", `Float prev_ok_ts)
    ; ("pid", `Int (Unix.getpid ()))
    ; ("registered", `List [])
    ; ("outbox_forwarded", `Int 0)
    ; ("outbox_failed", `Int 0)
    ; ("outbox_dlqed", `Int 0)
    ; ("inbound_delivered", `Int 0)
    ; ("inbound_rejected", `Int 0)
    ; ("last_error_op", `String op)
    ; ("last_error_detail", `String detail)
    ; ("last_error_ts", `Float now)
    ]) in
  let path = connector_state_path broker_root in
  let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
  let oc = open_out tmp in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () ->
      Yojson.Safe.to_channel oc json ~std:false;
      close_out oc;
      Unix.rename tmp path)

(* B228: stamp last_sync (not last_ok) at the start of a pass so a hung sync
   is visible as erroring (fresh last_sync, stale last_ok) rather than a silent
   full wedge where both timestamps freeze. Preserves prior last_ok, pid,
   counts, and last_error fields. Best-effort — never raises. *)
let touch_connector_last_sync broker_root =
  try
    let now = Unix.gettimeofday () in
    let path = connector_state_path broker_root in
    let base =
      match C2c_io.read_json_opt path with
      | Some (`Assoc fs) -> fs
      | _ -> []
    in
    let drop_keys = [ "last_sync_ts"; "pid" ] in
    let kept =
      List.filter (fun (k, _) -> not (List.mem k drop_keys)) base
    in
    let json =
      `Assoc
        (("last_sync_ts", `Float now)
         :: ("pid", `Int (Unix.getpid ()))
         :: kept)
    in
    let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
    let oc = open_out tmp in
    Fun.protect ~finally:(fun () -> close_out oc)
      (fun () ->
         Yojson.Safe.to_channel oc json ~std:false;
         close_out oc;
         Unix.rename tmp path)
  with _ -> ()

(** Append a single outbox entry to remote-outbox.jsonl (append-only, not rewrite).
    Used by enqueue_message when the target alias is remote (contains '@'). *)
let append_outbox_entry broker_root ~from_alias ~to_alias ~content ?message_id () =
  let path = outbox_path broker_root in
  let now = Unix.gettimeofday () in
  let msg_id_assoc = match message_id with
    | Some m -> ["message_id", `String m]
    | None -> []
  in
  let json = `Assoc (
    ["from_alias", `String from_alias;
     "to_alias", `String to_alias;
     "content", `String content;
     "attempts", `Int 1;
     "enqueued_at", `Float now]
    @ msg_id_assoc
  ) in
  let line = Yojson.Safe.to_string json ^ "\n" in
  let oc = open_out_gen [Open_text; Open_append; Open_creat] 0o644 path in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc line)

(* ---------------------------------------------------------------------------
 * HTTP client (inline — minimal, matches Relay_client in relay.ml)
 *
 * Auth strategy (matching Python connector):
 * - Admin paths (/gc, /dead_letter, /admin/unbind) → Bearer token
 * - Unauth paths (/health, /) → no auth
 * - Peer routes with identity available → Ed25519 Authorization header
 * - Otherwise → Bearer token
 * - /register: body-level Ed25519 proof when identity available
 * --------------------------------------------------------------------------- *)

module Relay_client = struct

  type t = {
    base_url : string;
    token : string option;
    timeout : float;
    identity : Relay_identity.t option;
  }

  let make ?token ?(timeout = 10.0) ?identity base_url =
    let base_url = match String.length base_url with
      | 0 -> base_url
      | n when base_url.[n-1] = '/' -> String.sub base_url 0 (n-1)
      | _ -> base_url
    in
    { base_url; token; timeout; identity }

  let connection_error msg =
    `Assoc [
      ("ok", `Bool false);
      ("error_code", `String "connection_error");
      ("error", `String msg);
    ]

  (* H10 (Q1-DEFECT-1) + B237: reconcile the parsed body with the HTTP
     status line — port of the H7/B237 contract from relay_client.ml. A
     non-2xx status can NEVER yield ok:true (pre-fix, an HTTP 500 with a
     dishonest {"ok":true} body made `relay connect --once` report
     success/exit 0). An honest ok:false object body passes through — its
     own error_code wins, which is what keeps the PoW/rate-limit helpers
     working: an honest 429 pow_required / rate_limit_exceeded body reaches
     Pow_client.is_pow_required and response_is_rate_limited unchanged
     apart from the appended http_status annotation. Error-shaped bodies
     that omit ok:false (B237 historical rate-limit shape) are normalized
     to ok:false with promoted error_code rather than schema-complaint
     double-errors. Anything else on a non-2xx is overridden with
     http_error_<code>, preserving the offending body under relay_response.
     2xx bodies are untouched. *)
  let error_shaped_fields fields =
    if List.assoc_opt "ok" fields = Some (`Bool true) then false
    else
      match List.assoc_opt "error_code" fields, List.assoc_opt "error" fields with
      | Some (`String _), _ | _, Some (`String _) -> true
      | _ -> false

  let normalize_error_shaped ~status fields =
    let fields =
      List.filter (fun (k, _) -> k <> "ok" && k <> "http_status") fields
    in
    let error_code =
      match List.assoc_opt "error_code" fields with
      | Some (`String c) -> Some c
      | _ ->
          (match List.assoc_opt "error" fields with
           | Some (`String c) -> Some c
           | _ -> None)
    in
    let error_msg =
      match List.assoc_opt "error" fields with
      | Some (`String e) -> Some e
      | _ -> error_code
    in
    let fields =
      List.filter (fun (k, _) -> k <> "error_code" && k <> "error") fields
    in
    let fields =
      (match error_code with
       | Some c -> ("error_code", `String c) :: fields
       | None -> fields)
    in
    let fields =
      (match error_msg with
       | Some e -> ("error", `String e) :: fields
       | None -> fields)
    in
    `Assoc (("ok", `Bool false) :: fields @ [ ("http_status", `Int status) ])

  let reconcile_status ~status body =
    if status >= 200 && status < 300 then body
    else
      match body with
      | `Assoc fields when List.assoc_opt "ok" fields = Some (`Bool false) ->
          let fields = List.filter (fun (k, _) -> k <> "http_status") fields in
          `Assoc (fields @ [ ("http_status", `Int status) ])
      | `Assoc fields when error_shaped_fields fields ->
          normalize_error_shaped ~status fields
      | dishonest ->
          `Assoc [
            ("ok", `Bool false);
            ("error_code", `String (Printf.sprintf "http_error_%d" status));
            ("error", `String (Printf.sprintf
              "relay answered HTTP %d but the body did not report ok:false"
              status));
            ("http_status", `Int status);
            ("relay_response", dishonest);
          ]

  let admin_paths = ["/gc"; "/dead_letter"; "/admin/unbind"]

  let is_admin_path path =
    List.mem path admin_paths
    || (String.length path > 14 && String.sub path 0 14 = "/remote_inbox/")
    || (String.length path >= 5 && String.sub path 0 5 = "/list")

  let is_unauth_path path =
    path = "/health" || path = "/"

  let sign_request t ~alias ~meth ~path ~body_str () =
    match t.identity with
    | None -> None
    | Some identity ->
        Some (Relay_signed_ops.sign_request identity ~alias ~meth ~path ~body_str ())

  let request t ~meth ~path ?body ?(alias : string option) () =
    let uri = Uri.of_string (t.base_url ^ path) in
    let base_path = match String.index_opt path '?' with
      | Some idx -> String.sub path 0 idx
      | None -> path
    in
    let headers =
      Cohttp.Header.init_with "Content-Type" "application/json"
    in
    (* B184: body on the wire must match the body covered by the Ed25519
       request signature. No body → empty string (not "{}"); see relay_client. *)
    let body_str =
      match body with
      | Some b -> Yojson.Safe.to_string b
      | None -> ""
    in
    let body_payload = Cohttp_lwt.Body.of_string body_str in
    let headers =
      if is_unauth_path base_path then headers
      else if is_admin_path base_path then
        (match t.token with
         | Some tok -> Cohttp.Header.add headers "Authorization" ("Bearer " ^ tok)
         | None -> headers)
      else
        match alias with
        | Some a ->
            (match sign_request t ~alias:a ~meth:(Cohttp.Code.string_of_method meth) ~path:base_path ~body_str () with
             | Some auth -> Cohttp.Header.add headers "Authorization" auth
             | None ->
                 (match t.token with
                  | Some tok -> Cohttp.Header.add headers "Authorization" ("Bearer " ^ tok)
                  | None -> headers))
        | None ->
            (match t.token with
             | Some tok -> Cohttp.Header.add headers "Authorization" ("Bearer " ^ tok)
             | None -> headers)
    in
    Lwt.catch
      (fun () ->
        Cohttp_lwt_unix.Client.call ~headers ~body:body_payload meth uri
        >>= fun (resp, resp_body) ->
        let status = Cohttp.Code.code_of_status (Cohttp.Response.status resp) in
        Cohttp_lwt.Body.to_string resp_body >>= fun text ->
        try Lwt.return (reconcile_status ~status (Yojson.Safe.from_string text))
        with _ -> Lwt.return (connection_error "invalid_json_response"))
      (fun exn -> Lwt.return (connection_error (Printexc.to_string exn)))

  let post t path ?alias body = request t ~meth:`POST ~path ?alias ~body ()
  let get t path = request t ~meth:`GET ~path ()

  let post_with_pow_retry t path ?alias ~route ~actor_id body =
    let post_body body = post t path ?alias body in
    Pow_client.post_with_retry ~post:post_body ~route ~actor_id body

  let health t = get t "/health"

  let register t ~node_id ~session_id ~alias ?(client_type = "unknown") ?(ttl = Relay.default_lease_ttl) ?(enc_pubkey = "") ?(signed_at = 0.0) ?(sig_b64 = "") () =
    (* B174: always report opaque_host_id so /stats machines count hosts, not
       sessions. Prefer Host_id; fall back to the connector node_id (which is
       already the host hash on the managed path). *)
    let opaque_host_id =
      try Host_id.compute_host_hash () with _ ->
        if node_id <> "" then node_id else ""
    in
    let body = `Assoc (
      [
        ("node_id", `String node_id);
        ("session_id", `String session_id);
        ("alias", `String alias);
        ("client_type", `String client_type);
        (* B149: connection metadata — the relay aggregates these into the
           public /stats connected.by_version / by_os counts (counts only,
           never tied back to an alias in that surface). *)
        ("client_version", `String Version.version);
        ("client_os", `String (Relay_common.client_os ()));
        ("ttl", `Int (int_of_float ttl));
      ]
      @ (if opaque_host_id <> "" then
           [ ("opaque_host_id", `String opaque_host_id) ]
         else [])
    ) in
    let body, actor_id =
      match t.identity with
      | None -> body, ""
      | Some identity ->
          let proof = Relay_signed_ops.sign_register identity ~alias ~relay_url:t.base_url in
          let open Yojson.Safe.Util in
          let base_list = to_assoc body in
          `Assoc (
            base_list @
            [
              ("identity_pk", `String proof.identity_pk_b64);
              ("signature", `String proof.sig_b64);
              ("nonce", `String proof.nonce);
              ("timestamp", `String proof.ts);
            ]
          ),
          proof.identity_pk_b64
    in
    let body =
      if enc_pubkey <> "" then
        let open Yojson.Safe.Util in
        let base_list = to_assoc body in
        `Assoc (base_list @ [("enc_pubkey", `String enc_pubkey); ("signed_at", `Float signed_at); ("sig_b64", `String sig_b64)])
      else body
    in
    post_with_pow_retry t "/register" ~alias ~route:"register" ~actor_id body

  let heartbeat t ~node_id ~session_id ?(alias : string option) () =
    (* B174: report host id on heartbeat so long-lived sessions heal
       connected.machines without a full re-register. *)
    let opaque_host_id =
      try Host_id.compute_host_hash () with _ ->
        if node_id <> "" then node_id else ""
    in
    let fields = [
      ("node_id", `String node_id);
      ("session_id", `String session_id);
    ] in
    let fields =
      if opaque_host_id <> "" then
        fields @ [ ("opaque_host_id", `String opaque_host_id) ]
      else fields
    in
    post t "/heartbeat" ?alias (`Assoc fields)

  let send t ~from_alias ~to_alias ~content ?message_id () =
    let base = [
      ("from_alias", `String from_alias);
      ("to_alias", `String to_alias);
      ("content", `String content);
    ] in
    let body = match message_id with
      | Some mid -> ("message_id", `String mid) :: base
      | None -> base
    in
    post t "/send" ~alias:from_alias (`Assoc body)

  let poll_inbox t ~node_id ~session_id ?(alias : string option) () =
    post t "/poll_inbox" ?alias (`Assoc [
      ("node_id", `String node_id);
      ("session_id", `String session_id);
    ])

end

(* ---------------------------------------------------------------------------
 * Sync (slice 2)
 * --------------------------------------------------------------------------- *)

(* Total on non-object responses (H10 item 5) via [member_or_null]. *)
let json_bool_member ~key json =
  match member_or_null key json with
  | `Bool b -> b
  | _ -> false

let json_list_member ~key json =
  match member_or_null key json with
  | `List lst -> lst
  | _ -> []

(* H9 (rows B095/B238): minimum deliverable-row contract for relay-pulled
   inbound rows. Mirrors exactly what [C2c_broker.message_of_json] REQUIRES:
   string [from_alias] / [to_alias] / [content] ([member .. |> to_string]
   raises Yojson Type_error on anything else); every other field is
   optional-with-default there (ts/deferrable/ephemeral/reply_via/
   enc_status/message_id). A row failing this check must never reach
   [append_to_local_inbox] — pre-H9 one such row wedged EVERY broker-side
   read of that session's inbox.

   Design note (drop-and-log vs dead-letter): rejected rows are dropped
   with a recorded [poll_inbox] sync error + [inbound_rejected] counter in
   connector-state, NOT dead-lettered. The connector's existing DLQ
   ([append_dlq_entry] / remote-outbox-dlq.jsonl) is typed for OUTBOUND
   outbox entries (ob_from/ob_to/ob_content) and doesn't fit arbitrary
   inbound JSON; a schema-invalid row also carries no trustworthy fields
   to key a retry on. If forensics ever need the raw rows, the upgrade
   path is a sibling inbound-DLQ jsonl file fed here. *)
let inbound_row_is_deliverable = function
  | `Assoc fields ->
      let is_str k =
        match List.assoc_opt k fields with Some (`String _) -> true | _ -> false
      in
      is_str "from_alias" && is_str "to_alias" && is_str "content"
  | _ -> false



(* ---------------------------------------------------------------------------
 * S5c Phase B: Broker WS client — connects to relay as outbound observer
 * --------------------------------------------------------------------------- *)

let parse_relay_url url =
  match String.split_on_char ':' url with
  | host :: port_str :: _ ->
      let port = int_of_string port_str in
      (host, port)
  | _ ->
      let default_port = if String.starts_with ~prefix:"https" url then 443 else 80 in
      (url, default_port)

let handle_pseudo_registration broker_root json =
  let open Yojson.Safe.Util in
  try
    let alias = json |> member "alias" |> to_string in
    let binding_id = json |> member "binding_id" |> to_string in
    let ed25519_pubkey = json |> member "ed25519_pubkey" |> to_string in
    let x25519_pubkey = json |> member "x25519_pubkey" |> to_string in
    let machine_ed25519_pubkey = json |> member "machine_ed25519_pubkey" |> to_string in
    let provenance_sig = json |> member "provenance_sig" |> to_string in
    let bound_at = json |> member "bound_at" |> to_float in
    Printf.printf "[broker-ws] pseudo_registration: alias=%s binding_id=%s\n%!" alias binding_id;
    upsert_pseudo_registration broker_root ~binding_id ~alias ~ed25519_pubkey ~x25519_pubkey
      ~machine_ed25519_pubkey ~provenance_sig ~bound_at;
    Printf.printf "[broker-ws]   stored in pseudo_registrations.json\n%!"
  with e ->
    Printf.eprintf "[broker-ws] error handling pseudo_registration: %s\n%!" (Printexc.to_string e)

let handle_pseudo_unregistration broker_root json =
  let open Yojson.Safe.Util in
  try
    let binding_id = json |> member "binding_id" |> to_string in
    Printf.printf "[broker-ws] pseudo_unregistration: binding_id=%s\n%!" binding_id;
    remove_pseudo_registration broker_root ~binding_id;
    Printf.printf "[broker-ws]   removed from pseudo_registrations.json\n%!"
  with e ->
    Printf.eprintf "[broker-ws] error handling pseudo_unregistration: %s\n%!" (Printexc.to_string e)

let ws_client_loop (session : Relay_ws_frame.Client_session.t) broker_root binding_id t =
  let rec loop () =
    Lwt.catch (fun () ->
      session |> Relay_ws_frame.Client_session.recv >>= function
      | None ->
          Printf.printf "[broker-ws] connection closed\n%!";
          Lwt.return ()
      | Some (`Ping) ->
          loop ()
      | Some (`Text raw) ->
          (try
            let json = Yojson.Safe.from_string raw in
            let open Yojson.Safe.Util in
            let msg_type = json |> member "type" |> to_string in
            match msg_type with
            | "pseudo_registration" -> handle_pseudo_registration broker_root json
            | "pseudo_unregistration" -> handle_pseudo_unregistration broker_root json
            | _ -> Printf.printf "[broker-ws] unknown frame type: %s\n%!" msg_type
          with e ->
            Printf.eprintf "[broker-ws] error parsing frame: %s\n%!" (Printexc.to_string e));
          loop ()
      | Some (`Binary raw) ->
          Printf.printf "[broker-ws] unexpected binary frame\n%!";
          loop ()
      | Some (`Close (code, reason)) ->
          Printf.printf "[broker-ws] server closed: code=%d reason=%s\n%!" code reason;
          Lwt.return ()
    ) (fun exn ->
      Printf.eprintf "[broker-ws] connection error: %s\n%!" (Printexc.to_string exn);
      Lwt.return ()
    )
  in
  Lwt.async (fun () ->
    loop () >>= fun () ->
    t.active_ws_bindings <- List.filter (fun id -> id <> binding_id) t.active_ws_bindings;
    Printf.printf "[broker-ws] connection ended for binding %s\n%!" binding_id;
    Lwt.return ()
  )

let broker_ws_connect ~relay_url ~binding_id ~broker_root ~(verbose : bool) ~(t : t) =
  let host, port = parse_relay_url relay_url in
  let path = "/observer/" ^ binding_id in
  if verbose then Printf.printf "[broker-ws] connecting to %s:%d%s\n%!" host port path;
  Lwt.catch (fun () ->
    let addr = Lwt_unix.ADDR_INET (Unix.inet_addr_of_string host, port) in
    let sock = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Lwt_unix.connect sock addr >>= fun () ->
    let request, masking_key = Relay_ws_frame.make_client_handshake_request ~host:(Printf.sprintf "%s:%d" host port) ~path in
    let request_bytes = Bytes.of_string request in
    Lwt_unix.write sock request_bytes 0 (Bytes.length request_bytes) >>= fun _ ->
    let ic = Lwt_io.of_fd ~mode:Lwt_io.Input sock in
    let oc = Lwt_io.of_fd ~mode:Lwt_io.Output sock in
    let buf = Bytes.create 4096 in
    Lwt_io.read_into ic buf 0 4096 >>= fun n ->
    let response = Bytes.sub_string buf 0 n in
    if not (String.length response >= 12 && String.sub response 0 12 = "HTTP/1.1 101") then (
      Printf.eprintf "[broker-ws] handshake failed: %s\n%!" (String.sub response 0 (min n 200));
      Lwt.return ()
    ) else (
      if verbose then Printf.printf "[broker-ws] handshake succeeded\n%!";
      let session = Relay_ws_frame.Client_session.create ic oc masking_key in
      ws_client_loop session broker_root binding_id t;
      Lwt.return ()
    )
  ) (fun exn ->
    Printf.eprintf "[broker-ws] connection failed: %s\n%!" (Printexc.to_string exn);
    t.active_ws_bindings <- List.filter (fun id -> id <> binding_id) t.active_ws_bindings;
    Lwt.return ()
  )

let maintain_ws_connections (t : t) : unit =
  let bindings = read_mobile_bindings t.broker_root in
  let binding_ids = List.map (fun mb -> mb.mb_binding_id) bindings in
  let new_bindings = List.filter (fun id -> not (List.mem id t.active_ws_bindings)) binding_ids in
  List.iter (fun binding_id ->
    if t.verbose then Printf.printf "[broker-ws] maintaining connection to binding %s\n%!" binding_id;
    t.active_ws_bindings <- binding_id :: t.active_ws_bindings;
    ignore (broker_ws_connect ~relay_url:t.relay_url ~binding_id ~broker_root:t.broker_root ~verbose:t.verbose ~t)
  ) new_bindings

(* ---------------------------------------------------------------------------
 * B010: relay-event passthrough
 *
 * The connector is the natural producer for relay-originated "degrading
 * events" — it owns the HTTP exchange and so sees difficulty challenges,
 * rate-limit rejections, PoW-retry failures, and dead-letter decisions. We
 * funnel those observations through the pure C2c_relay_alert module (severity
 * + edge-triggered dedup + routing). Sender-actionable events are injected as
 * messages from the reserved [c2c-system] alias; connector-wide difficulty
 * changes stay in the connector log so they cannot wake idle agents.
 * --------------------------------------------------------------------------- *)

let system_alias = "c2c-system"

let alias_eq a b = String.lowercase_ascii a = String.lowercase_ascii b

(* Extract a PoW difficulty from a relay response, wherever it may appear:
   - [pow_minted_difficulty]: annotation added by Pow_client.post_with_retry
     when a register only succeeded after we minted PoW (success body has no
     difficulty otherwise);
   - top-level [required.difficulty]: a raw pow_required challenge body (the
     connector's /send path does not auto-mint, so it sees these directly);
   - nested [relay_response.required.difficulty]: a pow_retry_failed error
     wraps the still-required challenge. *)
let response_difficulty json =
  let open Yojson.Safe.Util in
  (* B087: [Yojson.Safe.Util.member] RAISES Type_error on non-objects. A
     normal relay success response has no [required] field, so the old
     [member "difficulty" (member "required" json)] crashed on EVERY success
     ([member "required"] -> [Null] -> [member "difficulty" Null] -> raise),
     which took down the whole sync pass. Guard every descent: only read
     members from actual [`Assoc] objects, and return None (no difficulty)
     for null/missing/wrong-type inputs instead of raising. *)
  let member_opt name = function
    | `Assoc _ as obj -> obj |> member name
    | _ -> `Null
  in
  let as_int = function
    | `Int n -> Some n
    | `Float f -> Some (int_of_float f)
    | _ -> None
  in
  let required_difficulty j =
    as_int (member_opt "difficulty" (member_opt "required" j))
  in
  match as_int (member_opt "pow_minted_difficulty" json) with
  | Some n -> Some n
  | None ->
      (match required_difficulty json with
       | Some n -> Some n
       | None -> required_difficulty (member_opt "relay_response" json))

(* Total on non-object responses (H10 item 5) via [member_or_null]. *)
(* B213/B237/B244: accept every rate-limit code the monitor classifier knows.
   Production historically emitted {error:"rate_limit_exceeded", retry_after:N}
   without ok:false. After B237 reconcile_status that normalizes to
   error_code=rate_limit_exceeded (honest envelope). Older dishonest override
   shape used http_error_429 with the original under relay_response — still
   matched so connectors back off under either path. *)
let rate_limit_code = function
  | "rate_limit_exceeded" | "rate_limit" | "rate_limited" | "http_error_429" ->
      true
  | _ -> false

let response_is_rate_limited json =
  let code_match = function
    | `String s -> rate_limit_code s
    | _ -> false
  in
  if code_match (member_or_null "error_code" json) then true
  else if code_match (member_or_null "error" json) then true
  else
    match member_or_null "http_status" json with
    | `Int 429 -> true
    | _ ->
        (match member_or_null "relay_response" json with
         | `Assoc _ as nested ->
             code_match (member_or_null "error" nested)
             || code_match (member_or_null "error_code" nested)
         | _ -> false)

(* B244: positive retry_after seconds from a 429 body (top-level or nested
   under relay_response after reconcile). Pure. *)
let extract_retry_after json : float option =
  let positive = function
    | `Float f when Float.is_finite f && f > 0. -> Some f
    | `Int n when n > 0 -> Some (float_of_int n)
    | _ -> None
  in
  let from = function
    | `Assoc fields ->
        (match List.assoc_opt "retry_after" fields with
         | Some v -> positive v
         | None -> None)
    | _ -> None
  in
  match from json with
  | Some f -> Some f
  | None ->
      (match member_or_null "relay_response" json with
       | nested -> from nested)

let response_is_pow_retry_failed json =
  match member_or_null "error_code" json with
  | `String "pow_retry_failed" -> true
  | _ -> false

(* Build a single inbox message from the reserved system alias. Shape matches
   C2c_broker.message_of_json (from_alias/to_alias/content/ts/message_id). *)
let system_message_json ~to_alias ~content =
  `Assoc [
    ("from_alias", `String system_alias);
    ("to_alias", `String to_alias);
    ("content", `String content);
    ("ts", `Float (Unix.gettimeofday ()));
    ("message_id", `String (Printf.sprintf "sys-%d-%d-%d"
       (Unix.getpid ()) (int_of_float (Unix.gettimeofday ())) (Random.bits ())));
  ]

(* Deliver alert emissions to the connector log or relevant local inboxes.
   [regs] is the (session_id, alias, client_type) list for this broker.
   Returns the count of system messages written. *)
let deliver_alert_emissions broker_root regs (emissions : C2c_relay_alert.emission list) : int =
  List.fold_left (fun delivered (em : C2c_relay_alert.emission) ->
    let targets =
      match em.C2c_relay_alert.target with
      | C2c_relay_alert.Connector_log ->
          Printf.eprintf "[relay-connector] %s\n%!" em.C2c_relay_alert.body;
          []
      | C2c_relay_alert.Broadcast ->
          List.map (fun (sid, al, _) -> (sid, al)) regs
      | C2c_relay_alert.Dm alias ->
          List.filter_map
            (fun (sid, al, _) -> if alias_eq al alias then Some (sid, al) else None)
            regs
    in
    List.fold_left (fun d (sid, al) ->
      let m = system_message_json ~to_alias:al ~content:em.C2c_relay_alert.body in
      d + append_to_local_inbox broker_root sid [m]
    ) delivered targets
  ) 0 emissions

let sync (t : t) : sync_result Lwt.t =
  let client = Relay_client.make ?token:t.token ?identity:t.identity t.relay_url in
  let regs, skipped_regs = read_local_registrations_with_skipped t.broker_root in
  if t.verbose && skipped_regs > 0 then
    Printf.printf
      "[relay-connector] skipped %d dead/unverified historical registration(s) in %s\n%!"
      skipped_regs t.broker_root;
  (* Reload each pass so an operator can tighten local ingress controls without
     restarting the connector.  A present-but-invalid policy fails closed for
     inbound rows; registration, heartbeat, and outbound delivery continue. *)
  let inbound_policy = load_inbound_policy t.broker_root in

  (* B010: accumulate relay-event observations across this sync pass. *)
  let obs_difficulty = ref None in
  (* [obs_rate_limited] covers any 429 for sync/backoff accounting. Alert
     routing additionally distinguishes connector-wide operations from every
     affected outbox sender. *)
  let obs_rate_limited = ref false in
  let obs_connector_rate_limited = ref false in
  let obs_rate_senders = ref [] in
  let obs_retry_after = ref (None : float option) in
  (* B244: once any op this pass is rate-limited, skip remaining
     heartbeat/register/send/poll calls. Extra requests only deepen a
     NAT-shared IP bucket deficit and cannot succeed until refill. *)
  let abort_on_rate_limit = ref false in
  let obs_pow_failed = ref false in
  let obs_pow_sender = ref None in
  let obs_dlqs = ref [] in
  let note_difficulty d =
    obs_difficulty :=
      Some (max d (Option.value ~default:0 !obs_difficulty))
  in
  let note_retry_after json =
    match extract_retry_after json with
    | None -> ()
    | Some ra ->
        obs_retry_after :=
          (match !obs_retry_after with
           | None -> Some ra
           | Some prev -> Some (Float.max prev ra))
  in
  let note_observation ~(sender : string option) json =
    (match response_difficulty json with Some d -> note_difficulty d | None -> ());
    if response_is_rate_limited json then begin
      obs_rate_limited := true;
      abort_on_rate_limit := true;
      note_retry_after json;
      match sender with
      | None -> obs_connector_rate_limited := true
      | Some sender ->
          if not (C2c_relay_alert.alias_mem sender !obs_rate_senders) then
            obs_rate_senders := sender :: !obs_rate_senders
    end;
    if response_is_pow_retry_failed json then begin
      obs_pow_failed := true;
      (* keep the first known sender for routing *)
      match !obs_pow_sender, sender with
      | None, Some _ -> obs_pow_sender := sender
      | _ -> ()
    end
  in

  (* 0. Maintain WS connections to mobile bindings *)
  maintain_ws_connections t;

  (* 1. Register / heartbeat each local session *)
  (* Drop cached relay registrations that are no longer locally Alive. Without
     this intersection, a process that dies after the first pass is still
     heartbeated and polled forever even though it disappeared from [regs]. *)
  t.registered <- retain_eligible_registered regs t.registered;
  let registered, heartbeated, new_registered, reg_errors =
    List.fold_left (fun (registered, heartbeated, reg_list, errs) (session_id, alias, client_type) ->
      if !abort_on_rate_limit then
        (registered, heartbeated, reg_list, errs)
      else if List.mem session_id t.registered then
        let json = Lwt_main.run (Relay_client.heartbeat client ~node_id:t.node_id ~session_id ~alias ()) in
        note_observation ~sender:None json;
        if json_bool_member ~key:"ok" json then
          (registered, alias :: heartbeated, reg_list, errs)
        else
          let detail = Yojson.Safe.to_string json in
          (registered, heartbeated, reg_list, ("heartbeat", detail) :: errs)
      else
        let json = Lwt_main.run (Relay_client.register client
          ~node_id:t.node_id ~session_id ~alias ~client_type ~ttl:t.heartbeat_ttl ()) in
        note_observation ~sender:None json;
        if json_bool_member ~key:"ok" json then
          (alias :: registered, heartbeated, session_id :: reg_list, errs)
        else
          let detail = Yojson.Safe.to_string json in
          (registered, heartbeated, reg_list, ("register", detail) :: errs)
    ) ([], [], t.registered, []) regs
  in
  t.registered <- new_registered;

  (* 2. Forward outbox entries with retry + DLQ — LOCKED to prevent TOCTOU
     race with append_outbox_entry (MCP send). The window is read_outbox →
     HTTP sends → write_outbox (trunc). Without the lock, a concurrent
     append between read and write is silently lost. Lock is exclusive so we
     also serialise with any other outbox reader/writer. *)
  let outbox_forwarded, outbox_failed, remaining_outbox, dlqed, send_errors =
    with_outbox_lock t.broker_root (fun () ->
      let outbox = read_outbox t.broker_root in
      List.fold_left (fun (fwd, failed, remaining, dlqed, errs) entry ->
        if !abort_on_rate_limit then
          (* Keep the entry for the next pass; do not burn attempts on 429. *)
          (fwd, failed, entry :: remaining, dlqed, errs)
        else begin
        let json = Lwt_main.run (Relay_client.send client
          ~from_alias:entry.ob_from
          ~to_alias:entry.ob_to
          ~content:entry.ob_content
          ?message_id:entry.ob_msg_id ()) in
        note_observation ~sender:(Some entry.ob_from) json;
        if json_bool_member ~key:"ok" json then
          (fwd + 1, failed, remaining, dlqed, errs)
        else if response_is_rate_limited json then
          (* B244: rate-limit is not a permanent/attempt failure — keep the
             entry unchanged so we do not burn attempt budget while throttled. *)
          (fwd, failed, entry :: remaining, dlqed,
           ("send", "rate_limit_exceeded: " ^ Yojson.Safe.to_string json) :: errs)
        else
          let err_class = classify_error json in
          let now = Unix.gettimeofday () in
          let too_old = now -. entry.ob_enqueued_at > max_age_seconds in
          let over_attempts = entry.ob_attempts >= max_attempts in
          let detail = Yojson.Safe.to_string json in
          (* B010: record a discrete DLQ event so the sender is DM'd. *)
          let note_dlq reason =
            obs_dlqs := { C2c_relay_alert.dlq_sender = entry.ob_from;
                          dlq_to = entry.ob_to; dlq_reason = reason } :: !obs_dlqs
          in
          if err_class = "unknown_alias" || err_class = "recipient_dead" then
            (* Permanent error: immediate DLQ *)
            let () = append_dlq_entry t.broker_root entry ~reason:err_class in
            let () = note_dlq err_class in
            (fwd, failed + 1, remaining, dlqed + 1, ("send", err_class ^ ": " ^ detail) :: errs)
          else if over_attempts || too_old then
            (* Backstop reached: DLQ *)
            let dlq_reason = if over_attempts then "max_attempts" else "max_age" in
            let () = append_dlq_entry t.broker_root { entry with ob_last_error = Some err_class } ~reason:dlq_reason in
            let () = note_dlq dlq_reason in
            (fwd, failed + 1, remaining, dlqed + 1, ("send", dlq_reason ^ ": " ^ detail) :: errs)
          else
            (* Retry: increment attempts, update last_error, keep in outbox *)
            let updated = { entry with ob_attempts = entry.ob_attempts + 1; ob_last_error = Some err_class } in
            (fwd, failed + 1, updated :: remaining, dlqed, ("send", err_class ^ ": " ^ detail) :: errs)
        end
      ) (0, 0, [], 0, []) outbox
    )
  in
  write_outbox t.broker_root (List.rev remaining_outbox);

  (* 3. Poll inbound for registered sessions. H9: validate each row against
     the minimum broker-inbox contract BEFORE it touches the local inbox
     file; drop-and-log invalid rows (see [inbound_row_is_deliverable]) so a
     misbehaving relay can neither inflate [inbound_delivered] nor poison
     the local inbox. Partial-batch delivery: valid rows in a batch with
     invalid siblings still deliver. B244: skip remaining polls once the
     pass is already rate-limited. *)
  let initial_poll_errors =
    match inbound_policy with
    | Ok _ -> []
    | Error detail -> [ ("inbound_policy", detail ^ "; inbound delivery denied") ]
  in
  let inbound_delivered, inbound_rejected, poll_errors =
    List.fold_left (fun (delivered, rejected, errs) (session_id, alias, _) ->
      if !abort_on_rate_limit then
        delivered, rejected, errs
      else if List.mem session_id t.registered then
        let json = Lwt_main.run (Relay_client.poll_inbox client ~node_id:t.node_id ~session_id ~alias ()) in
        note_observation ~sender:None json;
        let msgs = json_list_member ~key:"messages" json in
        if msgs <> [] then begin
          let deliverable, rejection_reasons, rate_state_error =
            filter_inbound_messages_persisted ~now:(Unix.gettimeofday ())
              ~broker_root:t.broker_root ~expected_recipient:alias
              inbound_policy msgs
          in
          let errs =
            if rejection_reasons = [] then errs
            else
              let detail = Printf.sprintf
                "dropped %d policy-rejected inbound row(s) of %d for %s (%s)"
                (List.length rejection_reasons) (List.length msgs) alias
                (summarize_inbound_rejections rejection_reasons)
              in
              ("poll_inbox", detail) :: errs
          in
          let errs = match rate_state_error with
            | None -> errs
            | Some detail -> ("inbound_rate_state", detail) :: errs
          in
          let delivered =
            if deliverable = [] then delivered
            else delivered + append_to_local_inbox t.broker_root session_id deliverable
          in
          delivered, rejected + List.length rejection_reasons, errs
        end
        else if json_bool_member ~key:"ok" json then
          delivered, rejected, errs
        else
          let detail = Yojson.Safe.to_string json in
          delivered, rejected, ("poll_inbox", detail) :: errs
      else
        delivered, rejected, errs
    ) (0, 0, initial_poll_errors) regs
  in

  let last_error = match reg_errors @ send_errors @ poll_errors with
    | [] -> None
    | (op, detail) :: _ ->
        Some { err_op = op; err_detail = detail; err_ts = Unix.gettimeofday () }
  in

  (* B010/B222: turn this sync's observations into severity-tagged emissions
     (edge-triggered against t.alert_state). Difficulty changes are logged;
     sender-actionable emissions are injected as c2c-system messages into the
     appropriate local inboxes. *)
  let observation = {
    C2c_relay_alert.obs_difficulty = !obs_difficulty;
    obs_rate_limited = !obs_connector_rate_limited;
    obs_rate_limited_senders = List.rev !obs_rate_senders;
    obs_pow_retry_failed = !obs_pow_failed;
    obs_pow_retry_sender = !obs_pow_sender;
    obs_dlqs = List.rev !obs_dlqs;
  } in
  let emissions, new_alert_state = C2c_relay_alert.step t.alert_state observation in
  t.alert_state <- new_alert_state;
  let alerts_emitted = deliver_alert_emissions t.broker_root regs emissions in

  (* B209: pair every currently relay-registered session with its alias so
     connector-state.json records the authoritative (node_id, session_id)
     binding per alias. [t.registered] holds the session_ids that are live on
     the relay after this sync; [regs] maps session_id -> alias. *)
  let registered_sessions =
    List.filter_map
      (fun (session_id, alias, _client_type) ->
        if List.mem session_id t.registered then Some (alias, session_id) else None)
      regs
  in

  Lwt.return {
    registered;
    registered_sessions;
    heartbeated;
    outbox_forwarded;
    outbox_failed;
    outbox_dlqed = dlqed;
    alerts_emitted;
    inbound_delivered;
    inbound_rejected;
    rate_limited = !obs_rate_limited;
    retry_after_s = !obs_retry_after;
    last_error;
  }

(* ---------------------------------------------------------------------------
 * Run loop with graceful signal handling
 * --------------------------------------------------------------------------- *)

(* B210/B244: bounded, jittered exponential backoff for relay rate-limit (429)
   rejections. A connector that keeps polling at a fixed interval while the
   relay is returning 429 both wastes requests and — when several connectors
   share a host and a wall-clock-aligned interval — resynchronises into a
   machine-wide receive storm. On each consecutive rate-limited pass the delay
   grows 2^strikes from the base interval, capped at [rate_limit_backoff_cap_s];
   additive jitter in [0, base) desynchronises concurrent connectors so they do
   not all wake together. [strikes]=0 (a clean pass) returns the base interval
   unless [retry_after] is set (B244: honor the relay's advertised recovery
   wait even on the first strike). When both expo and retry_after are present,
   take the max so NAT-shared buckets get a real refill window.
   Pure so it is unit-testable. *)
let rate_limit_backoff_cap_s = 300.0

let rate_limit_backoff ~base ~strikes ?(retry_after = 0.) () =
  let expo =
    if strikes <= 0 then base
    else begin
      let grown = base *. (2.0 ** float_of_int (min strikes 20)) in
      Float.min grown rate_limit_backoff_cap_s
    end
  in
  let ra =
    if Float.is_finite retry_after && retry_after > 0. then retry_after else 0.
  in
  if strikes <= 0 && ra <= 0. then base
  else begin
    let core = Float.max expo ra in
    let core = Float.min core rate_limit_backoff_cap_s in
    let jitter = Random.float (Float.max 0.0 base) in
    core +. jitter
  end

(* B211/B228: staleness-exit watchdog for the *completes-but-erroring* wedge.
   The B181 SIGALRM watchdog only catches a sync pass that HANGS past the
   wall-clock deadline. A different wedge is just as fatal: each pass returns
   [Ok result] promptly but with [last_error = Some _] (e.g. every HTTP call
   fails fast with request_timeout / connection_error), so [watchdog_strikes]
   resets to 0 every pass, the process stays alive indefinitely, and
   [last_ok_ts] never advances — a live PID with a stale bridge (B211, and the
   B228 recurrence where whoami already reported wedged at ~2m while the
   process kept running until a manual restart). Neither the strike counter
   nor the 429 backoff ever terminates it.

   Fix: track wall-clock time since the last pass that made progress — either
   a fully successful sync ([last_error = None]) or a rate-limited pass (the
   relay is up and deliberately throttling us; B210 backs off, restarting
   would just re-hit the 429). When no progress has been made for
   [stale_exit_threshold_s], the connector is wedged: log an actionable line
   and exit 3 so a supervisor (managed `c2c start relay-connect`) restarts it.
   Default threshold (B228) is max(180, interval×6) so self-heal trails the
   doctor 120s liveness window by a small margin, not by ~10 minutes.
   Unsupervised, the exit makes whoami/doctor report `absent`/`stale` with the
   documented `c2c restart relay-connect` remediation instead of a silently
   wedged live PID. Both predicates are pure so they are unit-testable. *)
let stale_exit_threshold_s ~interval =
  match Option.bind (Sys.getenv_opt "C2C_RELAY_CONNECTOR_STALE_EXIT_S")
          float_of_string_opt with
  | Some v when v > 0.0 -> v
  | _ ->
      (* B228: self-heal soon after doctor marks the bridge dead (120s
         freshness). Floor 180s / 6×interval → 3 min at the default 30s poll. *)
      Float.max 180.0 (interval *. 6.0)

(* [true] when the connector has made no forward progress for at least
   [threshold] wall-clock seconds and should exit so a supervisor restarts it.
   [last_progress] is the epoch of the most recent ok / rate-limited pass. *)
let should_exit_stale ~now ~last_progress ~threshold =
  now -. last_progress >= threshold

(* A sync pass counts as forward progress if it fully succeeded or was merely
   rate-limited (relay reachable, throttling). Any other errored pass does NOT
   reset the staleness timer. *)
let sync_made_progress (result : sync_result) =
  result.last_error = None || result.rate_limited

(* B181/B228: wall-clock cap for one sync pass so a hung HTTP path cannot leave
   a multi-hour PID with stale last_sync. Defaults to max(90s, 4 * interval).
   Implemented with SIGALRM because [sync] drives work via nested
   Lwt_main.run (a Lwt.pick sibling never races those calls).

   B228: raising an exception from the SIGALRM handler is unreliable under
   nested Lwt_main.run / Cohttp — the exception can be swallowed and leave a
   live PID with a dead bridge (the observed B228 wedge). On timeout we
   force-exit 3 so a supervisor restarts (first hang; no multi-strike wait).
   The [Error `Watchdog] path remains only for injected/mock sync_once
   failures that return that variant without going through the real alarm. *)
let sync_watchdog_s (t : t) =
  max 90.0 (t.interval *. 4.0)

exception Sync_watchdog of string

let run_sync_once ?shutdown ?(sync_fn = sync) (t : t) :
    (sync_result, [ `Exn of exn | `Watchdog of string ]) result =
  let deadline = sync_watchdog_s t in
  let deadline_i =
    int_of_float (Float.ceil deadline) |> max 1
  in
  (* B228: advance last_sync at pass start so a hung HTTP path is visible as
     erroring (fresh last_sync, stale last_ok) instead of a full freeze. *)
  touch_connector_last_sync t.broker_root;
  let prev_alrm = Sys.signal Sys.sigalrm Sys.Signal_ignore in
  let finally () =
    ignore (Unix.alarm 0);
    Sys.set_signal Sys.sigalrm prev_alrm
  in
  Fun.protect ~finally (fun () ->
      Sys.set_signal Sys.sigalrm
        (Sys.Signal_handle
           (fun _ ->
              match shutdown with
              | Some requested when !requested -> Unix._exit 0
              | _ ->
                  (try
                     Printf.eprintf
                       "[relay-connector] wedged: sync wall-clock exceeded %ds \
                        — force-exit so a supervisor can restart (B181/B228)\n%!"
                       deadline_i
                   with _ -> ());
                  Unix._exit 3));
      ignore (Unix.alarm deadline_i);
      try Ok (Lwt_main.run (sync_fn t)) with
      | Sync_watchdog detail -> Error (`Watchdog detail)
      | exn -> Error (`Exn exn))

(* B217: a signal handler that only sets [shutdown] cannot make progress while
   the connector is indefinitely pending inside [Lwt_main.run]. Allow a short
   graceful window, then force-exit from the SIGALRM handler. [Unix._exit] is
   deliberate: unlike an OCaml exception, an Lwt catch boundary cannot consume
   it and leave the process wedged. *)
let with_bounded_shutdown ?(grace_s = 2.0) ~shutdown ~on_signal f =
  let grace_i = max 1 (int_of_float (Float.ceil grace_s)) in
  let handle_signal _ =
    if !shutdown then Unix._exit 0
    else begin
      shutdown := true;
      on_signal ();
      ignore (Unix.alarm grace_i)
    end
  in
  let previous_alarm =
    Sys.signal Sys.sigalrm
      (Sys.Signal_handle (fun _ -> Unix._exit 0))
  in
  let previous_term =
    Sys.signal Sys.sigterm (Sys.Signal_handle handle_signal)
  in
  let previous_int =
    Sys.signal Sys.sigint (Sys.Signal_handle handle_signal)
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Unix.alarm 0);
      Sys.set_signal Sys.sigint previous_int;
      Sys.set_signal Sys.sigterm previous_term;
      Sys.set_signal Sys.sigalrm previous_alarm)
    f

let sleep_interruptibly delay =
  try Unix.sleepf delay with
  | Unix.Unix_error (Unix.EINTR, _, _) -> ()

(* B228: sleep in short chunks so a long rate-limit backoff cannot delay the
   stale-exit check for the full backoff window. [should_stop] is polled each
   chunk (typically shutdown || stale-exit side effects). *)
let sleep_interruptibly_until ~slice_s ~should_stop delay =
  let deadline = Unix.gettimeofday () +. Float.max 0.0 delay in
  let slice = Float.max 0.05 slice_s in
  let rec loop () =
    if should_stop () then ()
    else
      let remaining = deadline -. Unix.gettimeofday () in
      if remaining <= 0.0 then ()
      else begin
        sleep_interruptibly (Float.min slice remaining);
        loop ()
      end
  in
  loop ()

let run ?(sync_once = fun shutdown t -> run_sync_once ~shutdown t)
    (t : t) : unit =
  (* B210: seed per-process so the backoff jitter actually desynchronises
     concurrent connectors (without a seed every process draws the same
     sequence, re-aligning them into a storm). *)
  Random.self_init ();
  let shutdown = ref false in
  let watchdog_strikes = ref 0 in
  (* B210: consecutive rate-limited passes drive the bounded backoff below. *)
  let rl_strikes = ref 0 in
  (* B244: last observed retry_after (seconds) for pacing; 0. means absent. *)
  let last_retry_after = ref 0. in
  (* B211: wall-clock epoch of the last pass that made forward progress (ok or
     rate-limited). Seeded to process start so a connector that NEVER succeeds
     still exits after the staleness threshold. *)
  let last_progress = ref (Unix.gettimeofday ()) in
  let stale_threshold = stale_exit_threshold_s ~interval:t.interval in
  let check_stale_exit () =
    if not !shutdown
       && should_exit_stale ~now:(Unix.gettimeofday ())
            ~last_progress:!last_progress ~threshold:stale_threshold
    then begin
      Printf.eprintf
        "[relay-connector] wedged: no successful sync for %.0fs (>= %.0fs \
         threshold) though the process is alive — exiting so a supervisor can \
         restart (B211/B228). Recover manually with: c2c restart relay-connect\n%!"
        (Unix.gettimeofday () -. !last_progress) stale_threshold;
      exit 3
    end
  in
  let rec loop () =
    if !shutdown then () else (
      (match sync_once shutdown t with
       | Ok result ->
           watchdog_strikes := 0;
           if result.rate_limited then incr rl_strikes
           else begin
             rl_strikes := 0;
             last_retry_after := 0.
           end;
           (match result.retry_after_s with
            | Some ra when result.rate_limited -> last_retry_after := ra
            | _ -> ());
           if sync_made_progress result then
             last_progress := Unix.gettimeofday ();
           write_connector_state ~node_id:t.node_id t.broker_root result;
           let err_str = match result.last_error with
             | None -> ""
             | Some e ->
                 Printf.sprintf " [%s: %s]" e.err_op
                   (if String.length e.err_detail > 80 then
                     String.sub e.err_detail 0 80 ^ "..."
                   else e.err_detail)
           in
           let rl_tag =
             if result.rate_limited then
               match result.retry_after_s with
               | Some ra -> Printf.sprintf " RATE_LIMITED(retry_after=%.1fs)" ra
               | None -> " RATE_LIMITED"
             else ""
           in
           (* B244: rate-limits are operator-visible on stdout summary AND
              stderr so log scrapers / `c2c doctor` greps cannot miss them. *)
           Printf.printf "[relay-connector] sync: registered=%d heartbeated=%d fwd=%d failed=%d dlqed=%d inbound=%d rejected=%d alerts=%d%s%s\n%!"
             (List.length result.registered)
             (List.length result.heartbeated)
             result.outbox_forwarded
             result.outbox_failed
             result.outbox_dlqed
             result.inbound_delivered
             result.inbound_rejected
             result.alerts_emitted
             err_str
             rl_tag;
           if result.rate_limited then
             Printf.eprintf
               "[relay-connector] RATE_LIMITED (HTTP 429) this sync — remaining \
                heartbeat/poll/send ops aborted for this pass; next delay will \
                honor retry_after when present (B210/B244)%s\n%!"
               (match result.retry_after_s with
                | Some ra -> Printf.sprintf " retry_after=%.1fs" ra
                | None -> "")
       | Error (`Watchdog detail) ->
           incr watchdog_strikes;
           write_connector_state_error t.broker_root ~op:"sync_watchdog"
             ~detail;
           Printf.eprintf
             "[relay-connector] %s (strike %d/3)\n%!" detail !watchdog_strikes;
           if !watchdog_strikes >= 3 then begin
             Printf.eprintf
               "[relay-connector] wedged: %d consecutive sync watchdog \
                timeouts — exiting so a supervisor can restart (B181)\n%!"
               !watchdog_strikes;
             exit 3
           end
       | Error (`Exn exn) ->
           watchdog_strikes := 0;
           write_connector_state_error t.broker_root ~op:"sync"
             ~detail:(Printexc.to_string exn);
           Printf.eprintf "[relay-connector] sync exception: %s\n%!"
             (Printexc.to_string exn));
      (* B211/B228: an alive-but-erroring connector never advances last_progress;
         terminate once it has been wedged past the threshold. *)
      check_stale_exit ();
      if not !shutdown then begin
        let delay =
          rate_limit_backoff ~base:t.interval ~strikes:!rl_strikes
            ~retry_after:!last_retry_after ()
        in
        if !rl_strikes > 0 then
          Printf.eprintf
            "[relay-connector] relay rate-limited (429); backing off %.0fs \
             (strike %d%s)\n%!"
            delay !rl_strikes
            (if !last_retry_after > 0. then
               Printf.sprintf ", retry_after=%.1fs" !last_retry_after
             else "");
        sleep_interruptibly_until ~slice_s:5.0
          ~should_stop:(fun () ->
            check_stale_exit ();
            !shutdown)
          delay;
        loop ()
      end
    )
  in
  with_bounded_shutdown ~shutdown
    ~on_signal:(fun () ->
      if t.verbose then
        Printf.printf "[relay-connector] received signal, shutting down...\n%!")
    (fun () -> loop ());
  Printf.printf "[relay-connector] shutdown complete\n%!"

(* B200: one managed connector service discovers every repository broker on
   the machine. Each broker keeps its own registration cache, ingress policy,
   rate state, outbox, inboxes, alerts, and connector-state file; only the
   process/service and relay configuration are shared. Discovery is repeated
   every pass so a repository first used after service startup joins without
   another `c2c start relay-connect`. *)
let discover_machine_broker_roots ~primary =
  let roots = primary :: List.map snd (C2c_repo_fp.list_all_broker_roots ()) in
  List.fold_left
    (fun acc root ->
       let root = String.trim root in
       if root = "" || List.mem root acc then acc else root :: acc)
    [] roots
  |> List.rev

let make_state ~relay_url ~token ~identity ~broker_root ~node_id
    ~heartbeat_ttl ~interval ~verbose =
  { relay_url; token; identity; broker_root; node_id;
    heartbeat_ttl; interval; verbose;
    registered = []; active_ws_bindings = [];
    alert_state = C2c_relay_alert.initial_state }

let print_sync_result ?broker_root result =
  let prefix = match broker_root with
    | None -> "[relay-connector]"
    | Some root -> Printf.sprintf "[relay-connector %s]" root
  in
  let err_str = match result.last_error with
    | None -> ""
    | Some e ->
        Printf.sprintf " [%s: %s]" e.err_op
          (if String.length e.err_detail > 80 then
             String.sub e.err_detail 0 80 ^ "..."
           else e.err_detail)
  in
  let rl_tag =
    if result.rate_limited then
      match result.retry_after_s with
      | Some ra -> Printf.sprintf " RATE_LIMITED(retry_after=%.1fs)" ra
      | None -> " RATE_LIMITED"
    else ""
  in
  Printf.printf
    "%s sync: registered=%d heartbeated=%d fwd=%d failed=%d dlqed=%d inbound=%d rejected=%d alerts=%d%s%s\n%!"
    prefix (List.length result.registered) (List.length result.heartbeated)
    result.outbox_forwarded result.outbox_failed result.outbox_dlqed
    result.inbound_delivered result.inbound_rejected result.alerts_emitted
    err_str rl_tag;
  if result.rate_limited then
    Printf.eprintf
      "%s RATE_LIMITED (HTTP 429) this sync — remaining heartbeat/poll/send \
       ops aborted for this pass (B210/B244)%s\n%!"
      prefix
      (match result.retry_after_s with
       | Some ra -> Printf.sprintf " retry_after=%.1fs" ra
       | None -> "")

let start_machine_impl ~sync_once ~discover_roots
    ~relay_url ~token ~identity ~primary_broker_root ~node_id
    ~(heartbeat_ttl : float) ~(interval : float) ~(verbose : bool)
    ~(once : bool) : int =
  if not (is_ocaml_backend ()) then begin
    Printf.eprintf
      "[relay-connector] --all-brokers requires the OCaml connector backend\n%!";
    1
  end else begin
    let states = Hashtbl.create 8 in
    let strikes = Hashtbl.create 8 in
    let shutdown = ref false in
    (* B211: per-root wall-clock epoch of the last progress-making pass; seeded
       lazily to service start so a root that never succeeds still exits. *)
    let progress = Hashtbl.create 8 in
    let stale_threshold = stale_exit_threshold_s ~interval in
    (* Seed a root's progress window the first time it is synced (NOT at service
       start): a broker root discovered hours later must get a fresh staleness
       window, or an erroring first pass on a late-joining repo would trip the
       exit and kill the whole machine service. *)
    let last_progress_for root =
      match Hashtbl.find_opt progress root with
      | Some t -> t
      | None ->
          let now = Unix.gettimeofday () in
          Hashtbl.replace progress root now;
          now
    in
    let check_root_stale_exit root =
      if not !shutdown
         && should_exit_stale ~now:(Unix.gettimeofday ())
           ~last_progress:(last_progress_for root) ~threshold:stale_threshold
      then begin
        Printf.eprintf
          "[relay-connector %s] wedged: no successful sync for %.0fs (>= %.0fs \
           threshold) though the process is alive — exiting so a supervisor \
           can restart (B211/B228). Recover manually with: c2c restart \
           relay-connect\n%!"
          root (Unix.gettimeofday () -. last_progress_for root) stale_threshold;
        exit 3
      end
    in
    (* B228: also re-check every root we have ever synced (progress table), not
       only the roots discovered this pass — a root that drops out of discovery
       must still self-exit rather than leave a wedged state file forever. *)
    let check_all_known_roots_stale () =
      Hashtbl.iter (fun root _ -> check_root_stale_exit root) progress
    in
    let state_for root =
      match Hashtbl.find_opt states root with
      | Some t -> t
      | None ->
          let t = make_state ~relay_url ~token ~identity ~broker_root:root
              ~node_id ~heartbeat_ttl ~interval ~verbose in
          Hashtbl.add states root t;
          t
    in
    (* B210/B244: any root observing a 429 this pass drives the shared
       machine-loop backoff (the loop sleeps once per pass across all roots).
       Track the max retry_after observed so the shared delay honors it. *)
    let rl_seen = ref false in
    let rl_retry_after = ref 0. in
    let sync_root root =
      let t = state_for root in
      let outcome =
        match sync_once shutdown t with
        | Ok result ->
            Hashtbl.replace strikes root 0;
            if result.rate_limited then begin
              rl_seen := true;
              (match result.retry_after_s with
               | Some ra -> rl_retry_after := Float.max !rl_retry_after ra
               | None -> ())
            end;
            if sync_made_progress result then
              Hashtbl.replace progress root (Unix.gettimeofday ());
            write_connector_state ~node_id t.broker_root result;
            print_sync_result ~broker_root:root result;
            (match result.last_error with None -> true | Some _ -> false)
        | Error (`Watchdog detail) ->
            let n = 1 + Option.value ~default:0 (Hashtbl.find_opt strikes root) in
            Hashtbl.replace strikes root n;
            write_connector_state_error root ~op:"sync_watchdog" ~detail;
            Printf.eprintf "[relay-connector %s] %s (strike %d/3)\n%!" root detail n;
            if n >= 3 then exit 3;
            false
        | Error (`Exn exn) ->
            Hashtbl.replace strikes root 0;
            write_connector_state_error root ~op:"sync"
              ~detail:(Printexc.to_string exn);
            Printf.eprintf "[relay-connector %s] sync exception: %s\n%!"
              root (Printexc.to_string exn);
            false
      in
      (* B211/B228: terminate a persistently-wedged (alive-but-erroring) root. *)
      check_root_stale_exit root;
      outcome
    in
    let identity_tag = match identity with Some _ -> "Ed25519-signed" | None -> "token-only" in
    Printf.printf
      "[relay-connector] starting machine service — relay=%s node=%s auth=%s interval=%.0fs\n%!"
      relay_url node_id identity_tag interval;
    if once then begin
      let roots = discover_roots ~primary:primary_broker_root in
      if List.fold_left (fun ok root -> sync_root root && ok) true roots then 0 else 2
    end else begin
      (* B210: seed jitter per-process (see [run]). *)
      Random.self_init ();
      let rl_strikes = ref 0 in
      let rec loop () =
        if not !shutdown then begin
          rl_seen := false;
          rl_retry_after := 0.;
          discover_roots ~primary:primary_broker_root
          |> List.iter (fun root ->
               if not !shutdown then ignore (sync_root root));
          check_all_known_roots_stale ();
          if !rl_seen then incr rl_strikes
          else begin
            rl_strikes := 0;
            rl_retry_after := 0.
          end;
          if not !shutdown then begin
            let delay =
              rate_limit_backoff ~base:interval ~strikes:!rl_strikes
                ~retry_after:!rl_retry_after ()
            in
            if !rl_strikes > 0 then
              Printf.eprintf
                "[relay-connector] relay rate-limited (429); backing off %.0fs \
                 (strike %d%s)\n%!"
                delay !rl_strikes
                (if !rl_retry_after > 0. then
                   Printf.sprintf ", retry_after=%.1fs" !rl_retry_after
                 else "");
            sleep_interruptibly_until ~slice_s:5.0
              ~should_stop:(fun () ->
                check_all_known_roots_stale ();
                !shutdown)
              delay;
            loop ()
          end
        end
      in
      with_bounded_shutdown ~shutdown ~on_signal:(fun () -> ())
        (fun () -> loop ());
      Printf.printf "[relay-connector] shutdown complete\n%!";
      0
    end
  end

let start_machine ~relay_url ~token ~identity ~primary_broker_root ~node_id
    ~(heartbeat_ttl : float) ~(interval : float) ~(verbose : bool)
    ~(once : bool) : int =
  start_machine_impl ~sync_once:(fun shutdown t -> run_sync_once ~shutdown t)
    ~discover_roots:discover_machine_broker_roots
    ~relay_url ~token ~identity ~primary_broker_root ~node_id
    ~heartbeat_ttl ~interval ~verbose ~once

(* ---------------------------------------------------------------------------
 * Entry point (slice 1 stub)
 * --------------------------------------------------------------------------- *)

let start ~relay_url ~token ~identity ~broker_root ~node_id
    ~(heartbeat_ttl : float) ~(interval : float) ~(verbose : bool) ~(once : bool) : int =
  if not (is_ocaml_backend ()) then begin
    Printf.eprintf "[relay-connector] Python backend not enabled; \
      set C2C_RELAY_CONNECTOR_BACKEND=python to use Python implementation\n%!";
    1
  end else begin
    let identity_tag = match identity with
      | Some _ -> "Ed25519-signed"
      | None -> "token-only"
    in
    Printf.printf "[relay-connector] starting — relay=%s node=%s auth=%s interval=%.0fs\n%!"
      relay_url node_id identity_tag interval;
    let t = {
      relay_url; token; identity; broker_root; node_id;
      heartbeat_ttl; interval; verbose;
      registered = [];
      active_ws_bindings = [];
      alert_state = C2c_relay_alert.initial_state;
    } in
    if once then begin
      match Lwt_main.run (sync t) with
      | result ->
          write_connector_state ~node_id:t.node_id t.broker_root result;
          print_sync_result result;
          (* B087: never exit 0 when the sync pass recorded a relay-level
             failure (register/heartbeat/send/poll returned ok:false). The
             exception branch below already exits 1; this covers the
             "completed with errors" case that previously exited 0 and
             masked the failure from callers/scripts. *)
          (match result.last_error with
           | None -> 0
           | Some e ->
               Printf.eprintf "[relay-connector] sync completed with errors: %s\n%!" e.err_op;
               2)
      | exception exn ->
          write_connector_state_error t.broker_root ~op:"sync"
            ~detail:(Printexc.to_string exn);
          Printf.eprintf "[relay-connector] sync exception: %s\n%!" (Printexc.to_string exn);
          1
    end else begin
      run t;
      0
    end
  end
