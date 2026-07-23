(* c2c_relay_subscribe_daemon.ml — Multi-alias relay subscription daemon.
 *
 * A long-running process that manages WebSocket connections to the relay
 * on behalf of multiple client processes (pi-c2c, opencode, etc.).
 *
 * One daemon per harness instance. Clients connect via Unix socket and
 * register/deregister aliases using a JSON-line IPC protocol.
 *
 * Phase 1: one WS connection per alias, managed by a single daemon process.
 * Phase 2: single multiplexed WS connection for all aliases (future).
 *
 * Usage:
 *   c2c relay subscribe-daemon                           # start daemon
 *   c2c relay subscribe-daemon register --alias ALIAS    # register alias
 *   c2c relay subscribe-daemon deregister --alias ALIAS  # deregister alias
 *   c2c relay subscribe-daemon list                      # daemon-global list (B278)
 *   c2c relay subscribe-daemon list --mine               # this IPC client only
 *   c2c relay subscribe-daemon shutdown                  # stop daemon
 *
 * List semantics (B278):
 * - IPC {"cmd":"list"} — per-client aliases (harness session view).
 * - IPC {"cmd":"list","all":true} / {"cmd":"list_all"} — daemon-global view
 *   of every open client's aliases plus a summary (clients, aliases,
 *   connected/connecting/stopped). Operator CLI defaults to global so a
 *   one-shot `list` no longer prints empty while the daemon is busy.
 *)

open Lwt.Infix
open Cmdliner.Term.Syntax

(* === Configuration === *)

let default_socket_dir =
  let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
  Filename.concat home ".c2c"
let default_socket_name = "relay-subscribe.sock"

(* === B273: reconnect backoff (full jitter + stable-session reset) ===
 *
 * Pre-B273: expo 1s→30s, no jitter, reset to 1s on any successful upgrade.
 * That thunders when origin recovers and re-hammers on multi-minute crash
 * loops (SIGSEGV every 4–8 min kept aliases near the short end).
 *
 * Policy:
 * 1. Full jitter: delay ∈ [0, base] (base capped at reconnect_backoff_max).
 * 2. Base doubles after each non-stable attempt, never above max.
 * 3. Reset base only after a *stable* session — connected ≥ stable_session_secs
 *    OR a keepalive frame (Ping/Pong) proved liveness — not on mere 101.
 * 4. Daemon-level circuit: many near-simultaneous failures share a cool-down.
 *
 * Pure helpers below are unit-tested; [rand] is injectable for determinism.
 *)

let reconnect_backoff_initial = 1.0
let reconnect_backoff_max = 30.0
(** Wall-clock seconds a session must survive before backoff fully resets. *)
let stable_session_secs = 45.0

(** Full-jitter delay: uniform sample in [0, min(base, max_backoff)].
    [rand x] must return a float in [0, x) (same contract as [Random.float]). *)
let full_jitter_delay ~base ~max_backoff ?(rand = Random.float) () =
  let cap = Float.min max_backoff (Float.max 0.0 base) in
  if cap <= 0.0 then 0.0 else rand cap

(** Grow the expo base after a failed / unstable attempt. *)
let grow_backoff ~base ~max_backoff =
  Float.min max_backoff (Float.max reconnect_backoff_initial (base *. 2.0))

(** Whether a finished session earned a full backoff reset.
    [got_keepalive] is true if the client saw a WS Ping or Pong (liveness). *)
let should_reset_backoff ~session_duration_s ~got_keepalive
    ?(stable_secs = stable_session_secs) () =
  got_keepalive || session_duration_s >= stable_secs

(** Daemon-wide cool-down when many aliases fail together (origin unhealthy). *)
module Reconnect_circuit = struct
  type t = {
    mutable failures : float list;
    mutable cool_until : float;
  }

  let failure_threshold = 5
  let window_s = 15.0
  let cool_down_s = 30.0

  let create () = { failures = []; cool_until = 0.0 }

  let remaining_cool (t : t) ~now =
    Float.max 0.0 (t.cool_until -. now)

  let is_open (t : t) ~now = remaining_cool t ~now > 0.0

  (** Record one alias-level connect/session failure. Trips a shared cool-down
      once [failure_threshold] failures land inside [window_s]. *)
  let record_failure (t : t) ~now =
    let cutoff = now -. window_s in
    let recent = List.filter (fun t0 -> t0 >= cutoff) t.failures in
    let recent = now :: recent in
    t.failures <- recent;
    if List.length recent >= failure_threshold then begin
      t.cool_until <- Float.max t.cool_until (now +. cool_down_s);
      t.failures <- []
    end

  let cool_until (t : t) = t.cool_until

  let reset (t : t) =
    t.failures <- [];
    t.cool_until <- 0.0
end

(* B275: max concurrent in-flight /ws/subscribe connects defaults to
   C2c_ws_connect_gate.default_max_inflight; overridable via
   C2C_RELAY_SUBSCRIBE_MAX_INFLIGHT. *)

(* === IPC Protocol === *)

type register_request = {
  reg_alias : string;
  reg_id : string;
}

type deregister_request = {
  dereg_alias : string;
  dereg_id : string;
}

