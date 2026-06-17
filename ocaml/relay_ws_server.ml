(* relay_ws_server.ml — WebSocket push endpoint for c2c relay.
   Slice 2 of push-delivery design (2026-06-17).
   
   Subscribers connect via GET /ws/subscribe with Ed25519 auth headers:
   - X-C2C-Alias: <alias>
   - X-C2C-Timestamp: <unix_seconds>
   - X-C2C-Signature: <base64url of ed25519 sig over (alias || ts)>
   
   On successful auth, the connection upgrades to WebSocket. The server pushes
   DM frames: {"op":"dm", "from":"...", "body":"...", "ts":...}
   
   Server pings every 30s; expects pong within 10s or drops connection. *)

open Lwt.Infix

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

(* A subscriber connection *)
type subscriber = {
  alias : string;
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

(* Receive loop for a subscriber. Handles pong, close, and ignores other frames. *)
let recv_loop sub =
  let rec loop () =
    if sub.closed then Lwt.return_unit
    else begin
      Lwt.catch
        (fun () ->
          Relay_ws_frame.Session.recv sub.session >>= function
          | None ->
            (* EOF *)
            sub.closed <- true;
            Lwt.return_unit
          | Some `Ping ->
            (* Client sent ping - Session.recv auto-sent pong. Just continue. *)
            loop ()
          | Some `Pong ->
            (* Client responded to our ping - update last_pong for timeout check *)
            sub.last_pong <- Unix.gettimeofday ();
            loop ()
          | Some (`Close (_, _)) ->
            sub.closed <- true;
            Lwt.return_unit
          | Some (`Text _) | Some (`Binary _) ->
            (* Ignore client messages for now *)
            loop ())
        (fun _ ->
          sub.closed <- true;
          Lwt.return_unit)
    end
  in
  loop ()

(* Handle an upgraded WebSocket connection for subscription.
   Called after HTTP upgrade is complete. *)
let handle_subscriber ~alias ~fd =
  let session = Relay_ws_frame.Session.of_fd fd in
  let sub = {
    alias;
    session;
    last_pong = Unix.gettimeofday ();
    closed = false;
  } in
  (* Register *)
  SubscriberMap.add subscribers ~alias sub;
  (* Cleanup on exit *)
  let cleanup () =
    sub.closed <- true;
    SubscriberMap.remove subscribers ~alias sub
  in
  (* Run ping and recv loops concurrently *)
  Lwt.finalize
    (fun () ->
      Lwt.pick [
        ping_loop sub;
        recv_loop sub;
      ])
    (fun () ->
      cleanup ();
      Lwt.return_unit)

(* Build WS upgrade response headers *)
let make_upgrade_response ws_key =
  Relay_ws_frame.make_handshake_response ws_key
