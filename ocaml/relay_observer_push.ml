open Relay_observer_sessions

let observer_sessions = ObserverSessions.create ()

(* S6: Push messages to all active observer sessions for a binding *)
let push_to_observers ~binding_id (msg : Relay_short_queue.message) =
  let sessions = ObserverSessions.get observer_sessions ~binding_id in
  let base_fields = [
    "type", `String "message";
    "ts", `Float msg.ts;
    "from_alias", `String msg.from_alias;
    "to_alias", `String msg.to_alias;
  ] in
  let room_field = match msg.room_id with Some r -> ["room_id", `String r] | None -> [] in
  let all_fields = base_fields @ room_field @ ["content", `String msg.content] in
  let json = `Assoc all_fields in
  let payload = Yojson.Safe.to_string json in
  List.iter (fun session ->
    Lwt.async (fun () -> Relay_ws_frame.Session.send_text session payload)
  ) sessions

(* S5c: Push pseudo_registration to all active observer sessions for a binding.
   This tells the bound broker to add the phone as a reachable peer. *)
let push_pseudo_registration_to_observers ~binding_id ~phone_ed_pk ~phone_x_pk ~machine_ed_pk ~provenance_sig ~bound_at =
  let sessions = ObserverSessions.get observer_sessions ~binding_id in
  let json = `Assoc [
    "type", `String "pseudo_registration";
    "alias", `String binding_id;
    "ed25519_pubkey", `String phone_ed_pk;
    "x25519_pubkey", `String phone_x_pk;
    "machine_ed25519_pubkey", `String machine_ed_pk;
    "binding_id", `String binding_id;
    "bound_at", `Float bound_at;
    "provenance_sig", `String provenance_sig;
  ] in
  let payload = Yojson.Safe.to_string json in
  List.iter (fun session ->
    Lwt.async (fun () -> Relay_ws_frame.Session.send_text session payload)
  ) sessions

(* S5c: Push pseudo_unregistration to all active observer sessions for a binding.
   This tells the bound broker to remove the phone's pseudo-registration. *)
let push_pseudo_unregistration_to_observers ~binding_id =
  let sessions = ObserverSessions.get observer_sessions ~binding_id in
  let json = `Assoc [
    "type", `String "pseudo_unregistration";
    "binding_id", `String binding_id;
  ] in
  let payload = Yojson.Safe.to_string json in
  List.iter (fun session ->
    Lwt.async (fun () -> Relay_ws_frame.Session.send_text session payload)
  ) sessions
