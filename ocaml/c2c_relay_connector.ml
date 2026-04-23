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
  inbound_delivered : int;
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
}

(* ---------------------------------------------------------------------------
 * Local broker helpers
 * --------------------------------------------------------------------------- *)

let local_inbox_path broker_root session_id =
  broker_root // (session_id ^ ".inbox.json")

let read_local_registrations broker_root =
  let reg_path = broker_root // "registry.json" in
  if not (Sys.file_exists reg_path) then []
  else
    try
      let json = Yojson.Safe.from_file reg_path in
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
    with _ -> []

let append_to_local_inbox broker_root session_id messages =
  if messages = [] then 0
  else
    let path = local_inbox_path broker_root session_id in
    let existing_json =
      try Yojson.Safe.from_file path
      with _ -> `List [] in
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
  if not (Sys.file_exists path) then []
  else
    try
      let json = Yojson.Safe.from_file path in
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
    with _ -> []

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
  if not (Sys.file_exists path) then []
  else
    try
      let json = Yojson.Safe.from_file path in
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
    with _ -> []

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
 * Outbox (remote-outbox.jsonl)
 * --------------------------------------------------------------------------- *)

let outbox_path broker_root = broker_root // "remote-outbox.jsonl"

type outbox_entry = {
  ob_from : string;
  ob_to : string;
  ob_content : string;
  ob_msg_id : string option;
}

let read_outbox broker_root =
  let path = outbox_path broker_root in
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
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
              loop ({ ob_from = from; ob_to = to_; ob_content = content; ob_msg_id = msg_id } :: acc)
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
          let json = `Assoc (
            ["from_alias", `String e.ob_from;
             "to_alias", `String e.ob_to;
             "content", `String e.ob_content]
            @ msg_id_assoc
          ) in
          output_string oc (Yojson.Safe.to_string json ^ "\n")
        ) entries)

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
    let body_str = Yojson.Safe.to_string (Option.value body ~default:(`Assoc [])) in
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
        >>= fun (_resp, resp_body) ->
        Cohttp_lwt.Body.to_string resp_body >>= fun text ->
        try Lwt.return (Yojson.Safe.from_string text)
        with _ -> Lwt.return (connection_error "invalid_json_response"))
      (fun exn -> Lwt.return (connection_error (Printexc.to_string exn)))

  let post t path ?alias body = request t ~meth:`POST ~path ?alias ~body ()
  let get t path = request t ~meth:`GET ~path ()

  let health t = get t "/health"

  let register t ~node_id ~session_id ~alias ?(client_type = "unknown") ?(ttl = 300.0) ?(enc_pubkey = "") ?(signed_at = 0.0) ?(sig_b64 = "") () =
    let body = `Assoc [
      ("node_id", `String node_id);
      ("session_id", `String session_id);
      ("alias", `String alias);
      ("client_type", `String client_type);
      ("ttl", `Int (int_of_float ttl));
    ] in
    let body =
      match t.identity with
      | None -> body
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
          )
    in
    let body =
      if enc_pubkey <> "" then
        let open Yojson.Safe.Util in
        let base_list = to_assoc body in
        `Assoc (base_list @ [("enc_pubkey", `String enc_pubkey); ("signed_at", `Float signed_at); ("sig_b64", `String sig_b64)])
      else body
    in
    post t "/register" ~alias body

  let heartbeat t ~node_id ~session_id ?(alias : string option) () =
    post t "/heartbeat" ?alias (`Assoc [
      ("node_id", `String node_id);
      ("session_id", `String session_id);
    ])

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

let json_bool_member ~key json =
  match Yojson.Safe.Util.member key json with
  | `Bool b -> b
  | _ -> false

let json_list_member ~key json =
  match Yojson.Safe.Util.member key json with
  | `List lst -> lst
  | _ -> []

let sync (t : t) : sync_result Lwt.t =
  let client = Relay_client.make ?token:t.token ?identity:t.identity t.relay_url in
  let regs = read_local_registrations t.broker_root in
  let outbox = read_outbox t.broker_root in

  (* 1. Register / heartbeat each local session *)
  let registered, heartbeated, new_registered, reg_errors =
    List.fold_left (fun (registered, heartbeated, reg_list, errs) (session_id, alias, client_type) ->
      if List.mem session_id t.registered then
        let json = Lwt_main.run (Relay_client.heartbeat client ~node_id:t.node_id ~session_id ~alias ()) in
        if json_bool_member ~key:"ok" json then
          (registered, alias :: heartbeated, reg_list, errs)
        else
          let detail = Yojson.Safe.to_string json in
          (registered, heartbeated, reg_list, ("heartbeat", detail) :: errs)
      else
        let json = Lwt_main.run (Relay_client.register client
          ~node_id:t.node_id ~session_id ~alias ~client_type ~ttl:t.heartbeat_ttl ()) in
        if json_bool_member ~key:"ok" json then
          (alias :: registered, heartbeated, session_id :: reg_list, errs)
        else
          let detail = Yojson.Safe.to_string json in
          (registered, heartbeated, reg_list, ("register", detail) :: errs)
    ) ([], [], t.registered, []) regs
  in
  t.registered <- new_registered;

  (* 2. Forward outbox entries *)
  let outbox_forwarded, outbox_failed, remaining_outbox, send_errors =
    List.fold_left (fun (fwd, failed, remaining, errs) entry ->
      let json = Lwt_main.run (Relay_client.send client
        ~from_alias:entry.ob_from
        ~to_alias:entry.ob_to
        ~content:entry.ob_content
        ?message_id:entry.ob_msg_id ()) in
      if json_bool_member ~key:"ok" json then
        (fwd + 1, failed, remaining, errs)
      else
        let detail = Yojson.Safe.to_string json in
        (fwd, failed + 1, entry :: remaining, ("send", detail) :: errs)
    ) (0, 0, [], []) outbox
  in
  write_outbox t.broker_root (List.rev remaining_outbox);

  (* 3. Poll inbound for registered sessions *)
  let inbound_delivered, poll_errors =
    List.fold_left (fun (delivered, errs) (session_id, alias, _) ->
      if List.mem session_id t.registered then
        let json = Lwt_main.run (Relay_client.poll_inbox client ~node_id:t.node_id ~session_id ~alias ()) in
        let msgs = json_list_member ~key:"messages" json in
        if msgs <> [] then
          delivered + append_to_local_inbox t.broker_root session_id msgs, errs
        else if json_bool_member ~key:"ok" json then
          delivered, errs
        else
          let detail = Yojson.Safe.to_string json in
          delivered, ("poll_inbox", detail) :: errs
      else
        delivered, errs
    ) (0, []) regs
  in

  let last_error = match reg_errors @ send_errors @ poll_errors with
    | [] -> None
    | (op, detail) :: _ ->
        Some { err_op = op; err_detail = detail; err_ts = Unix.gettimeofday () }
  in

  Lwt.return {
    registered;
    heartbeated;
    outbox_forwarded;
    outbox_failed;
    inbound_delivered;
    last_error;
  }

(* ---------------------------------------------------------------------------
 * Run loop with graceful signal handling
 * --------------------------------------------------------------------------- *)

let run (t : t) : unit =
  let shutdown = ref false in
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
      (try
        let result = Lwt_main.run (sync t) in
        let err_str = match result.last_error with
          | None -> ""
          | Some e ->
              Printf.sprintf " [%s: %s]" e.err_op
                (if String.length e.err_detail > 80 then
                  String.sub e.err_detail 0 80 ^ "..."
                else e.err_detail)
        in
        Printf.printf "[relay-connector] sync: registered=%d heartbeated=%d fwd=%d failed=%d inbound=%d%s\n%!"
          (List.length result.registered)
          (List.length result.heartbeated)
          result.outbox_forwarded
          result.outbox_failed
          result.inbound_delivered
          err_str
      with exn ->
        Printf.eprintf "[relay-connector] sync exception: %s\n%!" (Printexc.to_string exn));
      if not !shutdown then begin
        Unix.sleepf t.interval;
        loop ()
      end
    )
  in
  loop ()

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

let rec ws_client_loop (session : Relay_ws_frame.Client_session.t) broker_root binding_id =
  Lwt.catch (fun () ->
    session |> Relay_ws_frame.Client_session.recv >>= function
    | None ->
        Printf.printf "[broker-ws] connection closed\n%!";
        Lwt.return ()
    | Some (`Ping) ->
        ws_client_loop session broker_root binding_id
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
        ws_client_loop session broker_root binding_id
    | Some (`Binary raw) ->
        Printf.printf "[broker-ws] unexpected binary frame\n%!";
        ws_client_loop session broker_root binding_id
    | Some (`Close (code, reason)) ->
        Printf.printf "[broker-ws] server closed: code=%d reason=%s\n%!" code reason;
        Lwt.return ()
  ) (fun exn ->
    Printf.eprintf "[broker-ws] connection error: %s\n%!" (Printexc.to_string exn);
    Lwt.return ()
  )

let broker_ws_connect ~relay_url ~binding_id ~broker_root ~verbose =
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
      ws_client_loop session broker_root binding_id
    )
  ) (fun exn ->
    Printf.eprintf "[broker-ws] connection failed: %s\n%!" (Printexc.to_string exn);
    Lwt.return ()
  )

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
    } in
    if once then begin
      match Lwt_main.run (sync t) with
      | result ->
          let err_str = match result.last_error with
            | None -> ""
            | Some e -> Printf.sprintf " [%s: %s]" e.err_op e.err_detail
          in
          Printf.printf "[relay-connector] sync: registered=%d heartbeated=%d fwd=%d failed=%d inbound=%d%s\n%!"
            (List.length result.registered)
            (List.length result.heartbeated)
            result.outbox_forwarded
            result.outbox_failed
            result.inbound_delivered
            err_str;
          0
      | exception exn ->
          Printf.eprintf "[relay-connector] sync exception: %s\n%!" (Printexc.to_string exn);
          1
    end else begin
      run t;
      0
    end
  end
