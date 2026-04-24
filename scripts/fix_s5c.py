#!/usr/bin/env python3
"""Fix S5c Phase B implementation - fixes duplicate, blocking, reconnection issues."""

with open('ocaml/c2c_relay_connector.ml', 'r') as f:
    content = f.read()

print(f"File size: {len(content)}")

# Step 1: Add active_ws_bindings to t type
old_t = """type t = {
  relay_url : string;
  token : string option;
  identity : Relay_identity.t option;
  broker_root : string;
  node_id : string;
  heartbeat_ttl : float;
  interval : float;
  verbose : bool;
  mutable registered : string list;
}"""

new_t = """type t = {
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
}"""

if old_t in content:
    content = content.replace(old_t, new_t)
    print("Step 1 (t type): OK")
else:
    print("Step 1 (t type): FAILED")

# Step 2: Add active_ws_bindings = [] to start
old_start = """      registered = [];
    } in
    if once then begin
      match Lwt_main.run (sync t)"""

new_start = """      registered = [];
      active_ws_bindings = [];
    } in
    if once then begin
      match Lwt_main.run (sync t)"""

if old_start in content:
    content = content.replace(old_start, new_start)
    print("Step 2 (start init): OK")
else:
    print("Step 2 (start init): FAILED")

# Step 3: Add maintain_ws_connections call to sync (before step 1)
# Insert maintain_ws_connections call right after outbox read
old_sync_start = """  let outbox = read_outbox t.broker_root in

  (* 1. Register / heartbeat"""

new_sync_start = """  let outbox = read_outbox t.broker_root in

  (* 0. Maintain WS connections to mobile bindings (non-blocking) *)
  maintain_ws_connections t;

  (* 1. Register / heartbeat"""

if old_sync_start in content:
    content = content.replace(old_sync_start, new_sync_start)
    print("Step 3 (sync wiring): OK")
else:
    print("Step 3 (sync wiring): FAILED")

# Step 4: Add S5c functions (only once, before sync)
s5c_functions = '''
(* ---------------------------------------------------------------------------
 * S5c Phase B: Broker WS client — connects to relay as outbound observer
 * --------------------------------------------------------------------------- *)

let parse_relay_url url =
  let without_scheme s =
    if String.length s >= 8 && String.sub s 0 8 = "https://" then
      String.sub s 8 (String.length s - 8)
    else if String.length s >= 7 && String.sub s 0 7 = "http://" then
      String.sub s 7 (String.length s - 7)
    else s
  in
  let stripped = without_scheme url in
  match String.split_on_char ':' stripped with
  | host :: port_str :: _ ->
      let port = int_of_string port_str in
      (host, port)
  | [host] ->
      let default_port = if String.length url >= 8 && String.sub url 0 8 = "https://" then 443 else 80 in
      (host, default_port)
  | _ -> (stripped, 80)

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
    Printf.printf "[broker-ws] pseudo_registration: alias=%s binding_id=%s\\n%!" alias binding_id;
    upsert_pseudo_registration broker_root ~binding_id ~alias ~ed25519_pubkey ~x25519_pubkey
      ~machine_ed25519_pubkey ~provenance_sig ~bound_at;
    Printf.printf "[broker-ws]   stored in pseudo_registrations.json\\n%!"
  with e ->
    Printf.eprintf "[broker-ws] error handling pseudo_registration: %s\\n%!" (Printexc.to_string e)

let handle_pseudo_unregistration broker_root json =
  let open Yojson.Safe.Util in
  try
    let binding_id = json |> member "binding_id" |> to_string in
    Printf.printf "[broker-ws] pseudo_unregistration: binding_id=%s\\n%!" binding_id;
    remove_pseudo_registration broker_root ~binding_id;
    Printf.printf "[broker-ws]   removed from pseudo_registrations.json\\n%!"
  with e ->
    Printf.eprintf "[broker-ws] error handling pseudo_unregistration: %s\\n%!" (Printexc.to_string e)

let ws_client_loop (session : Relay_ws_frame.Client_session.t) broker_root binding_id t =
  let rec loop () =
    Lwt.catch (fun () ->
      session |> Relay_ws_frame.Client_session.recv >>= function
      | None ->
          Printf.printf "[broker-ws] connection closed\\n%!";
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
            | _ -> Printf.printf "[broker-ws] unknown frame type: %s\\n%!" msg_type
          with e ->
            Printf.eprintf "[broker-ws] error parsing frame: %s\\n%!" (Printexc.to_string e));
          loop ()
      | Some (`Binary raw) ->
          Printf.printf "[broker-ws] unexpected binary frame\\n%!";
          loop ()
      | Some (`Close (code, reason)) ->
          Printf.printf "[broker-ws] server closed: code=%d reason=%s\\n%!" code reason;
          Lwt.return ()
    ) (fun exn ->
      Printf.eprintf "[broker-ws] connection error: %s\\n%!" (Printexc.to_string exn);
      Lwt.return ()
    )
  in
  Lwt.async (fun () ->
    loop () >>= fun () ->
    (* On loop exit, mark binding as disconnected so maintain_ws_connections will retry *)
    t.active_ws_bindings <- List.filter (fun id -> id <> binding_id) t.active_ws_bindings;
    Printf.printf "[broker-ws] connection ended for binding %s\\n%!" binding_id;
    Lwt.return ()
  )

let broker_ws_connect ~relay_url ~binding_id ~broker_root ~(verbose : bool) ~(t : t) =
  let host, port = parse_relay_url relay_url in
  let path = "/observer/" ^ binding_id in
  if verbose then Printf.printf "[broker-ws] connecting to %s:%d%s\\n%!" host port path;
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
      Printf.eprintf "[broker-ws] handshake failed: %s\\n%!" (String.sub response 0 (min n 200));
      Lwt.return ()
    ) else (
      if verbose then Printf.printf "[broker-ws] handshake succeeded\\n%!";
      let session = Relay_ws_frame.Client_session.create ic oc masking_key in
      ws_client_loop session broker_root binding_id t
    )
  ) (fun exn ->
    Printf.eprintf "[broker-ws] connection failed: %s\\n%!" (Printexc.to_string exn);
    t.active_ws_bindings <- List.filter (fun id -> id <> binding_id) t.active_ws_bindings;
    Lwt.return ()
  )

let maintain_ws_connections (t : t) : unit =
  let bindings = read_mobile_bindings t.broker_root in
  let binding_ids = List.map (fun mb -> mb.mb_binding_id) bindings in
  let new_bindings = List.filter (fun id -> not (List.mem id t.active_ws_bindings)) binding_ids in
  List.iter (fun binding_id ->
    if t.verbose then Printf.printf "[broker-ws] maintaining connection to binding %s\\n%!" binding_id;
    t.active_ws_bindings <- binding_id :: t.active_ws_bindings;
    broker_ws_connect ~relay_url:t.relay_url ~binding_id ~broker_root:t.broker_root ~verbose:t.verbose ~t
  ) new_bindings

'''

# Check if already patched
if "let maintain_ws_connections" in content:
    print("Step 4 (S5c functions): Already present - skipping")
else:
    # Insert before sync function
    marker = "let sync (t : t) : sync_result Lwt.t ="
    if marker in content:
        content = content.replace(marker, s5c_functions + marker)
        print("Step 4 (S5c functions): OK")
    else:
        print("Step 4 (S5c functions): FAILED - could not find sync marker")

with open('ocaml/c2c_relay_connector.ml', 'w') as f:
    f.write(content)

print(f"Final file size: {len(content)}")