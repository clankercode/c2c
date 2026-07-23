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

(* Test/ops instrumentation: count push_dm invocations (including zero-subscriber).
   Used by private-reachability tests to prove rejected first-contact never pushes. *)
let push_dm_count = Atomic.make 0
let push_dm_invocations () = Atomic.get push_dm_count
let reset_push_dm_count () = Atomic.set push_dm_count 0

(* ---------------------------------------------------------------------------
   B277 / B280: process-wide + per-IP caps on concurrent WS *connections*.

   B277: /ws/subscribe Expert upgrades (subscriber slots).
   B280: /observer/<binding> upgrades (observer slots) — sibling budget so an
   observer flood cannot starve subscribers and vice versa.

   - Cap is on unique connections (one slot per upgraded socket).
   - Dynamic multi-alias subscribe/unsubscribe on an existing connection does
     not consume additional slots.
   - Limits are env-tunable; tests call [set_connection_limits] /
     [set_observer_limits].
   --------------------------------------------------------------------------- *)

type cap_denial = Cap_global | Cap_per_ip

type slot = {
  client_ip : string;
  mutable released : bool;
}

type acquire_result =
  | Acquired of slot
  | Denied of { reason : cap_denial; retry_after_s : float }

type cap_config = {
  env_max_total : string;
  env_max_per_ip : string;
  env_retry_after : string;
  default_max_total : int;
  default_max_per_ip : int;
  default_retry_after_s : float;
}

let default_max_total = 1024
let default_max_per_ip = 32
let default_retry_after_s = 30.0

let subscriber_cap_config = {
  env_max_total = "C2C_RELAY_WS_MAX_SUBSCRIBERS";
  env_max_per_ip = "C2C_RELAY_WS_MAX_SUBSCRIBERS_PER_IP";
  env_retry_after = "C2C_RELAY_WS_CAP_RETRY_AFTER";
  default_max_total;
  default_max_per_ip;
  default_retry_after_s;
}

let observer_cap_config = {
  env_max_total = "C2C_RELAY_WS_MAX_OBSERVERS";
  env_max_per_ip = "C2C_RELAY_WS_MAX_OBSERVERS_PER_IP";
  env_retry_after = "C2C_RELAY_WS_OBSERVER_CAP_RETRY_AFTER";
  default_max_total;
  default_max_per_ip;
  default_retry_after_s;
}

let env_positive name default =
  match Sys.getenv_opt name with
  | None -> default
  | Some s ->
    (match int_of_string_opt (String.trim s) with
     | Some n when n > 0 -> n
     | _ -> default)

let env_float_positive name default =
  match Sys.getenv_opt name with
  | None -> default
  | Some s ->
    (match float_of_string_opt (String.trim s) with
     | Some n when n > 0. && Float.is_finite n -> n
     | _ -> default)

module ConnectionCap : sig
  type t
  val create : cap_config -> t
  val try_acquire : t -> client_ip:string -> acquire_result
  val release : t -> slot -> unit
  val active : t -> int
  val per_ip : t -> client_ip:string -> int
  val max_total : t -> int
  val max_per_ip : t -> int
  val retry_after_s : t -> float
  val denied_global : t -> int
  val denied_per_ip : t -> int
  val set_limits :
    t -> ?max_total:int -> ?max_per_ip:int -> ?retry_after_s:float -> unit -> unit
  val reset : t -> unit
