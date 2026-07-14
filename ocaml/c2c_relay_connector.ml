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
  heartbeated : string list;
  outbox_forwarded : int;
  outbox_failed : int;
  outbox_dlqed : int;  (* entries moved to local DLQ this sync *)
  inbound_delivered : int;
  inbound_rejected : int;  (* H9: schema-invalid poll rows dropped this sync *)
  alerts_emitted : int;  (* B010: c2c-system alert messages injected this sync *)
  last_error : sync_error option;
}

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

let read_local_registrations broker_root =
  let reg_path = broker_root // "registry.json" in
  match C2c_io.read_json_opt reg_path with
  | None -> []
  | Some json ->
      let open Yojson.Safe.Util in
      match json with
      | `List regs ->
          List.fold_left (fun acc r ->
            match r with
            | `Assoc _ ->
                (match r |> member "session_id", r |> member "alias" with
                 | `String sid, `String alias ->
                     let ct = match r |> member "client_type" with `String s -> s | _ -> "unknown" in
                     (sid, alias, ct) :: acc
                 | _ -> acc)
            | _ -> acc
          ) [] regs
      | _ -> []

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
    ] @ node_id_assoc @ err_assoc) in
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
      Some {
        cs_last_sync_ts = last_sync_ts;
        cs_last_ok_ts = last_ok_ts;
        cs_last_error_op = get_str "last_error_op";
        cs_last_error_detail = get_str "last_error_detail";
        cs_last_error_ts = get_float "last_error_ts";
        cs_registered = registered;
        cs_node_id = get_str "node_id";
        cs_pid = get_int_opt "pid";
        cs_outbox_forwarded = get_int "outbox_forwarded";
        cs_outbox_failed = get_int "outbox_failed";
        cs_outbox_dlqed = get_int "outbox_dlqed";
        cs_inbound_delivered = get_int "inbound_delivered";
        cs_inbound_rejected = get_int "inbound_rejected";
      }

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

  (* H10 (Q1-DEFECT-1): reconcile the parsed body with the HTTP status
     line — port of the H7 contract from relay_client.ml. A non-2xx status
     can NEVER yield ok:true (pre-fix, an HTTP 500 with a dishonest
     {"ok":true} body made `relay connect --once` report success/exit 0).
     An honest ok:false object body passes through — its own error_code
     wins, which is what keeps the PoW/rate-limit helpers working: an
     honest 429 pow_required / rate_limit_exceeded body reaches
     Pow_client.is_pow_required and response_is_rate_limited unchanged
     apart from the appended http_status annotation. Anything else on a
     non-2xx is overridden with http_error_<code>, preserving the
     offending body under relay_response. 2xx bodies are untouched. *)
  let reconcile_status ~status body =
    if status >= 200 && status < 300 then body
    else
      match body with
      | `Assoc fields when List.assoc_opt "ok" fields = Some (`Bool false) ->
          let fields = List.filter (fun (k, _) -> k <> "http_status") fields in
          `Assoc (fields @ [ ("http_status", `Int status) ])
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
 * + edge-triggered dedup + routing) and inject the resulting messages from the
 * reserved [c2c-system] alias into local inboxes — the same files this module
 * already writes relay-pulled inbound messages to, so the alerts ride every
 * existing delivery surface for free.
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
let response_is_rate_limited json =
  let is_rl = function `String "rate_limit_exceeded" -> true | _ -> false in
  is_rl (member_or_null "error" json) || is_rl (member_or_null "error_code" json)

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

(* Deliver alert emissions into the relevant local inboxes.
   [regs] is the (session_id, alias, client_type) list for this broker.
   Returns the count of system messages written. *)
let deliver_alert_emissions broker_root regs (emissions : C2c_relay_alert.emission list) : int =
  List.fold_left (fun delivered (em : C2c_relay_alert.emission) ->
    let targets =
      match em.C2c_relay_alert.target with
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
  let regs = read_local_registrations t.broker_root in

  (* B010: accumulate relay-event observations across this sync pass. *)
  let obs_difficulty = ref None in
  let obs_rate_limited = ref false in
  let obs_pow_failed = ref false in
  let obs_pow_sender = ref None in
  let obs_dlqs = ref [] in
  let note_difficulty d =
    obs_difficulty :=
      Some (max d (Option.value ~default:0 !obs_difficulty))
  in
  let note_observation ~(sender : string option) json =
    (match response_difficulty json with Some d -> note_difficulty d | None -> ());
    if response_is_rate_limited json then obs_rate_limited := true;
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
  let registered, heartbeated, new_registered, reg_errors =
    List.fold_left (fun (registered, heartbeated, reg_list, errs) (session_id, alias, client_type) ->
      if List.mem session_id t.registered then
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
        let json = Lwt_main.run (Relay_client.send client
          ~from_alias:entry.ob_from
          ~to_alias:entry.ob_to
          ~content:entry.ob_content
          ?message_id:entry.ob_msg_id ()) in
        note_observation ~sender:(Some entry.ob_from) json;
        if json_bool_member ~key:"ok" json then
          (fwd + 1, failed, remaining, dlqed, errs)
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
      ) (0, 0, [], 0, []) outbox
    )
  in
  write_outbox t.broker_root (List.rev remaining_outbox);

  (* 3. Poll inbound for registered sessions. H9: validate each row against
     the minimum broker-inbox contract BEFORE it touches the local inbox
     file; drop-and-log invalid rows (see [inbound_row_is_deliverable]) so a
     misbehaving relay can neither inflate [inbound_delivered] nor poison
     the local inbox. Partial-batch delivery: valid rows in a batch with
     invalid siblings still deliver. *)
  let inbound_delivered, inbound_rejected, poll_errors =
    List.fold_left (fun (delivered, rejected, errs) (session_id, alias, _) ->
      if List.mem session_id t.registered then
        let json = Lwt_main.run (Relay_client.poll_inbox client ~node_id:t.node_id ~session_id ~alias ()) in
        note_observation ~sender:None json;
        let msgs = json_list_member ~key:"messages" json in
        if msgs <> [] then begin
          let deliverable, bad = List.partition inbound_row_is_deliverable msgs in
          let errs =
            if bad = [] then errs
            else
              let sample = Yojson.Safe.to_string (`List bad) in
              let sample =
                if String.length sample > 512 then String.sub sample 0 512 ^ "..."
                else sample
              in
              let detail = Printf.sprintf
                "dropped %d schema-invalid inbound row(s) of %d for %s: %s"
                (List.length bad) (List.length msgs) alias sample
              in
              ("poll_inbox", detail) :: errs
          in
          let delivered =
            if deliverable = [] then delivered
            else delivered + append_to_local_inbox t.broker_root session_id deliverable
          in
          delivered, rejected + List.length bad, errs
        end
        else if json_bool_member ~key:"ok" json then
          delivered, rejected, errs
        else
          let detail = Yojson.Safe.to_string json in
          delivered, rejected, ("poll_inbox", detail) :: errs
      else
        delivered, rejected, errs
    ) (0, 0, []) regs
  in

  let last_error = match reg_errors @ send_errors @ poll_errors with
    | [] -> None
    | (op, detail) :: _ ->
        Some { err_op = op; err_detail = detail; err_ts = Unix.gettimeofday () }
  in

  (* B010: turn this sync's observations into severity-tagged emissions
     (edge-triggered against t.alert_state) and inject them as c2c-system
     messages into the appropriate local inboxes. Pure decision, side-effecting
     delivery — same inbox-write path used for relay-pulled messages. *)
  let observation = {
    C2c_relay_alert.obs_difficulty = !obs_difficulty;
    obs_rate_limited = !obs_rate_limited;
    obs_pow_retry_failed = !obs_pow_failed;
    obs_pow_retry_sender = !obs_pow_sender;
    obs_dlqs = List.rev !obs_dlqs;
  } in
  let emissions, new_alert_state = C2c_relay_alert.step t.alert_state observation in
  t.alert_state <- new_alert_state;
  let alerts_emitted = deliver_alert_emissions t.broker_root regs emissions in

  Lwt.return {
    registered;
    heartbeated;
    outbox_forwarded;
    outbox_failed;
    outbox_dlqed = dlqed;
    alerts_emitted;
    inbound_delivered;
    inbound_rejected;
    last_error;
  }

(* ---------------------------------------------------------------------------
 * Run loop with graceful signal handling
 * --------------------------------------------------------------------------- *)

(* B181: wall-clock cap for one sync pass so a hung HTTP path cannot leave
   a multi-hour PID with stale last_sync. Defaults to max(90s, 4 * interval).
   Implemented with SIGALRM because [sync] drives work via nested
   Lwt_main.run (a Lwt.pick sibling never races those calls). On timeout we
   write an error state and count consecutive strikes; after 3 the process
   exits 3 so managed `c2c start relay-connect` / supervisors can restart. *)
let sync_watchdog_s (t : t) =
  max 90.0 (t.interval *. 4.0)

exception Sync_watchdog of string

let run_sync_once (t : t) :
    (sync_result, [ `Exn of exn | `Watchdog of string ]) result =
  let deadline = sync_watchdog_s t in
  let deadline_i =
    int_of_float (Float.ceil deadline) |> max 1
  in
  let prev_alrm = Sys.signal Sys.sigalrm Sys.Signal_ignore in
  let finally () =
    ignore (Unix.alarm 0);
    Sys.set_signal Sys.sigalrm prev_alrm
  in
  Fun.protect ~finally (fun () ->
      Sys.set_signal Sys.sigalrm
        (Sys.Signal_handle
           (fun _ ->
              raise
                (Sync_watchdog
                   (Printf.sprintf
                      "sync wall-clock exceeded %ds (B181 watchdog)" deadline_i))));
      ignore (Unix.alarm deadline_i);
      try Ok (Lwt_main.run (sync t)) with
      | Sync_watchdog detail -> Error (`Watchdog detail)
      | exn -> Error (`Exn exn))

let run (t : t) : unit =
  let shutdown = ref false in
  let watchdog_strikes = ref 0 in
  let install_signal sig_name =
    Sys.signal sig_name (Sys.Signal_handle (fun _ ->
      if not !shutdown then begin
        shutdown := true;
        if t.verbose then
          Printf.printf "[relay-connector] received signal, shutting down...\n%!"
      end))
  in
  let _ = install_signal Sys.sigterm in
  let _ = install_signal Sys.sigint in
  let rec loop () =
    if !shutdown then (
      Printf.printf "[relay-connector] shutdown complete\n%!";
    ) else (
      (match run_sync_once t with
       | Ok result ->
           watchdog_strikes := 0;
           write_connector_state ~node_id:t.node_id t.broker_root result;
           let err_str = match result.last_error with
             | None -> ""
             | Some e ->
                 Printf.sprintf " [%s: %s]" e.err_op
                   (if String.length e.err_detail > 80 then
                     String.sub e.err_detail 0 80 ^ "..."
                   else e.err_detail)
           in
           Printf.printf "[relay-connector] sync: registered=%d heartbeated=%d fwd=%d failed=%d dlqed=%d inbound=%d rejected=%d alerts=%d%s\n%!"
             (List.length result.registered)
             (List.length result.heartbeated)
             result.outbox_forwarded
             result.outbox_failed
             result.outbox_dlqed
             result.inbound_delivered
             result.inbound_rejected
             result.alerts_emitted
             err_str
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
      if not !shutdown then begin
        Unix.sleepf t.interval;
        loop ()
      end
    )
  in
  loop ()

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
          let err_str = match result.last_error with
            | None -> ""
            | Some e -> Printf.sprintf " [%s: %s]" e.err_op e.err_detail
          in
          Printf.printf "[relay-connector] sync: registered=%d heartbeated=%d fwd=%d failed=%d dlqed=%d inbound=%d rejected=%d alerts=%d%s\n%!"
            (List.length result.registered)
            (List.length result.heartbeated)
            result.outbox_forwarded
            result.outbox_failed
            result.outbox_dlqed
            result.inbound_delivered
            result.inbound_rejected
            result.alerts_emitted
            err_str;
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
