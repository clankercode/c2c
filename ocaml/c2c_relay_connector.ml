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

type sync_result = {
  registered : string list;
  heartbeated : string list;
  outbox_forwarded : int;
  outbox_failed : int;
  inbound_delivered : int;
}

type t = {
  relay_url : string;
  token : string option;
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
 * --------------------------------------------------------------------------- *)

module Relay_client = struct

  type t = {
    base_url : string;
    token : string option;
    timeout : float;
  }

  let make ?token ?(timeout = 10.0) base_url =
    let base_url = match String.length base_url with
      | 0 -> base_url
      | n when base_url.[n-1] = '/' -> String.sub base_url 0 (n-1)
      | _ -> base_url
    in
    { base_url; token; timeout }

  let connection_error msg =
    `Assoc [
      ("ok", `Bool false);
      ("error_code", `String "connection_error");
      ("error", `String msg);
    ]

  let request t ~meth ~path ?body () =
    let uri = Uri.of_string (t.base_url ^ path) in
    let headers =
      let base = Cohttp.Header.init_with "Content-Type" "application/json" in
      match t.token with
      | Some tok -> Cohttp.Header.add base "Authorization" ("Bearer " ^ tok)
      | None -> base
    in
    let body_str = Yojson.Safe.to_string (Option.value body ~default:(`Assoc [])) in
    let body_payload = Cohttp_lwt.Body.of_string body_str in
    Lwt.catch
      (fun () ->
        Cohttp_lwt_unix.Client.call ~headers ~body:body_payload meth uri
        >>= fun (_resp, resp_body) ->
        Cohttp_lwt.Body.to_string resp_body >>= fun text ->
        try Lwt.return (Yojson.Safe.from_string text)
        with _ -> Lwt.return (connection_error "invalid_json_response"))
      (fun exn -> Lwt.return (connection_error (Printexc.to_string exn)))

  let post t path body = request t ~meth:`POST ~path ~body ()
  let get t path = request t ~meth:`GET ~path ()

  let health t = get t "/health"

  let register t ~node_id ~session_id ~alias ?(client_type = "unknown") ?(ttl = 300.0) () =
    post t "/register" (`Assoc [
      ("node_id", `String node_id);
      ("session_id", `String session_id);
      ("alias", `String alias);
      ("client_type", `String client_type);
      ("ttl", `Int (int_of_float ttl));
    ])

  let heartbeat t ~node_id ~session_id =
    post t "/heartbeat" (`Assoc [
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
    post t "/send" (`Assoc body)

  let poll_inbox t ~node_id ~session_id =
    post t "/poll_inbox" (`Assoc [
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
  let client = Relay_client.make ?token:t.token t.relay_url in
  let regs = read_local_registrations t.broker_root in
  let outbox = read_outbox t.broker_root in

  (* 1. Register / heartbeat each local session *)
  let registered, heartbeated, new_registered =
    List.fold_left (fun (registered, heartbeated, reg_list) (session_id, alias, client_type) ->
      if List.mem session_id t.registered then
        let json = Lwt_main.run (Relay_client.heartbeat client ~node_id:t.node_id ~session_id) in
        if json_bool_member ~key:"ok" json then
          (registered, alias :: heartbeated, reg_list)
        else
          (registered, heartbeated, reg_list)
      else
        let json = Lwt_main.run (Relay_client.register client
          ~node_id:t.node_id ~session_id ~alias ~client_type ~ttl:t.heartbeat_ttl ()) in
        if json_bool_member ~key:"ok" json then
          (alias :: registered, heartbeated, session_id :: reg_list)
        else
          (registered, heartbeated, reg_list)
    ) ([], [], t.registered) regs
  in
  t.registered <- new_registered;

  (* 2. Forward outbox entries *)
  let outbox_forwarded, outbox_failed, remaining_outbox =
    List.fold_left (fun (fwd, failed, remaining) entry ->
      let json = Lwt_main.run (Relay_client.send client
        ~from_alias:entry.ob_from
        ~to_alias:entry.ob_to
        ~content:entry.ob_content
        ?message_id:entry.ob_msg_id ()) in
      if json_bool_member ~key:"ok" json then
        (fwd + 1, failed, remaining)
      else
        (fwd, failed + 1, entry :: remaining)
    ) (0, 0, []) outbox
  in
  write_outbox t.broker_root (List.rev remaining_outbox);

  (* 3. Poll inbound for registered sessions *)
  let inbound_delivered =
    List.fold_left (fun delivered (session_id, _alias, _) ->
      if List.mem session_id t.registered then
        let json = Lwt_main.run (Relay_client.poll_inbox client ~node_id:t.node_id ~session_id) in
        let msgs = json_list_member ~key:"messages" json in
        if msgs <> [] then
          delivered + append_to_local_inbox t.broker_root session_id msgs
        else
          delivered
      else
        delivered
    ) 0 regs
  in

  Lwt.return {
    registered;
    heartbeated;
    outbox_forwarded;
    outbox_failed;
    inbound_delivered;
  }

(* ---------------------------------------------------------------------------
 * Run loop (slice 2+)
 * --------------------------------------------------------------------------- *)

let run (t : t) : unit =
  let rec loop () =
    if t.verbose then
      Printf.printf "[relay-connector] syncing...\n%!";
    (try
      ignore (Lwt_main.run (sync t))
     with exn ->
       if t.verbose then
         Printf.eprintf "[relay-connector] sync error: %s\n%!" (Printexc.to_string exn));
    if t.verbose then
      Printf.printf "[relay-connector] sleep %.0fs\n%!" t.interval;
    Unix.sleepf t.interval;
    loop ()
  in
  loop ()

(* ---------------------------------------------------------------------------
 * Entry point (slice 1 stub)
 * --------------------------------------------------------------------------- *)

let start ~relay_url ~token ~broker_root ~node_id
    ~(heartbeat_ttl : float) ~(interval : float) ~(verbose : bool) ~(once : bool) : int =
  if not (is_ocaml_backend ()) then begin
    Printf.eprintf "[relay-connector] Python backend not enabled; \
      set C2C_RELAY_CONNECTOR_BACKEND=python to use Python implementation\n%!";
    1
  end else begin
    let t = {
      relay_url; token; broker_root; node_id;
      heartbeat_ttl; interval; verbose;
      registered = [];
    } in
    if once then begin
      match Lwt_main.run (sync t) with
      | result ->
          if verbose then begin
            Printf.printf "[relay-connector] sync result: registered=%d heartbeated=%d outbox_forwarded=%d outbox_failed=%d inbound_delivered=%d\n%!"
              (List.length result.registered)
              (List.length result.heartbeated)
              result.outbox_forwarded
              result.outbox_failed
              result.inbound_delivered
          end;
          0
      | exception exn ->
          if verbose then
            Printf.eprintf "[relay-connector] sync error: %s\n%!" (Printexc.to_string exn);
          1
    end else begin
      run t;
      0
    end
  end