end = struct
  type t = {
    config : cap_config;
    mutex : Mutex.t;
    mutable max_total : int;
    mutable max_per_ip : int;
    mutable retry_after_s : float;
    mutable total : int;
    per_ip : (string, int) Hashtbl.t;
    mutable denied_global : int;
    mutable denied_per_ip : int;
  }

  let create config = {
    config;
    mutex = Mutex.create ();
    max_total = env_positive config.env_max_total config.default_max_total;
    max_per_ip =
      env_positive config.env_max_per_ip config.default_max_per_ip;
    retry_after_s =
      env_float_positive config.env_retry_after config.default_retry_after_s;
    total = 0;
    per_ip = Hashtbl.create 64;
    denied_global = 0;
    denied_per_ip = 0;
  }

  let with_lock t f =
    Mutex.lock t.mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

  let try_acquire t ~client_ip =
    with_lock t (fun () ->
      let ip_count =
        match Hashtbl.find_opt t.per_ip client_ip with
        | Some n -> n
        | None -> 0
      in
      if t.total >= t.max_total then begin
        t.denied_global <- t.denied_global + 1;
        Denied { reason = Cap_global; retry_after_s = t.retry_after_s }
      end else if ip_count >= t.max_per_ip then begin
        t.denied_per_ip <- t.denied_per_ip + 1;
        Denied { reason = Cap_per_ip; retry_after_s = t.retry_after_s }
      end else begin
        t.total <- t.total + 1;
        Hashtbl.replace t.per_ip client_ip (ip_count + 1);
        Acquired { client_ip; released = false }
      end)

  let release t slot =
    if slot.released then ()
    else
      with_lock t (fun () ->
        if not slot.released then begin
          slot.released <- true;
          t.total <- max 0 (t.total - 1);
          match Hashtbl.find_opt t.per_ip slot.client_ip with
          | Some n when n <= 1 -> Hashtbl.remove t.per_ip slot.client_ip
          | Some n -> Hashtbl.replace t.per_ip slot.client_ip (n - 1)
          | None -> ()
        end)

  let active t = with_lock t (fun () -> t.total)
  let per_ip t ~client_ip =
    with_lock t (fun () ->
      match Hashtbl.find_opt t.per_ip client_ip with
      | Some n -> n
      | None -> 0)
  let max_total t = with_lock t (fun () -> t.max_total)
  let max_per_ip t = with_lock t (fun () -> t.max_per_ip)
  let retry_after_s t = with_lock t (fun () -> t.retry_after_s)
  let denied_global t = with_lock t (fun () -> t.denied_global)
  let denied_per_ip t = with_lock t (fun () -> t.denied_per_ip)

  let set_limits t ?max_total ?max_per_ip ?retry_after_s () =
    with_lock t (fun () ->
      (match max_total with
       | Some n when n > 0 -> t.max_total <- n
       | _ -> ());
      (match max_per_ip with
       | Some n when n > 0 -> t.max_per_ip <- n
       | _ -> ());
      (match retry_after_s with
       | Some n when n > 0. && Float.is_finite n -> t.retry_after_s <- n
       | _ -> ()))

  let reset t =
    with_lock t (fun () ->
      t.total <- 0;
      Hashtbl.clear t.per_ip;
      t.denied_global <- 0;
      t.denied_per_ip <- 0;
      t.max_total <-
        env_positive t.config.env_max_total t.config.default_max_total;
      t.max_per_ip <-
        env_positive t.config.env_max_per_ip t.config.default_max_per_ip;
      t.retry_after_s <-
        env_float_positive t.config.env_retry_after t.config.default_retry_after_s)
end

(* --- B277: /ws/subscribe subscriber connection cap --- *)

let connection_cap = ConnectionCap.create subscriber_cap_config

let try_acquire_slot ~client_ip =
  ConnectionCap.try_acquire connection_cap ~client_ip

let release_slot slot = ConnectionCap.release connection_cap slot

let active_connection_count () = ConnectionCap.active connection_cap

let per_ip_connection_count ~client_ip =
  ConnectionCap.per_ip connection_cap ~client_ip

let connection_limits () =
  ( ConnectionCap.max_total connection_cap
  , ConnectionCap.max_per_ip connection_cap
  , ConnectionCap.retry_after_s connection_cap )

let set_connection_limits ?max_total ?max_per_ip ?retry_after_s () =
  ConnectionCap.set_limits connection_cap ?max_total ?max_per_ip ?retry_after_s ()

let reset_connection_cap () = ConnectionCap.reset connection_cap

let cap_denied_counts () =
  ( ConnectionCap.denied_global connection_cap
  , ConnectionCap.denied_per_ip connection_cap )

let cap_denial_label = function
  | Cap_global -> "global"
  | Cap_per_ip -> "per_ip"