(** [List { all }] — [all=false] is the calling IPC client's aliases only;
    [all=true] is daemon-global (every open client). B278. *)
type ipc_request =
  | Register of register_request
  | Deregister of deregister_request
  | List of { all : bool }
  | Shutdown

type list_summary = {
  sum_clients : int;
  sum_aliases : int;
  sum_connected : int;
  sum_connecting : int;
  sum_stopped : int;
}

type ipc_response = {
  resp_ok : bool;
  resp_id : string;
  resp_alias : string;
  resp_error : string option;
  resp_aliases : alias_info list;
  (** Present on list responses (always for global list; also for per-client). *)
  resp_summary : list_summary option;
}

and alias_info = {
  info_alias : string;
  info_state : string;
  info_started_at : float;
}

let empty_response ?(ok = true) ?(id = "") ?(alias = "") ?error () : ipc_response =
  { resp_ok = ok; resp_id = id; resp_alias = alias;
    resp_error = error; resp_aliases = []; resp_summary = None }

(** Map connection flags to a stable state string for IPC/CLI. *)
let alias_state_string ~stop_requested ~session_alive =
  if stop_requested then "stopped"
  else if session_alive then "connected"
  else "connecting"

(** Count alias states for the summary block. [clients] is the number of
    open IPC clients included in the view (1 for --mine, N for --all). *)
let summarize_alias_infos ~(clients : int) (aliases : alias_info list) : list_summary =
  let connected = ref 0 and connecting = ref 0 and stopped = ref 0 in
  List.iter (fun a ->
      match a.info_state with
      | "connected" -> incr connected
      | "stopped" -> incr stopped
      | _ -> incr connecting) aliases;
  { sum_clients = clients;
    sum_aliases = List.length aliases;
    sum_connected = !connected;
    sum_connecting = !connecting;
    sum_stopped = !stopped }

(** True when [list] should return the daemon-global view. Accepts
    [all:true], [scope:"all"|"global"], or cmd [list_all]. *)
let list_request_wants_all (fields : (string * Yojson.Safe.t) list) : bool =
  match List.assoc_opt "all" fields with
  | Some (`Bool b) -> b
  | Some (`String s) ->
    let s = String.lowercase_ascii (String.trim s) in
    s = "true" || s = "1" || s = "yes" || s = "all"
  | Some (`Int n) -> n <> 0
  | _ ->
    match List.assoc_opt "scope" fields with
    | Some (`String s) ->
      let s = String.lowercase_ascii (String.trim s) in
      s = "all" || s = "global" || s = "daemon"
    | _ -> false

(* Parse a JSON-line IPC request *)
let parse_request (json : Yojson.Safe.t) : ipc_request option =
  let get_string fields key =
    match List.assoc_opt key fields with
    | Some (`String s) -> Some s
    | _ -> None
  in
  match json with
  | `Assoc fields ->
    let cmd = get_string fields "cmd" in
    (match cmd with
     | Some "register" ->
       (match get_string fields "alias", get_string fields "id" with
        | Some a, Some i -> Some (Register { reg_alias = a; reg_id = i })
        | _ -> None)
     | Some "deregister" ->
       (match get_string fields "alias", get_string fields "id" with
        | Some a, Some i -> Some (Deregister { dereg_alias = a; dereg_id = i })
        | _ -> None)
     | Some "list" -> Some (List { all = list_request_wants_all fields })
     | Some "list_all" -> Some (List { all = true })
     | Some "shutdown" -> Some Shutdown
     | _ -> None)
  | _ -> None

let alias_info_to_json (a : alias_info) : Yojson.Safe.t =
  `Assoc [
    ("alias", `String a.info_alias);
    ("state", `String a.info_state);
    ("started_at", `Float a.info_started_at);
  ]

let summary_to_json (s : list_summary) : Yojson.Safe.t =
  `Assoc [
    ("clients", `Int s.sum_clients);
    ("aliases", `Int s.sum_aliases);
    ("connected", `Int s.sum_connected);
    ("connecting", `Int s.sum_connecting);
    ("stopped", `Int s.sum_stopped);
  ]

