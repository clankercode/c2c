(* relay_ws_server.ml — WebSocket push endpoint for c2c relay.
   Slice 2 of push-delivery design (2026-06-17).
   
   Subscribers connect via GET /ws/subscribe with Ed25519 auth headers:
   - X-C2C-Alias: <alias>
   - X-C2C-Timestamp: <unix_seconds>
   - X-C2C-Signature: <base64url of ed25519 sig over (alias || ts)>
   
   On successful auth, the connection upgrades to WebSocket. The server pushes
   DM frames: {"op":"dm", "from":"...", "body":"...", "ts":...}
   
   Phase 2: clients can dynamically add/remove aliases on an existing connection
   by sending subscribe/unsubscribe frames with per-alias Ed25519 signatures.
   This allows a single WS connection to serve multiple aliases without
   re-establishing the connection or reinitializing other subscriptions.
   
   Server pings every 30s; expects pong within 10s or drops connection. *)

open Lwt.Infix

module StringSet = Set.Make(String)

(* Timestamp validation window: ±60s *)
let auth_ts_window = 60.0

(* Ping interval and pong timeout *)
let ping_interval_s = 30.0
let pong_timeout_s = 10.0

(* Close codes per RFC 6455 + custom *)
let close_normal = 1000
let close_going_away = 1001
let close_auth_failed = 4001
let close_pong_timeout = 4002

(* Base64url-nopad decode *)
let b64url_decode s =
  Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s

(* Base64url-nopad encode *)
let b64url_encode s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

(* A subscriber connection — supports multiple aliases (Phase 2) *)
type subscriber = {
  mutable aliases : StringSet.t;
  session : Relay_ws_frame.Session.t;
  mutable last_pong : float;
  mutable closed : bool;
}

(* Thread-safe subscriber map: alias -> subscriber list (multiple connections per alias allowed) *)
module SubscriberMap : sig
  type t
  val create : unit -> t
  val add : t -> alias:string -> subscriber -> unit
  val remove : t -> alias:string -> subscriber -> unit
  val find : t -> alias:string -> subscriber list
  val iter : t -> (string -> subscriber list -> unit) -> unit
