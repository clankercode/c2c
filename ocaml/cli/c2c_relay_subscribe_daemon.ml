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
 *   c2c relay subscribe-daemon list                      # list aliases
 *   c2c relay subscribe-daemon shutdown                  # stop daemon
 *)

open Lwt.Infix
open Cmdliner.Term.Syntax

(* === Configuration === *)

let default_socket_dir =
  let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
  Filename.concat home ".c2c"
let default_socket_name = "relay-subscribe.sock"
let reconnect_backoff_initial = 1.0
let reconnect_backoff_max = 30.0
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

type ipc_request =
  | Register of register_request
  | Deregister of deregister_request
  | List
  | Shutdown

type ipc_response = {
  resp_ok : bool;
  resp_id : string;
  resp_alias : string;
  resp_error : string option;
  resp_aliases : alias_info list;
}

and alias_info = {
  info_alias : string;
  info_state : string;
  info_started_at : float;
}

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
     | Some "list" -> Some List
     | Some "shutdown" -> Some Shutdown
     | _ -> None)
  | _ -> None

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
  if r.resp_aliases <> [] then
    `Assoc (
      ("aliases", `List (List.map (fun a ->
        `Assoc [
          ("alias", `String a.info_alias);
          ("state", `String a.info_state);
          ("started_at", `Float a.info_started_at);
        ]) r.resp_aliases)) :: with_error)
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
   session_alive: currently connected to relay WS. Set false on WS error/close. *)
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
   Handles reconnection with exponential backoff. *)
let run_alias_connection (state : daemon_state) (client : client_conn) (conn : alias_conn) =
  let rec connect_and_loop () =
    if conn.stop_requested then Lwt.return_unit
    else begin
      Lwt.catch
        (fun () ->
           connect_with_gate state conn
           >>= fun (session, close) ->
           conn.ws_session := Some session;
           conn.session_alive <- true;
           conn.ws_backoff <- reconnect_backoff_initial;
           conn.ws_started_at <- Unix.gettimeofday ();
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
                         | Some `Ping -> read_loop ()
                         | Some `Pong -> read_loop ()
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
                (* Always close WS resources on exit *)
                conn.ws_session := None;
                conn.session_alive <- false;
                Lwt.catch (fun () -> Relay_ws_frame.Client_session.close session) (fun _ -> Lwt.return_unit)
                >>= fun () ->
                Lwt.catch close (fun _ -> Lwt.return_unit)))
        (fun exn ->
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
        (* Reconnect with backoff *)
        Printf.eprintf "[subscribe-daemon] reconnecting %s in %.1fs...\n%!"
          conn.alias conn.ws_backoff;
        Lwt_unix.sleep conn.ws_backoff >>= fun () ->
        conn.ws_backoff <- min (conn.ws_backoff *. 2.0) reconnect_backoff_max;
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

let handle_register (state : daemon_state) (client : client_conn) (req : register_request) =
  if List.mem_assoc req.reg_alias client.client_aliases then begin
    send_response client {
      resp_ok = true; resp_id = req.reg_id; resp_alias = req.reg_alias;
      resp_error = None; resp_aliases = [];
    }
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
    Lwt.async (fun () ->
        Lwt.pick [
          run_alias_connection state client conn;
          conn_cancel;
        ]);
    send_response client {
      resp_ok = true; resp_id = req.reg_id; resp_alias = req.reg_alias;
      resp_error = None; resp_aliases = [];
    }
  end

let handle_deregister (client : client_conn) (req : deregister_request) =
  match List.assoc_opt req.dereg_alias client.client_aliases with
  | Some conn ->
    conn.stop_requested <- true;
    Lwt.wakeup_later conn.cancel ();
    client.client_aliases <- List.filter (fun (a, _) -> a <> req.dereg_alias) client.client_aliases;
    send_response client {
      resp_ok = true; resp_id = req.dereg_id; resp_alias = req.dereg_alias;
      resp_error = None; resp_aliases = [];
    }
  | None ->
    send_response client {
      resp_ok = false; resp_id = req.dereg_id; resp_alias = req.dereg_alias;
      resp_error = Some "alias not registered"; resp_aliases = [];
    }

let handle_list (client : client_conn) =
  let aliases = List.map (fun (alias, conn) ->
      let state_str =
        if conn.stop_requested then "stopped"
        else if conn.session_alive then "connected"
        else "connecting" in
      { info_alias = alias; info_state = state_str; info_started_at = conn.ws_started_at })
      client.client_aliases in
  send_response client {
    resp_ok = true; resp_id = ""; resp_alias = "";
    resp_error = None; resp_aliases = aliases;
  }

let cleanup_client (client : client_conn) =
  client.client_closed <- true;
  List.iter (fun (_alias, conn) ->
      conn.stop_requested <- true;
      Lwt.wakeup_later conn.cancel ();
    ) client.client_aliases;
  client.client_aliases <- [];
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
             cleanup_client client;
             Lwt.return_unit
           | Some raw ->
             (match json_of_string_opt raw with
              | Some json ->
                (match parse_request json with
                 | Some (Register req) ->
                   handle_register state client req >>= fun () -> loop ()
                 | Some (Deregister req) ->
                   handle_deregister client req >>= fun () -> loop ()
                 | Some List ->
                   handle_list client >>= fun () -> loop ()
                 | Some Shutdown ->
                   state.shutdown_requested <- true;
                   (match state.shutdown_waker with
                    | Some waker -> Lwt.wakeup_later waker ()
                    | None -> ());
                   send_response client {
                     resp_ok = true; resp_id = ""; resp_alias = "";
                     resp_error = None; resp_aliases = [];
                   }
                 | None ->
                   send_response client {
                     resp_ok = false; resp_id = ""; resp_alias = "";
                     resp_error = Some "invalid request"; resp_aliases = [];
                   } >>= fun () -> loop ())
              | None ->
                send_response client {
                  resp_ok = false; resp_id = ""; resp_alias = "";
                  resp_error = Some "invalid JSON"; resp_aliases = [];
                } >>= fun () -> loop ()))
        (fun _ ->
           cleanup_client client;
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
  List.iter (fun client -> cleanup_client client) state.clients;
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
    let state = {
      clients = []; shutdown_requested = false; listen_sock = None;
      shutdown_waker = None; lock_fd = None;
      socket_path; identity; relay_endpoint = endpoint;
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
         let req = `Assoc [("cmd", `String "list")] in
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
    (Cmdliner.Cmd.info "list" ~doc:"List registered aliases.")
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
            ])
    [ subscribe_daemon_start; subscribe_daemon_register; subscribe_daemon_deregister; subscribe_daemon_list; subscribe_daemon_shutdown ]