let response_to_json (r : ipc_response) : Yojson.Safe.t =
  let base = [
    ("ok", `Bool r.resp_ok);
    ("id", `String r.resp_id);
    ("alias", `String r.resp_alias);
  ] in
  let with_error = match r.resp_error with
    | Some e -> ("error", `String e) :: base
    | None -> base
  in
  (* List responses always include aliases + summary (even when empty) so
     operators can distinguish "daemon idle" from a missing field (B278). *)
  match r.resp_summary with
  | Some summary ->
    `Assoc (
      ("summary", summary_to_json summary)
      :: ("aliases", `List (List.map alias_info_to_json r.resp_aliases))
      :: with_error)
  | None ->
    if r.resp_aliases <> [] then
      `Assoc (
        ("aliases", `List (List.map alias_info_to_json r.resp_aliases))
        :: with_error)
    else
      `Assoc with_error

let dm_to_json ~to_alias ~from_alias ~body ~ts : Yojson.Safe.t =
  `Assoc [
    ("type", `String "dm");
    ("to", `String to_alias);
    ("from", `String from_alias);
    ("body", `String body);
    ("ts", `Float ts);
  ]

(* === Helpers === *)

let json_of_string_opt s =
  try Some (Yojson.Safe.from_string s) with _ -> None

let string_of_json j = Yojson.Safe.to_string j

(* === Alias Connection State === *)

(* stop_requested: user called deregister or client disconnected — no reconnect.
   session_alive: currently connected to relay WS. Set false on WS error/close.
   ws_backoff: expo base for full-jitter reconnect delay (B273). *)
type alias_conn = {
  alias : string;
  ws_session : Relay_ws_frame.Client_session.t option ref;
  mutable stop_requested : bool;
  mutable session_alive : bool;
  mutable ws_backoff : float;
  mutable ws_started_at : float;
  cancel : unit Lwt.u;
}

(* === Client State === *)

type client_conn = {
  client_ic : Lwt_io.input_channel;
  client_oc : Lwt_io.output_channel;
  client_fd : Lwt_unix.file_descr;
  mutable client_aliases : (string * alias_conn) list;
  mutable client_closed : bool;
}

(* === Daemon State === *)

type daemon_state = {
  mutable clients : client_conn list;
  mutable shutdown_requested : bool;
  mutable listen_sock : Lwt_unix.file_descr option;
  mutable shutdown_waker : unit Lwt.u option;
  (* bugs.txt 2026-06-29: singleton guard. Held open for the daemon's whole
     lifetime; closing it (or process exit) releases the cross-process lock
     so the next start can acquire it. [None] only if the guard was bypassed
     (e.g. legacy/debug path) — the normal path always sets it. *)
  mutable lock_fd : Unix.file_descr option;
  socket_path : string;
  identity : Relay_identity.t;
  relay_endpoint : Relay_ws_client.endpoint;
  (* B273: shared cool-down when many aliases fail together. *)
  circuit : Reconnect_circuit.t;
  (* B275: global cap on concurrent in-flight /ws/subscribe handshakes.
     Live sessions do not hold a slot — only connect/handshake does. *)
  connect_gate : C2c_ws_connect_gate.t;
}

(* === WebSocket Connection Management (non-blocking Lwt) === *)

let create_ws_session_lwt ~endpoint ~alias ~identity =
  Relay_ws_client.connect_subscribe ~endpoint ~alias ~identity ()

(* Connect under the global in-flight gate (B275). Slot is held only for the
   handshake — released as soon as connect returns (ok or error) so other
   aliases can proceed while this one reads frames. Re-check stop after
   acquiring in case we waited in the queue while deregister fired. *)
let stop_while_queued_msg = "subscribe-daemon: stop requested while queued for connect"

let connect_with_gate (state : daemon_state) (conn : alias_conn) =
  C2c_ws_connect_gate.with_slot state.connect_gate (fun () ->
      if conn.stop_requested then
        Lwt.fail (Failure stop_while_queued_msg)
      else
        create_ws_session_lwt ~endpoint:state.relay_endpoint
          ~alias:conn.alias ~identity:state.identity)

(* Run a single alias WS connection: connects, reads frames, forwards DMs.
   Handles reconnection with full-jitter expo backoff + stable-session reset
   (B273). *)
let run_alias_connection (state : daemon_state) (client : client_conn) (conn : alias_conn) =
  let rec connect_and_loop () =
    if conn.stop_requested then Lwt.return_unit
    else begin
      (* Outcome of this attempt — drives backoff reset vs grow + circuit. *)
      let outcome : [ `Stable | `Unstable | `Connect_failed ] ref =
        ref `Connect_failed
      in
      Lwt.catch
        (fun () ->
           connect_with_gate state conn
           >>= fun (session, close) ->
           conn.ws_session := Some session;
           conn.session_alive <- true;
           (* B273: do NOT reset backoff on mere upgrade 101 — only after a
              stable session (duration or keepalive). *)
           conn.ws_started_at <- Unix.gettimeofday ();
           let got_keepalive = ref false in
           (* Send connected state to client *)
           let msg = `Assoc [
             ("type", `String "state");
             ("alias", `String conn.alias);
             ("state", `String "connected");
           ] in
           Lwt.finalize
             (fun () ->
                Lwt.catch
                  (fun () ->
                     let line = string_of_json msg in
                     Lwt_io.write_line client.client_oc line >>= fun () ->
                     Lwt_io.flush client.client_oc)
                  (fun _ -> conn.stop_requested <- true; Lwt.return_unit)
                >>= fun () ->
                (* Read loop — forward DMs to client, recurse on success *)
                let rec read_loop () =
                  if conn.stop_requested || client.client_closed then Lwt.return_unit
                  else
                    Lwt.catch
                      (fun () ->
                         Relay_ws_frame.Client_session.recv session >>= fun frame ->
                         match frame with
                         | Some (`Text payload) ->
                           (match json_of_string_opt payload with
                            | Some (`Assoc fields) ->
                              let op = List.assoc_opt "op" fields in
                              if op = Some (`String "dm") then begin
                                let get_str key = match List.assoc_opt key fields with Some (`String s) -> s | _ -> "" in
                                let get_float key = match List.assoc_opt key fields with Some (`Float f) -> f | Some (`Int i) -> float_of_int i | _ -> 0.0 in
                                let from = let v = get_str "from" in if v = "" then "unknown" else v in
                                let body = get_str "body" in
                                let ts = get_float "ts" in
                                let dm_msg = dm_to_json ~to_alias:conn.alias ~from_alias:from ~body ~ts in
                                if client.client_closed then Lwt.return_unit
                                else
                                  Lwt.catch
                                    (fun () ->
                                       let line = string_of_json dm_msg in
                                       Lwt_io.write_line client.client_oc line >>= fun () ->
                                       Lwt_io.flush client.client_oc >>= fun () ->
                                       read_loop ())
                                    (fun _ -> conn.stop_requested <- true; Lwt.return_unit)
                              end else
                                read_loop ()
                            | _ -> read_loop ())
                         | Some `Ping ->
                           (* Keepalive proves the session is live (B273). *)
                           got_keepalive := true;
                           read_loop ()
                         | Some `Pong ->
                           got_keepalive := true;
                           read_loop ()
                         | Some (`Close (_, _)) ->
                           conn.session_alive <- false;
                           Lwt.return_unit
                         | Some (`Binary _) -> read_loop ()
                         | None ->
                           conn.session_alive <- false;
                           Lwt.return_unit)
                      (fun _ ->
                         conn.session_alive <- false;
                         Lwt.return_unit)
                in
                read_loop ())
             (fun () ->
                (* Classify session before tearing down resources. *)
                let duration = Unix.gettimeofday () -. conn.ws_started_at in
                outcome :=
                  if should_reset_backoff ~session_duration_s:duration
                       ~got_keepalive:!got_keepalive ()
                  then `Stable
                  else `Unstable;
                (* Always close WS resources on exit *)
                conn.ws_session := None;
                conn.session_alive <- false;
                Lwt.catch (fun () -> Relay_ws_frame.Client_session.close session) (fun _ -> Lwt.return_unit)
                >>= fun () ->
                Lwt.catch close (fun _ -> Lwt.return_unit)))
        (fun exn ->
           outcome := `Connect_failed;
           (* Quiet on intentional stop-while-queued; still log real failures. *)
           (match exn with
            | Failure msg when msg = stop_while_queued_msg -> ()
            | _ ->
              Printf.eprintf "[subscribe-daemon] WS connect failed for %s: %s\n%!"
                conn.alias (Printexc.to_string exn));
           Lwt.return_unit)
      >>= fun () ->
      if conn.stop_requested || client.client_closed then
        Lwt.return_unit
      else begin
        (* B273: full-jitter delay; reset only after stable; circuit cool-down. *)
        let now = Unix.gettimeofday () in
        (match !outcome with
         | `Stable ->
           conn.ws_backoff <- reconnect_backoff_initial
         | `Unstable | `Connect_failed ->
           Reconnect_circuit.record_failure state.circuit ~now);
        let delay =
          full_jitter_delay ~base:conn.ws_backoff
            ~max_backoff:reconnect_backoff_max ()
        in
        let circuit_wait = Reconnect_circuit.remaining_cool state.circuit ~now in
        let wait = Float.max delay circuit_wait in
        Printf.eprintf
          "[subscribe-daemon] reconnecting %s in %.1fs (base=%.1fs circuit=%.1fs outcome=%s)...\n%!"
          conn.alias wait conn.ws_backoff circuit_wait
          (match !outcome with
           | `Stable -> "stable"
           | `Unstable -> "unstable"
           | `Connect_failed -> "connect_failed");
        Lwt_unix.sleep wait >>= fun () ->
        (match !outcome with
         | `Stable ->
           (* Leave base at initial so the next cycle starts clean. *)
           ()
         | `Unstable | `Connect_failed ->
           conn.ws_backoff <-
             grow_backoff ~base:conn.ws_backoff
               ~max_backoff:reconnect_backoff_max);
        connect_and_loop ()
      end
    end
  in
  connect_and_loop ()

(* === Client Handling === *)

let send_response (client : client_conn) (resp : ipc_response) =
  if not client.client_closed then begin
    Lwt.catch
      (fun () ->
         let line = string_of_json (response_to_json resp) in
         Lwt_io.write_line client.client_oc line >>= fun () ->
         Lwt_io.flush client.client_oc)
      (fun _ -> client.client_closed <- true; Lwt.return_unit)
  end else
    Lwt.return_unit

(* B274: cancel may already be woken (double deregister / cleanup race). *)
let request_alias_stop (conn : alias_conn) =
  conn.stop_requested <- true;
  (try Lwt.wakeup_later conn.cancel () with Invalid_argument _ -> ())

(* B274: if pick/cancel races past the session finalize, still drop the WS. *)
let close_alias_session (conn : alias_conn) =
  conn.session_alive <- false;
  match !(conn.ws_session) with
  | None -> Lwt.return_unit
  | Some session ->
      conn.ws_session := None;
      Lwt.catch
        (fun () -> Relay_ws_frame.Client_session.close session)
        (fun _ -> Lwt.return_unit)

let handle_register (state : daemon_state) (client : client_conn) (req : register_request) =
  if List.mem_assoc req.reg_alias client.client_aliases then begin
    send_response client (empty_response ~id:req.reg_id ~alias:req.reg_alias ())
  end else begin
    let conn_cancel, cancel = Lwt.wait () in
    let conn = {
      alias = req.reg_alias;
      ws_session = ref None;
      stop_requested = false;
      session_alive = false;
      ws_backoff = reconnect_backoff_initial;
      ws_started_at = 0.0;
      cancel;
    } in
    client.client_aliases <- (req.reg_alias, conn) :: client.client_aliases;
    (* B274: wrap pick so cancel always runs session cleanup after the fiber
       dies — mid-connect FD close is owned by Relay_ws_client finalize. *)
    Lwt.async (fun () ->
        Lwt.finalize
          (fun () ->
             Lwt.pick [
               run_alias_connection state client conn;
               (conn_cancel >>= fun () -> Lwt.return_unit);
             ])
          (fun () -> close_alias_session conn));
    send_response client (empty_response ~id:req.reg_id ~alias:req.reg_alias ())
  end

let handle_deregister (client : client_conn) (req : deregister_request) =
  match List.assoc_opt req.dereg_alias client.client_aliases with
  | Some conn ->
    request_alias_stop conn;
    client.client_aliases <- List.filter (fun (a, _) -> a <> req.dereg_alias) client.client_aliases;
    send_response client (empty_response ~id:req.dereg_id ~alias:req.dereg_alias ())
  | None ->
    send_response client
      (empty_response ~ok:false ~id:req.dereg_id ~alias:req.dereg_alias
         ~error:"alias not registered" ())

let alias_info_of_conn (alias : string) (conn : alias_conn) : alias_info =
  { info_alias = alias;
    info_state = alias_state_string
        ~stop_requested:conn.stop_requested
        ~session_alive:conn.session_alive;
    info_started_at = conn.ws_started_at }

let aliases_of_client (client : client_conn) : alias_info list =
  List.map (fun (alias, conn) -> alias_info_of_conn alias conn) client.client_aliases

(** Collect aliases from every open IPC client (daemon-global view, B278). *)
let collect_all_aliases (state : daemon_state) : int * alias_info list =
  let open_clients =
    List.filter (fun c -> not c.client_closed) state.clients in
  let aliases =
    List.concat_map aliases_of_client open_clients in
  (List.length open_clients, aliases)

let handle_list ~(all : bool) (state : daemon_state) (client : client_conn) =
  let clients_n, aliases =
    if all then collect_all_aliases state
    else
      let n = if client.client_closed then 0 else 1 in
      (n, aliases_of_client client)
  in
  let summary = summarize_alias_infos ~clients:clients_n aliases in
  send_response client {
    resp_ok = true; resp_id = ""; resp_alias = "";
    resp_error = None; resp_aliases = aliases;
    resp_summary = Some summary;
  }

(** B281: drop [client] from the daemon client list by physical equality.
    Pure helper so unit tests can cover the prune without Lwt FDs. Under Lwt
    cooperative scheduling the read-filter-assign is a single non-yielding
    step, so it does not race with accept's prepend. *)
let remove_client_from_list (client : 'a) (clients : 'a list) : 'a list =
  List.filter (fun c -> c != client) clients

(** Mark [client] closed, stop its aliases, prune it from [state.clients], and
    close IPC channels. Idempotent: a second call is a no-op prune. B281. *)
let cleanup_client (state : daemon_state) (client : client_conn) =
  let first = not client.client_closed in
  client.client_closed <- true;
  if first then begin
    List.iter (fun (_alias, conn) -> request_alias_stop conn) client.client_aliases;
    client.client_aliases <- []
  end;
  (* Always prune — keeps the list consistent if a prior path set
     client_closed without removing (legacy) or races re-enter cleanup. *)
  state.clients <- remove_client_from_list client state.clients;
  if first then
    (* Close IPC channels *)
    Lwt.async (fun () ->
        Lwt.catch (fun () -> Lwt_io.close client.client_ic) (fun _ -> Lwt.return_unit) >>= fun () ->
        Lwt.catch (fun () -> Lwt_io.close client.client_oc) (fun _ -> Lwt.return_unit) >>= fun () ->
        Lwt.catch (fun () -> Lwt_unix.close client.client_fd) (fun _ -> Lwt.return_unit))

let handle_client (state : daemon_state) (client : client_conn) =
  let rec loop () =
    if client.client_closed || state.shutdown_requested then Lwt.return_unit
    else
      Lwt.catch
        (fun () ->
           Lwt_io.read_line_opt client.client_ic >>= fun line ->
           match line with
           | None ->
             cleanup_client state client;
             Lwt.return_unit
           | Some raw ->
             (match json_of_string_opt raw with
              | Some json ->
                (match parse_request json with
                 | Some (Register req) ->
                   handle_register state client req >>= fun () -> loop ()
                 | Some (Deregister req) ->
                   handle_deregister client req >>= fun () -> loop ()
                 | Some (List { all }) ->
                   handle_list ~all state client >>= fun () -> loop ()
                 | Some Shutdown ->
                   state.shutdown_requested <- true;
                   (match state.shutdown_waker with
                    | Some waker -> Lwt.wakeup_later waker ()
                    | None -> ());
                   send_response client (empty_response ())
                 | None ->
                   send_response client
                     (empty_response ~ok:false ~error:"invalid request" ())
                   >>= fun () -> loop ())
              | None ->
                send_response client
                  (empty_response ~ok:false ~error:"invalid JSON" ())
                >>= fun () -> loop ()))
        (fun _ ->
           cleanup_client state client;
           Lwt.return_unit)
  in
  loop ()

(* === Server === *)

let accept_connections (state : daemon_state) =
  let sock = Lwt_unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  (try Unix.unlink state.socket_path with _ -> ());
  Lwt_unix.bind sock (Unix.ADDR_UNIX state.socket_path) >>= fun () ->
  Lwt_unix.listen sock 16;
  state.listen_sock <- Some sock;
  Printf.eprintf "[subscribe-daemon] listening on %s\n%!" state.socket_path;
  (* Race accept against shutdown *)
  let shutdown_promise, shutdown_waker = Lwt.wait () in
  state.shutdown_waker <- Some shutdown_waker;
  (* Store waker so shutdown command can trigger it *)
  let accept_loop () =
    let rec loop () =
      if state.shutdown_requested then Lwt.return_unit
      else
        Lwt.catch
          (fun () ->
             Lwt.pick [
               (Lwt_unix.accept sock >>= fun (client_fd, _addr) -> Lwt.return (`Client client_fd));
               (shutdown_promise >>= fun () -> Lwt.return `Shutdown);
             ] >>= function
             | `Shutdown -> Lwt.return_unit
             | `Client client_fd ->
               let fd_lwt = client_fd in
               let ic = Lwt_io.of_fd ~mode:Lwt_io.Input fd_lwt in
               let oc = Lwt_io.of_fd ~mode:Lwt_io.Output fd_lwt in
               let client = {
                 client_ic = ic; client_oc = oc; client_fd = fd_lwt;
                 client_aliases = []; client_closed = false;
               } in
               state.clients <- client :: state.clients;
               Lwt.async (fun () -> handle_client state client);
               loop ())
          (fun _ ->
             if state.shutdown_requested then Lwt.return_unit
             else Lwt_unix.sleep 0.1 >>= loop)
    in
    loop ()
  in
  (* Store the shutdown waker in state for the shutdown command *)
  let orig_shutdown = state.shutdown_requested in
  let result = accept_loop () in
  (* If shutdown was requested during setup, wake the promise *)
  if state.shutdown_requested && not orig_shutdown then
    Lwt.wakeup_later shutdown_waker ();
  (* Return a tuple so the caller can trigger shutdown *)
  Lwt.return (result, shutdown_waker)

let cleanup_daemon (state : daemon_state) =
  (* Snapshot: cleanup_client mutates state.clients (B281 prune). List.iter
     holds the original cons cells, so every client is visited once. *)
  List.iter (fun client -> cleanup_client state client) state.clients;
  (match state.listen_sock with
   | Some sock -> Lwt.async (fun () -> Lwt.catch (fun () -> Lwt_unix.close sock) (fun _ -> Lwt.return_unit))
   | None -> ());
  (try Unix.unlink state.socket_path with _ -> ());
  (* Remove the pidfile we wrote at startup so callers that probe for a live
     daemon (e.g. pi-c2c DaemonClient.isDaemonRunning) see us as gone. *)
  (try Unix.unlink (state.socket_path ^ ".pid") with _ -> ());
  (* Release the singleton lock. The OS also releases it on process exit, but
     closing explicitly keeps the fd table tidy on clean shutdown. *)
  (match state.lock_fd with
   | Some fd -> state.lock_fd <- None; C2c_singleton_lock.release fd
   | None -> ());
  Printf.eprintf "[subscribe-daemon] shutdown complete\n%!"

(* === CLI Commands === *)

let socket_path_arg () =
  Cmdliner.Arg.(value & opt (some string) None & info [ "socket" ] ~docv:"PATH"
    ~doc:"Unix socket path. Default: ~/.c2c/relay-subscribe.sock")

let resolve_socket_path explicit =
  match explicit with
  | Some p -> p
  | None -> Filename.concat default_socket_dir default_socket_name

let start_daemon_cmd =
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL"
      ~doc:"Relay server URL (default: https://relay.c2c.im).")
  and socket = socket_path_arg () in
  let+ relay_url = relay_url
  and+ socket = socket in
  let socket_path = resolve_socket_path socket in
  let url = match relay_url with
    | Some u -> u
    | None ->
      (try Sys.getenv "C2C_RELAY_URL" with _ ->
       try
         let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
         let config_path = Filename.concat home ".c2c/relay-setup.json" in
         let ic = open_in config_path in
         let json = Yojson.Safe.from_channel ic in
         close_in ic;
         match json with
         | `Assoc fields ->
           (match List.assoc_opt "url" fields with
            | Some (`String u) -> u
            | _ -> "https://relay.c2c.im")
         | _ -> "https://relay.c2c.im"
       with _ -> "https://relay.c2c.im")
  in
  if not (Relay_doctor.subscribe_url_supported url) then begin
    Printf.eprintf
      "error: c2c relay subscribe-daemon does not support this relay URL scheme.\n\
       hint: use http(s):// or ws(s):// (e.g. https://relay.c2c.im).\n%!";
    exit 1
  end;
  let endpoint = Relay_ws_client.parse_endpoint url in
  match Relay_identity.load () with
  | Error msg ->
    Printf.eprintf "error: cannot load identity.json: %s\n%!" msg;
    Printf.eprintf "Run 'c2c relay identity init' first.\n%!";
    exit 1
  | Ok identity ->
    let scheme = if endpoint.Relay_ws_client.use_tls then "wss" else "ws" in
    let connect_gate = C2c_ws_connect_gate.create () in
    Printf.eprintf
      "[subscribe-daemon] starting (relay=%s://%s:%d socket=%s max_inflight_connects=%d)\n%!"
      scheme endpoint.Relay_ws_client.host endpoint.Relay_ws_client.port socket_path
      (C2c_ws_connect_gate.capacity connect_gate);
    (* B273: seed jitter so concurrent daemons / multi-alias loops desync. *)
    Random.self_init ();
    let state = {
      clients = []; shutdown_requested = false; listen_sock = None;
      shutdown_waker = None; lock_fd = None;
      socket_path; identity; relay_endpoint = endpoint;
      circuit = Reconnect_circuit.create ();
      connect_gate;
    } in
    let handle_signal _sig =
      state.shutdown_requested <- true;
      cleanup_daemon state;
      exit 0
    in
    Sys.set_signal Sys.sigterm (Sys.Signal_handle handle_signal);
    Sys.set_signal Sys.sigint (Sys.Signal_handle handle_signal);
    (try Unix.mkdir (Filename.dirname socket_path) 0o755 with _ -> ());
    (* bugs.txt 2026-06-29: singleton guard. Acquire a cross-process lock on
       <socket>.lock BEFORE binding the socket. A second start against an
       already-running daemon gets [Already_running] and exits 0 (idempotent
       auto-start) instead of unlinking the socket path and orphaning the
       live owner (which had piled up 344 duplicate daemons). The lock is a
       POSIX lockf released automatically on process exit, so a crashed
       owner leaves no stale lock — only a stale socket file, which we unlink
       below before binding because we are now provably the sole owner. *)
    (match C2c_singleton_lock.try_acquire ~path:socket_path with
     | Already_running ->
       Printf.eprintf "[subscribe-daemon] already running on %s; exiting\n%!" socket_path;
       exit 0
     | Acquired fd -> state.lock_fd <- Some fd);
    let pid_file = socket_path ^ ".pid" in
    let oc = open_out pid_file in
    Printf.fprintf oc "%d\n" (Unix.getpid ());
    close_out oc;
    Lwt_main.run (
      accept_connections state >>= fun (accept_promise, _shutdown_waker) ->
      accept_promise
    );
    cleanup_daemon state

let register_cmd =
  let alias =
    Cmdliner.Arg.(required & opt (some string) None & info [ "alias" ] ~docv:"ALIAS"
      ~doc:"Alias to register.")
  and socket = socket_path_arg () in
  let+ alias = alias
  and+ socket = socket in
  let socket_path = resolve_socket_path socket in
  Lwt_main.run (
    let fd = Lwt_unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Lwt.finalize
      (fun () ->
         Lwt_unix.connect fd (Unix.ADDR_UNIX socket_path) >>= fun () ->
         let ic = Lwt_io.of_fd ~mode:Lwt_io.Input fd in
         let oc = Lwt_io.of_fd ~mode:Lwt_io.Output fd in
         let id = Printf.sprintf "reg-%d" (Unix.getpid ()) in
         let req = `Assoc [
           ("cmd", `String "register");
           ("alias", `String alias);
           ("id", `String id);
         ] in
         Lwt_io.write_line oc (Yojson.Safe.to_string req) >>= fun () ->
         Lwt_io.flush oc >>= fun () ->
         Lwt_io.read_line ic >>= fun resp_line ->
         let resp = Yojson.Safe.from_string resp_line in
         Printf.printf "%s\n%!" (Yojson.Safe.pretty_to_string resp);
         Lwt_io.close ic >>= fun () ->
         Lwt_io.close oc)
      (fun () -> Lwt_unix.close fd)
  )

let deregister_cmd =
  let alias =
    Cmdliner.Arg.(required & opt (some string) None & info [ "alias" ] ~docv:"ALIAS"
      ~doc:"Alias to deregister.")
  and socket = socket_path_arg () in
  let+ alias = alias
  and+ socket = socket in
  let socket_path = resolve_socket_path socket in
  Lwt_main.run (
    let fd = Lwt_unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Lwt.finalize
      (fun () ->
         Lwt_unix.connect fd (Unix.ADDR_UNIX socket_path) >>= fun () ->
         let ic = Lwt_io.of_fd ~mode:Lwt_io.Input fd in
         let oc = Lwt_io.of_fd ~mode:Lwt_io.Output fd in
         let id = Printf.sprintf "dereg-%d" (Unix.getpid ()) in
         let req = `Assoc [
           ("cmd", `String "deregister");
           ("alias", `String alias);
           ("id", `String id);
         ] in
         Lwt_io.write_line oc (Yojson.Safe.to_string req) >>= fun () ->
         Lwt_io.flush oc >>= fun () ->
         Lwt_io.read_line ic >>= fun resp_line ->
         let resp = Yojson.Safe.from_string resp_line in
         Printf.printf "%s\n%!" (Yojson.Safe.pretty_to_string resp);
         Lwt_io.close ic >>= fun () ->
         Lwt_io.close oc)
      (fun () -> Lwt_unix.close fd)
  )

let list_cmd =
  (* B278: operator default is daemon-global. A one-shot CLI list opens a
     fresh IPC connection with zero aliases of its own — listing only that
     client always printed empty and hid a busy daemon. --mine keeps the
     per-session view for harness debugging. *)
  let mine =
    Cmdliner.Arg.(value & flag & info [ "mine" ]
      ~doc:"List only aliases registered on this IPC connection (per-client \
            view). Default is daemon-global: every open client's aliases \
            plus a summary (clients, aliases, connected/connecting/stopped).")
  and socket = socket_path_arg () in
  let+ mine = mine
  and+ socket = socket in
  let socket_path = resolve_socket_path socket in
  Lwt_main.run (
    let fd = Lwt_unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Lwt.finalize
      (fun () ->
         Lwt_unix.connect fd (Unix.ADDR_UNIX socket_path) >>= fun () ->
         let ic = Lwt_io.of_fd ~mode:Lwt_io.Input fd in
         let oc = Lwt_io.of_fd ~mode:Lwt_io.Output fd in
         let req =
           if mine then `Assoc [("cmd", `String "list")]
           else `Assoc [("cmd", `String "list"); ("all", `Bool true)]
         in
         Lwt_io.write_line oc (Yojson.Safe.to_string req) >>= fun () ->
         Lwt_io.flush oc >>= fun () ->
         Lwt_io.read_line ic >>= fun resp_line ->
         let resp = Yojson.Safe.from_string resp_line in
         Printf.printf "%s\n%!" (Yojson.Safe.pretty_to_string resp);
         Lwt_io.close ic >>= fun () ->
         Lwt_io.close oc)
      (fun () -> Lwt_unix.close fd)
  )

let shutdown_cmd =
  let socket = socket_path_arg () in
  let+ socket = socket in
  let socket_path = resolve_socket_path socket in
  Lwt_main.run (
    let fd = Lwt_unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Lwt.finalize
      (fun () ->
         Lwt_unix.connect fd (Unix.ADDR_UNIX socket_path) >>= fun () ->
         let ic = Lwt_io.of_fd ~mode:Lwt_io.Input fd in
         let oc = Lwt_io.of_fd ~mode:Lwt_io.Output fd in
         let req = `Assoc [("cmd", `String "shutdown")] in
         Lwt_io.write_line oc (Yojson.Safe.to_string req) >>= fun () ->
         Lwt_io.flush oc >>= fun () ->
         Lwt_io.read_line ic >>= fun resp_line ->
         let resp = Yojson.Safe.from_string resp_line in
         Printf.printf "%s\n%!" (Yojson.Safe.pretty_to_string resp);
         Lwt_io.close ic >>= fun () ->
         Lwt_io.close oc)
      (fun () -> Lwt_unix.close fd)
  )

(* === Subcommand Registration === *)

let subscribe_daemon_start =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "start" ~doc:"Start the subscription daemon.")
    start_daemon_cmd

let subscribe_daemon_register =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "register" ~doc:"Register an alias with the daemon.")
    register_cmd

let subscribe_daemon_deregister =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "deregister" ~doc:"Deregister an alias from the daemon.")
    deregister_cmd

let subscribe_daemon_list =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "list"
       ~doc:"List managed aliases (daemon-global by default; --mine for this IPC client only).")
    list_cmd

let subscribe_daemon_shutdown =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "shutdown" ~doc:"Shutdown the daemon.")
    shutdown_cmd

let subscribe_daemon_cmd =
  Cmdliner.Cmd.group
    ~default:start_daemon_cmd
    (Cmdliner.Cmd.info "subscribe-daemon"
       ~doc:"Multi-alias relay subscription daemon. Manages WS connections for multiple aliases in one process."
       ~man:[ `S "DESCRIPTION"
            ; `P "$(b,c2c relay subscribe-daemon) manages WebSocket connections to the c2c relay for multiple aliases in a single process."
            ; `P "Client harnesses (pi-c2c, opencode, etc.) register aliases via the Unix socket IPC. The daemon opens and manages the WS connections, forwarding DMs back to clients."
            ; `P "Default socket: ~/.c2c/relay-subscribe.sock"
            ; `P "$(b,list) is daemon-global by default (every open IPC client's aliases plus a summary). Harness IPC $(b,{\"cmd\":\"list\"}) remains per-client; pass $(b,all:true) or use $(b,list_all) for the global view. Operator CLI: $(b,list) global, $(b,list --mine) per-client."
            ])
    [ subscribe_daemon_start; subscribe_daemon_register; subscribe_daemon_deregister; subscribe_daemon_list; subscribe_daemon_shutdown ]