(** JSON fragment for /stats and ops surfaces. *)
let connection_cap_stats_json () =
  let max_total, max_per_ip, retry_after_s = connection_limits () in
  let denied_global, denied_per_ip = cap_denied_counts () in
  `Assoc [
    ("subscribers", `Int (active_connection_count ()));
    ("max_subscribers", `Int max_total);
    ("max_per_ip", `Int max_per_ip);
    ("retry_after_s", `Float retry_after_s);
    ("denied_global", `Int denied_global);
    ("denied_per_ip", `Int denied_per_ip);
  ]

(* --- B280: /observer/* concurrent session cap (sibling budget) --- *)

let observer_cap = ConnectionCap.create observer_cap_config

let try_acquire_observer_slot ~client_ip =
  ConnectionCap.try_acquire observer_cap ~client_ip

let release_observer_slot slot = ConnectionCap.release observer_cap slot

let active_observer_count () = ConnectionCap.active observer_cap

let per_ip_observer_count ~client_ip =
  ConnectionCap.per_ip observer_cap ~client_ip

let observer_limits () =
  ( ConnectionCap.max_total observer_cap
  , ConnectionCap.max_per_ip observer_cap
  , ConnectionCap.retry_after_s observer_cap )

let set_observer_limits ?max_total ?max_per_ip ?retry_after_s () =
  ConnectionCap.set_limits observer_cap ?max_total ?max_per_ip ?retry_after_s ()

let reset_observer_cap () = ConnectionCap.reset observer_cap

let observer_cap_denied_counts () =
  ( ConnectionCap.denied_global observer_cap
  , ConnectionCap.denied_per_ip observer_cap )

(** JSON fragment for /stats — observer concurrent sessions (B280). *)
let observer_cap_stats_json () =
  let max_total, max_per_ip, retry_after_s = observer_limits () in
  let denied_global, denied_per_ip = observer_cap_denied_counts () in
  `Assoc [
    ("observers", `Int (active_observer_count ()));
    ("max_observers", `Int max_total);
    ("max_per_ip", `Int max_per_ip);
    ("retry_after_s", `Float retry_after_s);
    ("denied_global", `Int denied_global);
    ("denied_per_ip", `Int denied_per_ip);
  ]

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
  Atomic.incr push_dm_count;
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
   ~lookup_pk: function to validate Ed25519 signatures for dynamic subscribe
   ~slot: optional B277 connection-cap slot; released on disconnect so the
     global/per-IP budget frees for new upgrades. Production Expert path always
     passes a slot acquired before the 101 response. *)
let handle_subscriber_session ~aliases ~session ~lookup_pk ?slot () =
  let sub = {
    aliases = StringSet.of_list aliases;
    session;
    last_pong = Unix.gettimeofday ();
    closed = false;
  } in
  (* Register for all initial aliases *)
  List.iter (fun alias -> SubscriberMap.add subscribers ~alias sub) aliases;
  (* Cleanup on exit — remove from all aliases + free connection slot *)
  let cleanup () =
    sub.closed <- true;
    StringSet.iter (fun alias -> SubscriberMap.remove subscribers ~alias sub) sub.aliases;
    sub.aliases <- StringSet.empty;
    (match slot with
     | Some s -> release_slot s
     | None -> ());
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

let handle_subscriber ~aliases ~fd ~lookup_pk ?slot () =
  handle_subscriber_session ~aliases
    ~session:(Relay_ws_frame.Session.of_fd fd) ~lookup_pk ?slot ()

let handle_subscriber_channels ~aliases ~ic ~oc ~lookup_pk ?slot () =
  handle_subscriber_session ~aliases
    ~session:(Relay_ws_frame.Session.of_cohttp_channels ic oc) ~lookup_pk ?slot ()

(* Backward-compatible: handle a single-alias subscriber (Phase 1 behavior) *)
let handle_subscriber_single ~alias ~fd =
  handle_subscriber ~aliases:[alias] ~fd ~lookup_pk:(fun ~alias:_ -> None) ()

(* Build WS upgrade response headers *)
let make_upgrade_response ws_key =
  Relay_ws_frame.make_handshake_response ws_key