end = struct
  type t = {
    map : (string, subscriber list) Hashtbl.t;
    mutex : Mutex.t;
  }
  
  let create () = {
    map = Hashtbl.create 64;
    mutex = Mutex.create ();
  }
  
  let with_lock t f =
    Mutex.lock t.mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f
  
  let add t ~alias sub =
    with_lock t (fun () ->
      let subs = match Hashtbl.find_opt t.map alias with
        | Some l -> l | None -> []
      in
      Hashtbl.replace t.map alias (sub :: subs))
  
  let remove t ~alias sub =
    with_lock t (fun () ->
      match Hashtbl.find_opt t.map alias with
      | None -> ()
      | Some l ->
        let l' = List.filter (fun s -> s != sub) l in
        if l' = [] then Hashtbl.remove t.map alias
        else Hashtbl.replace t.map alias l')
  
  let find t ~alias =
    with_lock t (fun () ->
      match Hashtbl.find_opt t.map alias with
      | Some l -> l | None -> [])
  
  let iter t f =
    with_lock t (fun () ->
      Hashtbl.iter f t.map)
end

(* Global subscriber map *)
let subscribers = SubscriberMap.create ()

(* Parse JSON string, returning None on failure *)
let json_of_string_opt s =
  try Some (Yojson.Safe.from_string s) with _ -> None

(* Auth result *)
type auth_result =
  | Auth_ok of string (* alias *)
  | Auth_error of string (* error message *)

(* Validate subscribe auth headers.
   Returns Auth_ok alias if valid, Auth_error msg otherwise.
   lookup_pk is a function that returns Some raw_pk for a registered alias. *)
let validate_subscribe_auth
    ~(lookup_pk : alias:string -> string option)
    ~(alias : string)
    ~(ts_str : string)
    ~(sig_b64 : string) : auth_result =
  (* Parse timestamp *)
  let ts = try Some (float_of_string ts_str) with _ -> None in
  match ts with
  | None -> Auth_error "invalid timestamp format"
  | Some ts_client ->
    (* Check timestamp window *)
    let now = Unix.gettimeofday () in
    let skew = abs_float (ts_client -. now) in
    if skew > auth_ts_window then
      Auth_error (Printf.sprintf "timestamp skew %.1fs exceeds window" skew)
    else
      (* Look up identity pk *)
      match lookup_pk ~alias with
      | None -> Auth_error (Printf.sprintf "alias %S has no identity binding" alias)
      | Some pk ->
        (* Decode signature *)
        match b64url_decode sig_b64 with
        | Error _ -> Auth_error "signature not valid base64url"
        | Ok sig_ when String.length sig_ <> 64 ->
          Auth_error "signature must be 64 bytes"
        | Ok sig_ ->
          (* Verify: sign over alias || ts *)
          let msg = alias ^ ts_str in
          if Relay_identity.verify ~pk ~msg ~sig_ then
            Auth_ok alias
          else
            Auth_error "signature verification failed"

(* Push a DM to all subscribers for the given alias.
   Non-blocking: spawns async sends. *)
let push_dm ~to_alias ~from_alias ~body ~ts =
  let subs = SubscriberMap.find subscribers ~alias:to_alias in
  let payload = Yojson.Safe.to_string (`Assoc [
    ("op", `String "dm");
    ("from", `String from_alias);
    ("body", `String body);
    ("ts", `Float ts);
  ]) in
  List.iter (fun sub ->
    if not sub.closed then
      Lwt.async (fun () ->
        Lwt.catch
          (fun () -> Relay_ws_frame.Session.send_text sub.session payload)
          (fun _ -> sub.closed <- true; Lwt.return_unit))
  ) subs

(* Check if alias has any active subscribers *)
let has_subscribers ~alias =
  let subs = SubscriberMap.find subscribers ~alias in
  List.exists (fun s -> not s.closed) subs

(* Get count of active subscribers for an alias *)
let subscriber_count ~alias =
  let subs = SubscriberMap.find subscribers ~alias in
  List.length (List.filter (fun s -> not s.closed) subs)

(* Get total subscriber count across all aliases *)
let total_subscriber_count () =
  let count = ref 0 in
  SubscriberMap.iter subscribers (fun _ subs ->
    count := !count + List.length (List.filter (fun s -> not s.closed) subs));
  !count

(* Ping loop for a subscriber. Sends ping every 30s, expects pong within 10s. *)
let ping_loop sub =
  let rec loop () =
    if sub.closed then Lwt.return_unit
    else begin
      Lwt_unix.sleep ping_interval_s >>= fun () ->
      if sub.closed then Lwt.return_unit
      else begin
        let before_ping = Unix.gettimeofday () in
        (* Send ping *)
        Lwt.catch
          (fun () -> Relay_ws_frame.write_ping sub.session.oc)
          (fun _ -> sub.closed <- true; Lwt.return_unit)
        >>= fun () ->
        if sub.closed then Lwt.return_unit
        else begin
          (* Wait for pong timeout *)
          Lwt_unix.sleep pong_timeout_s >>= fun () ->
          if sub.closed then Lwt.return_unit
          else begin
            (* Check if pong was received after the ping *)
            if sub.last_pong < before_ping then begin
              (* No pong received - close connection *)
              sub.closed <- true;
              Lwt.catch
                (fun () ->
                  Relay_ws_frame.Session.close_with ~code:close_pong_timeout
                    ~reason:"pong timeout" () sub.session)
                (fun _ -> Lwt.return_unit)
            end else
              loop ()
          end
        end
      end
    end
  in
  loop ()

(* Process a subscribe/unsubscribe frame from the client.
   Returns (added_aliases, removed_aliases, error_opt). *)
let process_subscription_frame
    ~(lookup_pk : alias:string -> string option)
    (sub : subscriber)
    (json : Yojson.Safe.t) : (string list * string list * string option) =
  match json with
  | `Assoc fields ->
    let op = List.assoc_opt "op" fields in
    (match op with
     | Some (`String "subscribe") ->
       (* Add aliases: {"op":"subscribe","aliases":["alias1"],"signatures":{"alias1":{"ts":"...","sig":"..."}}} *)
       let aliases_json = List.assoc_opt "aliases" fields in
       let sigs_json = List.assoc_opt "signatures" fields in
       (match aliases_json, sigs_json with
        | Some (`List alias_list), Some (`Assoc sig_map) ->
          (* First pass: validate all aliases before mutating *)
          let validated = ref [] in
          let errors = ref [] in
          List.iter (fun alias_json ->
            match alias_json with
            | `String alias ->
              if StringSet.mem alias sub.aliases then ()
              else begin
                match List.assoc_opt alias sig_map with
                | Some (`Assoc sig_fields) ->
                  let get_str key = match List.assoc_opt key sig_fields with Some (`String s) -> s | _ -> "" in
                  let ts_str = get_str "ts" in
                  let sig_b64 = get_str "sig" in
                  (match validate_subscribe_auth ~lookup_pk ~alias ~ts_str ~sig_b64 with
                   | Auth_ok _ -> validated := alias :: !validated
                   | Auth_error msg -> errors := Printf.sprintf "%s: %s" alias msg :: !errors)
                | _ ->
                  errors := Printf.sprintf "%s: missing signature" alias :: !errors
              end
            | _ -> ()) alias_list;
          if !errors <> [] then
            ([], [], Some (String.concat "; " !errors))
          else begin
            (* Second pass: apply all validated aliases *)
            List.iter (fun alias ->
              sub.aliases <- StringSet.add alias sub.aliases;
              SubscriberMap.add subscribers ~alias sub) !validated;
            (!validated, [], None)
          end
        | _ -> ([], [], Some "subscribe requires 'aliases' array and 'signatures' object"))
     | Some (`String "unsubscribe") ->
       (* Remove aliases: {"op":"unsubscribe","aliases":["alias1"]} *)
       let aliases_json = List.assoc_opt "aliases" fields in
       (match aliases_json with
        | Some (`List alias_list) ->
          let removed = ref [] in
          List.iter (fun alias_json ->
            match alias_json with
            | `String alias ->
              if StringSet.mem alias sub.aliases then begin
                sub.aliases <- StringSet.remove alias sub.aliases;
                SubscriberMap.remove subscribers ~alias sub;
                removed := alias :: !removed
              end
            | _ -> ()) alias_list;
          ([], !removed, None)
        | _ -> ([], [], Some "unsubscribe requires 'aliases' array"))
     | _ -> ([], [], None))
  | _ -> ([], [], None)

(* Receive loop for a subscriber. Handles pong, close, subscribe/unsubscribe. *)
let recv_loop ~(lookup_pk : alias:string -> string option) (sub : subscriber) =
  let send_json json =
    if not sub.closed then
      Lwt.catch
        (fun () ->
           Relay_ws_frame.Session.send_text sub.session (Yojson.Safe.to_string json))
        (fun _ -> sub.closed <- true; Lwt.return_unit)
    else
      Lwt.return_unit
  in
  let rec loop () =
    if sub.closed then Lwt.return_unit
    else
      Lwt.catch
        (fun () ->
          Relay_ws_frame.Session.recv sub.session >>= function
          | None ->
            sub.closed <- true;
            Lwt.return_unit
          | Some `Ping ->
            loop ()
          | Some `Pong ->
            sub.last_pong <- Unix.gettimeofday ();
            loop ()
          | Some (`Close (_, _)) ->
            sub.closed <- true;
            Lwt.return_unit
          | Some (`Text payload) ->
            (* Phase 2: handle subscribe/unsubscribe frames *)
            (match json_of_string_opt payload with
             | Some json ->
               let (added, removed, err) = process_subscription_frame ~lookup_pk sub json in
               (match err with
                | Some msg ->
                  let resp = `Assoc [
                    ("ok", `Bool false);
                    ("error", `String msg);
                  ] in
                  send_json resp >>= fun () -> loop ()
                | None ->
                  let resp = `Assoc [
                    ("ok", `Bool true);
                    ("added", `List (List.map (fun a -> `String a) added));
                    ("removed", `List (List.map (fun a -> `String a) removed));
                  ] in
                  send_json resp >>= fun () -> loop ())
             | None -> loop ())
          | Some (`Binary _) ->
            loop ())
        (fun _ ->
          sub.closed <- true;
          Lwt.return_unit)
  in
  loop ()

(* Handle an upgraded WebSocket connection for subscription.
   Called after HTTP upgrade is complete.
   ~aliases: initial set of aliases to subscribe (from HTTP headers)
   ~lookup_pk: function to validate Ed25519 signatures for dynamic subscribe *)
let handle_subscriber_session ~aliases ~session ~lookup_pk =
  let sub = {
    aliases = StringSet.of_list aliases;
    session;
    last_pong = Unix.gettimeofday ();
    closed = false;
  } in
  (* Register for all initial aliases *)
  List.iter (fun alias -> SubscriberMap.add subscribers ~alias sub) aliases;
  (* Cleanup on exit — remove from all aliases *)
  let cleanup () =
    sub.closed <- true;
    StringSet.iter (fun alias -> SubscriberMap.remove subscribers ~alias sub) sub.aliases;
    sub.aliases <- StringSet.empty;
    (* Close the WS session/fd *)
    Lwt.catch (fun () -> Relay_ws_frame.Session.close_with ~code:close_normal ~reason:"cleanup" () sub.session)
      (fun _ -> Lwt.return_unit)
  in
  Lwt.finalize
    (fun () ->
      Lwt.pick [
        ping_loop sub;
        recv_loop ~lookup_pk sub;
      ])
    (fun () ->
      cleanup ())

let handle_subscriber ~aliases ~fd ~lookup_pk =
  handle_subscriber_session ~aliases
    ~session:(Relay_ws_frame.Session.of_fd fd) ~lookup_pk

let handle_subscriber_channels ~aliases ~ic ~oc ~lookup_pk =
  handle_subscriber_session ~aliases
    ~session:(Relay_ws_frame.Session.of_cohttp_channels ic oc) ~lookup_pk

(* Backward-compatible: handle a single-alias subscriber (Phase 1 behavior) *)
let handle_subscriber_single ~alias ~fd =
  handle_subscriber ~aliases:[alias] ~fd ~lookup_pk:(fun ~alias:_ -> None)

(* Build WS upgrade response headers *)
let make_upgrade_response ws_key =
  Relay_ws_frame.make_handshake_response ws_key
