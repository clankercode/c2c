(* c2c_codex_app_server — internal app-server-backed Codex session launcher
   primitive (backlog P1.M1.E1.T002).

   OWNS one `codex app-server` (headless, authenticated loopback WebSocket) plus
   one stock `codex --remote` frontend as a SINGLE managed unit: endpoint
   allocation, capability-token auth setup, child spawning, verified readiness,
   supervision, exit propagation, cleanup, and the minimal NON-SECRET persisted
   mapping later tasks resume/deliver against.

   ===================================================================== OWNERSHIP
   Internal PRIMITIVE + SECURITY BOUNDARY only; wired into the build, NOT a public
   CLI. Sibling task boundaries:

   - T006 (public grammar) owns `c2c start codex`/`codex`/`new`/`resume`, alias
     generation/override, generated-name UX, `--yolo`, flag forwarding. It calls
     {!start}/{!supervise_step}/{!stop}/{!supervise_until_exit} and reads
     {!persisted}; it must NOT re-implement spawning/auth here. `thread_id` in
     {!persisted} is the field T006/T003 fill once a thread is loaded (left
     [None] here).
   - T003 (passive ingress) owns `thread/inject_items` over the authed control
     channel (persist-first to the broker inbox; never `turn/*`). This module
     opens NO control JSON-RPC session and delivers nothing.
   - T007 (policy-driven turns) owns any `turn/start`. This module never starts a
     turn and never reads message content.

   ================================================================ AUTH BOUNDARY
   T001 proved (receipt: .collab/research/2026-07-11-t001-...): a bare
   loopback/unix listener has ZERO same-UID boundary. The ONLY proven boundary is
   launching the app-server with `--ws-auth capability-token --ws-token-sha256
   <sha>`: an unauthenticated / wrong-token client is rejected with HTTP 401 at
   the WebSocket handshake; a correct `Authorization: Bearer <token>` grants
   access.

   Secret flow (never weakened):
   - A fresh 256-bit CSPRNG capability token is generated per unit.
   - The server receives ONLY its sha256 hex on the command line (`--ws-token-sha256`).
   - The frontend receives the RAW token via an ENV VAR named on the command line
     (`--remote-auth-token-env <ENVVAR>`); the value is placed only in the
     frontend child's environment — never in argv.
   - The raw token lives ONLY in this launcher process's memory + the frontend
     child's environment: never on disk, never in argv, never in logs, never in
     {!persisted}/{!diagnostic} JSON. It is scrubbed on stop.
   - Because the raw token is memory-only, a *different* process that loads
     {!persisted} cannot authenticate to the recorded endpoint — so resume can
     NEVER silently attach (see {!classify_persisted}).

   Endpoint is always `ws://127.0.0.1:<port>` — no TCP/non-loopback listener.

   Startup-race hardening (loopback ephemeral ports have an inherent
   allocate-then-bind TOCTOU): before the frontend is spawned, readiness requires
   not only an authed 101 handshake but ALSO that the listening socket on the
   endpoint port is owned by OUR server child pid ({!real_verify_owner}, via
   /proc). Once our server holds the bound socket no same-UID process can rebind
   the port, so verifying ownership at readiness time is race-free and prevents a
   same-UID impersonator from ever receiving the frontend's bearer token.

   ================================================================== TESTABILITY
   All external effects go through a {!backend} record of closures so tests script
   every lifecycle transition deterministically without touching a live process.
   {!real_backend} is the production Unix implementation; {!handshake} is the real
   WS-handshake auth probe reused by both readiness and the auth-rejection test. *)

let ( // ) = Filename.concat

(* --------------------------------------------------------------------------- *)
(* Lifecycle state                                                             *)
(* --------------------------------------------------------------------------- *)

type state =
  | Allocating
  | Starting_server
  | Waiting_ready
  | Starting_frontend
  | Running
  | Frontend_exited
  | Stopping_server
  | Offline
  | Failed
  | Cleaning_up

let state_to_string = function
  | Allocating -> "allocating"
  | Starting_server -> "starting_server"
  | Waiting_ready -> "waiting_ready"
  | Starting_frontend -> "starting_frontend"
  | Running -> "running"
  | Frontend_exited -> "frontend_exited"
  | Stopping_server -> "stopping_server"
  | Offline -> "offline"
  | Failed -> "failed"
  | Cleaning_up -> "cleaning_up"

let state_of_string = function
  | "allocating" -> Allocating
  | "starting_server" -> Starting_server
  | "waiting_ready" -> Waiting_ready
  | "starting_frontend" -> Starting_frontend
  | "running" -> Running
  | "frontend_exited" -> Frontend_exited
  | "stopping_server" -> Stopping_server
  | "offline" -> Offline
  | "failed" -> Failed
  | "cleaning_up" -> Cleaning_up
  | _ -> Offline

(* --------------------------------------------------------------------------- *)
(* Structured diagnostic (consumable by T006)                                  *)
(* --------------------------------------------------------------------------- *)

type diag_code =
  | Codex_not_found
  | Codex_version_unsupported
  | Codex_capability_unsupported
  | Endpoint_alloc_failed
  | Server_spawn_failed
  | Readiness_timeout
  | Server_died_before_ready
  | Endpoint_ownership_unverified
  | Auth_setup_failed
  | Frontend_spawn_failed
  | Persistence_failed
  | Internal_error

let diag_code_to_string = function
  | Codex_not_found -> "codex_not_found"
  | Codex_version_unsupported -> "codex_version_unsupported"
  | Codex_capability_unsupported -> "codex_capability_unsupported"
  | Endpoint_alloc_failed -> "endpoint_alloc_failed"
  | Server_spawn_failed -> "server_spawn_failed"
  | Readiness_timeout -> "readiness_timeout"
  | Server_died_before_ready -> "server_died_before_ready"
  | Endpoint_ownership_unverified -> "endpoint_ownership_unverified"
  | Auth_setup_failed -> "auth_setup_failed"
  | Frontend_spawn_failed -> "frontend_spawn_failed"
  | Persistence_failed -> "persistence_failed"
  | Internal_error -> "internal_error"

type diagnostic = {
  code : diag_code;
  message : string;
  codex_version : string option;
  min_codex_version : string option;
}

let diagnostic_to_json (d : diagnostic) : Yojson.Safe.t =
  `Assoc
    ([ ("error", `String "codex_app_server_launch_failed")
     ; ("code", `String (diag_code_to_string d.code))
     ; ("message", `String d.message) ]
     @ (match d.codex_version with Some v -> [ ("codex_version", `String v) ] | None -> [])
     @ (match d.min_codex_version with
        | Some v -> [ ("min_codex_version", `String v) ] | None -> []))

(* --------------------------------------------------------------------------- *)
(* Endpoint locator (safe — no secret)                                         *)
(* --------------------------------------------------------------------------- *)

type endpoint = { transport : string; host : string; port : int }

let endpoint_uri (e : endpoint) = Printf.sprintf "%s://%s:%d" e.transport e.host e.port

let endpoint_to_json (e : endpoint) : Yojson.Safe.t =
  `Assoc [ ("transport", `String e.transport); ("host", `String e.host); ("port", `Int e.port) ]

let endpoint_of_json (j : Yojson.Safe.t) : endpoint option =
  match j with
  | `Assoc a ->
      let s k = match List.assoc_opt k a with Some (`String v) -> Some v | _ -> None in
      let i k = match List.assoc_opt k a with Some (`Int v) -> Some v | _ -> None in
      (match s "transport", s "host", i "port" with
       | Some transport, Some host, Some port -> Some { transport; host; port }
       | _ -> None)
  | _ -> None

(* --------------------------------------------------------------------------- *)
(* Version parsing                                                             *)
(* --------------------------------------------------------------------------- *)

(* Parse "codex-cli 0.144.1" / "0.144.1" / "v2.0" into (major, minor, patch). A
   trailing non-numeric suffix on patch (e.g. "-rc1") is truncated. *)
let parse_version (s : string) : (int * int * int) option =
  let s = String.trim s in
  let toks = String.split_on_char ' ' s |> List.filter (fun t -> t <> "") in
  let cand = match List.rev toks with t :: _ -> t | [] -> s in
  let cand =
    if String.length cand > 0 && (cand.[0] = 'v' || cand.[0] = 'V')
    then String.sub cand 1 (String.length cand - 1) else cand
  in
  let leading_int t =
    let b = Buffer.create 8 in
    (try String.iter (fun c -> if c >= '0' && c <= '9' then Buffer.add_char b c else raise Exit) t
     with Exit -> ());
    int_of_string_opt (Buffer.contents b)
  in
  match String.split_on_char '.' cand with
  | maj :: min :: patch :: _ ->
      (match int_of_string_opt (String.trim maj), int_of_string_opt (String.trim min),
             leading_int (String.trim patch) with
       | Some a, Some b, Some c -> Some (a, b, c) | _ -> None)
  | maj :: [ min ] ->
      (match int_of_string_opt (String.trim maj), leading_int (String.trim min) with
       | Some a, Some b -> Some (a, b, 0) | _ -> None)
  | _ -> None

let version_ge (a : int * int * int) (b : int * int * int) : bool =
  let a1, a2, a3 = a and b1, b2, b3 = b in
  if a1 <> b1 then a1 > b1 else if a2 <> b2 then a2 > b2 else a3 >= b3

let version_triple_to_string (a, b, c) = Printf.sprintf "%d.%d.%d" a b c

(* --------------------------------------------------------------------------- *)
(* Auth material                                                              *)
(* --------------------------------------------------------------------------- *)

let sha256_hex (s : string) : string =
  Digestif.SHA256.digest_string s |> Digestif.SHA256.to_hex

let hex_of_bytes (s : string) : string =
  let b = Buffer.create (String.length s * 2) in
  String.iter (fun c -> Buffer.add_string b (Printf.sprintf "%02x" (Char.code c))) s;
  Buffer.contents b

let rng_initialized = ref false
let ensure_rng () =
  if not !rng_initialized then (Mirage_crypto_rng_unix.use_default (); rng_initialized := true)

(* Env var name that carries the raw bearer token into the frontend child. Only
   the NAME is ever persisted/logged; the value is set only in the frontend
   child's environment. Sanitized to [A-Z0-9_]. *)
let token_env_var_name (unit_id : string) : string =
  let b = Buffer.create 32 in
  Buffer.add_string b "C2C_CODEX_REMOTE_TOKEN_";
  String.iter
    (fun c ->
      let c = Char.uppercase_ascii c in
      if (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') then Buffer.add_char b c
      else Buffer.add_char b '_')
    unit_id;
  Buffer.contents b

(* --------------------------------------------------------------------------- *)
(* Child process abstraction                                                   *)
(* --------------------------------------------------------------------------- *)

type child_status = Running_ | Exited of int | Signaled of int

let child_status_to_string = function
  | Running_ -> "running"
  | Exited c -> Printf.sprintf "exited:%d" c
  | Signaled s -> Printf.sprintf "signaled:%d" s

type child = {
  child_id : int;                   (* pid for the real backend; synthetic for fakes *)
  poll_fn : unit -> child_status;   (* nonblocking liveness *)
  signal_fn : int -> unit;          (* best-effort; no-op once reaped *)
  reap_fn : float -> child_status;  (* SIG(TERM|KILL) -> wait; idempotent *)
}

let child_poll c = c.poll_fn ()
let child_signal c s = c.signal_fn s
let child_reap ?(timeout = 5.0) c = c.reap_fn timeout

(* --------------------------------------------------------------------------- *)
(* Readiness / auth handshake result                                           *)
(* --------------------------------------------------------------------------- *)

type handshake_result =
  | Hs_ready               (* HTTP 101 Switching Protocols — authed OK *)
  | Hs_unauthorized        (* HTTP 401/403 — auth rejected at handshake *)
  | Hs_refused             (* TCP connection refused — server not up yet / gone *)
  | Hs_status of int       (* some other HTTP status *)
  | Hs_error of string     (* transient socket/protocol error *)

let handshake_result_to_string = function
  | Hs_ready -> "ready"
  | Hs_unauthorized -> "unauthorized"
  | Hs_refused -> "refused"
  | Hs_status c -> Printf.sprintf "status:%d" c
  | Hs_error e -> Printf.sprintf "error:%s" e

exception Refused_exn

(* One WebSocket-upgrade handshake against [ep], optionally presenting a bearer
   [token]. We read only the HTTP status line — auth is decided at the handshake
   (101 vs 401), so we never complete the upgrade. Same boundary T001 proved;
   reused for readiness AND the auth-rejection test (call with [token:None]). *)
let handshake ?(timeout = 3.0) (ep : endpoint) ~(token : string option) : handshake_result =
  let addr =
    try Unix.ADDR_INET (Unix.inet_addr_of_string ep.host, ep.port)
    with _ -> Unix.ADDR_INET (Unix.inet_addr_loopback, ep.port)
  in
  let fd = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> try Unix.close fd with _ -> ())
    (fun () ->
      try
        Unix.setsockopt_float fd Unix.SO_RCVTIMEO timeout;
        Unix.setsockopt_float fd Unix.SO_SNDTIMEO timeout;
        (try Unix.connect fd addr
         with
         | Unix.Unix_error (Unix.ECONNREFUSED, _, _)
         | Unix.Unix_error (Unix.ECONNRESET, _, _) -> raise Refused_exn);
        let auth_line =
          match token with
          | Some t when String.trim t <> "" -> Printf.sprintf "Authorization: Bearer %s\r\n" t
          | _ -> ""
        in
        let req =
          Printf.sprintf
            "GET / HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
             Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n%s\r\n"
            ep.host ep.port auth_line
        in
        let _ = Unix.write_substring fd req 0 (String.length req) in
        let buf = Bytes.create 512 in
        let n = try Unix.read fd buf 0 512 with _ -> 0 in
        if n <= 0 then Hs_error "empty_response"
        else begin
          let resp = Bytes.sub_string buf 0 n in
          let line = match String.index_opt resp '\r' with Some i -> String.sub resp 0 i | None -> resp in
          match String.split_on_char ' ' line with
          | _proto :: code :: _ ->
              (match int_of_string_opt (String.trim code) with
               | Some 101 -> Hs_ready
               | Some (401 | 403) -> Hs_unauthorized
               | Some c -> Hs_status c
               | None -> Hs_error ("bad_status_line:" ^ line))
          | _ -> Hs_error ("bad_status_line:" ^ line)
        end
      with
      | Refused_exn -> Hs_refused
      | Unix.Unix_error (Unix.ECONNREFUSED, _, _) -> Hs_refused
      | Unix.Unix_error (e, _, _) -> Hs_error (Unix.error_message e)
      | e -> Hs_error (Printexc.to_string e))

(* --------------------------------------------------------------------------- *)
(* /proc helpers: PID + listener ownership (Linux; startup-race hardening)      *)
(* --------------------------------------------------------------------------- *)

let read_proc_cmdline (pid : int) : string option =
  let path = Printf.sprintf "/proc/%d/cmdline" pid in
  try
    let ic = open_in_bin path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      let n = in_channel_length ic in
      let raw = really_input_string ic n in
      (* NUL-separated argv -> space-joined *)
      Some (String.map (fun c -> if c = '\000' then ' ' else c) raw))
  with _ -> None

let pid_alive (pid : int) : bool =
  try Unix.kill pid 0; true
  with Unix.Unix_error (Unix.ESRCH, _, _) -> false | _ -> false

(* Process-group id of [pid] from /proc/<pid>/stat (field 5; parsed after the
   final ')' so a comm containing spaces/parens is handled). *)
let proc_pgrp (pid : int) : int option =
  try
    let ic = open_in (Printf.sprintf "/proc/%d/stat" pid) in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      let line = input_line ic in
      match String.rindex_opt line ')' with
      | None -> None
      | Some i ->
          let rest = String.sub line (i + 1) (String.length line - i - 1) in
          (match List.filter (fun s -> s <> "") (String.split_on_char ' ' rest) with
           | _state :: _ppid :: pgrp :: _ -> int_of_string_opt pgrp
           | _ -> None))
  with _ -> None

(* Verify that the LISTEN socket on the endpoint port is held by a process in
   OUR server's process group (== [server_pid], which is spawned as a session
   leader so its whole group is ours). codex app-server can hold the listener in
   a worker child within that group, so ownership is a group property, not a
   single-pid one. Parses /proc/net/tcp{,6} for the listening inode(s), then
   confirms one appears in the fd table of some pid whose pgrp is [server_pid].
   Once our server holds the bound socket no same-UID process can rebind the
   port, so this is a race-free proof the endpoint is ours (defeats the
   allocate-then-bind impersonation race). Fail-closed. *)
let real_verify_owner (ep : endpoint) ~(server_pid : int) : bool =
  let port_hex = Printf.sprintf "%04X" ep.port in
  let listen_inodes_from file =
    let acc = ref [] in
    (try
       let ic = open_in file in
       Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
         (try ignore (input_line ic) with End_of_file -> ());
         try
           while true do
             let line = input_line ic in
             let f = List.filter (fun s -> s <> "") (String.split_on_char ' ' line) in
             match f with
             | _sl :: local :: _rem :: st :: _ ->
                 (* local is ADDR:PORThex; LISTEN state is 0A. Match on port +
                    LISTEN; group-ownership below is the authoritative filter. *)
                 let matches_port =
                   match String.rindex_opt local ':' with
                   | Some ci -> String.uppercase_ascii (String.sub local (ci + 1) (String.length local - ci - 1)) = port_hex
                   | None -> false
                 in
                 if st = "0A" && matches_port then
                   (match List.nth_opt f 9 with Some ino -> acc := ino :: !acc | None -> ())
             | _ -> ()
           done
         with End_of_file -> ())
     with _ -> ());
    !acc
  in
  let inos = listen_inodes_from "/proc/net/tcp" @ listen_inodes_from "/proc/net/tcp6" in
  match inos with
  | [] -> false
  | inos ->
      let socket_links = List.map (fun ino -> Printf.sprintf "socket:[%s]" ino) inos in
      let pid_holds_listener pid =
        let fddir = Printf.sprintf "/proc/%d/fd" pid in
        try
          Array.exists
            (fun e ->
              match (try Some (Unix.readlink (fddir // e)) with _ -> None) with
              | Some target -> List.mem target socket_links
              | None -> false)
            (Sys.readdir fddir)
        with _ -> false
      in
      (* Pids in our server's process group (server_pid is the group leader). *)
      let our_group_pids =
        try
          Sys.readdir "/proc" |> Array.to_list
          |> List.filter_map (fun e -> int_of_string_opt e)
          |> List.filter (fun pid -> pid = server_pid || proc_pgrp pid = Some server_pid)
        with _ -> [ server_pid ]
      in
      List.exists pid_holds_listener our_group_pids

(* --------------------------------------------------------------------------- *)
(* Backend (injectable effect seam)                                            *)
(* --------------------------------------------------------------------------- *)

type ready_error =
  | Re_unauthorized     (* our own correct token was rejected — auth setup bug *)
  | Re_not_yet          (* server not reachable yet / transient — keep polling *)
  | Re_server_gone      (* connection refused after the server had bound *)

type backend = {
  now : unit -> float;
  sleep : float -> unit;
  gen_token : unit -> string;                          (* raw hex token *)
  alloc_port : unit -> (int, string) result;           (* free loopback port *)
  codex_version : string -> (string, string) result;   (* arg: codex_bin; raw --version stdout *)
  capabilities : string -> (unit, string) result;      (* arg: codex_bin; Ok if required flags present *)
  spawn_server : argv:string array -> env:string array -> log_path:string -> (child, string) result;
  spawn_frontend : argv:string array -> env:string array -> (child, string) result;
  probe_ready : endpoint -> token:string -> (unit, ready_error) result;
  verify_owner : endpoint -> server_pid:int -> bool;   (* listener owned by our server pid? *)
}

(* --------------------------------------------------------------------------- *)
(* Real backend                                                                *)
(* --------------------------------------------------------------------------- *)

(* [group_leader]: real server children are spawned as their own session leaders
   (setsid) so the WHOLE process group (server + any helpers) is reaped via
   killpg. The frontend is NOT a group leader (it needs the controlling tty), so
   it is signalled by pid. *)
let make_real_child ?(group_leader = false) (pid : int) : child =
  let status = ref None in
  let kill_target s =
    if group_leader then (try Unix.kill (- pid) s with _ -> (try Unix.kill pid s with _ -> ()))
    else (try Unix.kill pid s with _ -> ())
  in
  let poll () =
    match !status with
    | Some s -> s
    | None -> (
        match Unix.waitpid [ Unix.WNOHANG ] pid with
        | 0, _ -> Running_
        | _, Unix.WEXITED c -> status := Some (Exited c); Exited c
        | _, Unix.WSIGNALED s -> status := Some (Signaled s); Signaled s
        | _, Unix.WSTOPPED _ -> Running_
        | exception Unix.Unix_error (Unix.ECHILD, _, _) ->
            let s = Exited 0 in status := Some s; s
        | exception _ -> Running_)
  in
  let signal_ s = match !status with Some _ -> () | None -> kill_target s in
  let reap timeout =
    match !status with
    | Some s -> s
    | None ->
        kill_target Sys.sigterm;
        let deadline = Unix.gettimeofday () +. timeout in
        let rec loop () =
          match poll () with
          | Running_ ->
              if Unix.gettimeofday () < deadline then (
                (try ignore (Unix.select [] [] [] 0.05) with _ -> ());
                loop ())
              else begin
                kill_target Sys.sigkill;
                (match poll () with
                 | Running_ ->
                     (try
                        (match Unix.waitpid [] pid with
                         | _, Unix.WEXITED c -> status := Some (Exited c)
                         | _, Unix.WSIGNALED s -> status := Some (Signaled s)
                         | _ -> status := Some (Signaled Sys.sigkill))
                      with _ -> status := Some (Signaled Sys.sigkill));
                     (match !status with Some s -> s | None -> Signaled Sys.sigkill)
                 | s -> s)
              end
          | s -> s
        in
        loop ()
  in
  { child_id = pid; poll_fn = poll; signal_fn = signal_; reap_fn = reap }

let real_alloc_port () : (int, string) result =
  try
    let fd = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () -> try Unix.close fd with _ -> ())
      (fun () ->
        Unix.setsockopt fd Unix.SO_REUSEADDR true;
        Unix.bind fd (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
        match Unix.getsockname fd with
        | Unix.ADDR_INET (_, port) -> Ok port
        | _ -> Error "getsockname did not return an inet port")
  with e -> Error (Printexc.to_string e)

let capture_cmd (cmd : string) : (string, string) result =
  try
    let ic = Unix.open_process_in cmd in
    let buf = Buffer.create 256 in
    (try while true do Buffer.add_channel buf ic 1 done with End_of_file -> ());
    (match Unix.close_process_in ic with
     | Unix.WEXITED 0 -> Ok (Buffer.contents buf)
     | _ -> Error (Printf.sprintf "command exited non-zero: %s" cmd))
  with e -> Error (Printexc.to_string e)

let real_codex_version (codex_bin : string) : (string, string) result =
  match capture_cmd (Filename.quote codex_bin ^ " --version 2>/dev/null") with
  | Ok out ->
      let line = try List.hd (String.split_on_char '\n' out) with _ -> "" in
      if String.trim line <> "" then Ok (String.trim line)
      else Error "codex --version produced no output"
  | Error e -> Error e

(* Verify the installed codex exposes the exact surface T001 proved: app-server
   auth flags + the remote-attach flags. A version bump that drops/renames any of
   these yields a pre-frontend structured diagnostic instead of a generic
   spawn/readiness failure. *)
let real_capabilities (codex_bin : string) : (unit, string) result =
  let contains hay need =
    let nl = String.length need and hl = String.length hay in
    if nl = 0 then true
    else
      let rec go i = if i + nl > hl then false
        else if String.sub hay i nl = need then true else go (i + 1) in
      go 0
  in
  match capture_cmd (Filename.quote codex_bin ^ " app-server --help 2>/dev/null"),
        capture_cmd (Filename.quote codex_bin ^ " --help 2>/dev/null") with
  | Ok as_help, Ok top_help ->
      let need_as = [ "--listen"; "--ws-auth"; "--ws-token-sha256" ] in
      let need_top = [ "--remote"; "--remote-auth-token-env" ] in
      let missing =
        List.filter (fun f -> not (contains as_help f)) need_as
        @ List.filter (fun f -> not (contains top_help f)) need_top
      in
      if missing = [] then Ok ()
      else Error ("codex is missing required app-server capabilities: " ^ String.concat ", " missing)
  | Error e, _ | _, Error e -> Error ("could not probe codex capabilities: " ^ e)

let devnull_fd () = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0o600

(* Spawn as a new session leader (setsid) with the given stdio, searching PATH
   for [argv.(0)] and using [env]. Returns the child pid (== process-group id).
   Used for the headless server so its whole group can be reaped. *)
let spawn_session_leader ~(argv : string array) ~(env : string array)
    ~(stdin_fd : Unix.file_descr) ~(stdout_fd : Unix.file_descr) ~(stderr_fd : Unix.file_descr) : int =
  match Unix.fork () with
  | 0 ->
      (try
         ignore (Unix.setsid ());
         if stdin_fd <> Unix.stdin then Unix.dup2 stdin_fd Unix.stdin;
         if stdout_fd <> Unix.stdout then Unix.dup2 stdout_fd Unix.stdout;
         if stderr_fd <> Unix.stderr then Unix.dup2 stderr_fd Unix.stderr;
         Unix.execvpe argv.(0) argv env
       with _ -> (try Unix.write_substring Unix.stderr "exec failed\n" 0 12 |> ignore with _ -> ());
                 exit 127)
  | pid -> pid

let real_spawn_server ~(argv : string array) ~(env : string array) ~(log_path : string) :
    (child, string) result =
  let din = ref None and logfd = ref None in
  Fun.protect
    ~finally:(fun () ->
      (match !din with Some fd -> (try Unix.close fd with _ -> ()) | None -> ());
      (match !logfd with Some fd -> (try Unix.close fd with _ -> ()) | None -> ()))
    (fun () ->
      try
        let d = devnull_fd () in din := Some d;
        let l = Unix.openfile log_path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
        logfd := Some l;
        let pid = spawn_session_leader ~argv ~env ~stdin_fd:d ~stdout_fd:l ~stderr_fd:l in
        Ok (make_real_child ~group_leader:true pid)
      with e -> Error (Printexc.to_string e))

let real_spawn_frontend ~(argv : string array) ~(env : string array) : (child, string) result =
  try
    (* Frontend inherits the launcher's stdio so the TUI attaches to the
       controlling terminal / tmux pane. NOT a session leader (that would detach
       the controlling tty and break the interactive TUI); reaped by pid. *)
    let pid = Unix.create_process_env argv.(0) argv env Unix.stdin Unix.stdout Unix.stderr in
    Ok (make_real_child ~group_leader:false pid)
  with e -> Error (Printexc.to_string e)

let real_probe_ready (ep : endpoint) ~(token : string) : (unit, ready_error) result =
  match handshake ep ~token:(Some token) with
  | Hs_ready -> Ok ()
  | Hs_unauthorized -> Error Re_unauthorized
  | Hs_refused -> Error Re_server_gone
  | Hs_status _ | Hs_error _ -> Error Re_not_yet

let real_backend () : backend =
  {
    now = Unix.gettimeofday;
    sleep = (fun s -> try Unix.sleepf s with _ -> ());
    gen_token = (fun () -> ensure_rng (); hex_of_bytes (Mirage_crypto_rng.generate 32));
    alloc_port = real_alloc_port;
    codex_version = real_codex_version;
    capabilities = real_capabilities;
    spawn_server = real_spawn_server;
    spawn_frontend = real_spawn_frontend;
    probe_ready = real_probe_ready;
    verify_owner = real_verify_owner;
  }

(* --------------------------------------------------------------------------- *)
(* Config                                                                      *)
(* --------------------------------------------------------------------------- *)

type config = {
  cwd : string;
  codex_bin : string;
  instance_name : string;
  alias : string option;
  instance_dir : string;
  readiness_timeout_s : float;
  reap_timeout_s : float;
  min_codex_version : int * int * int;
  extra_server_args : string list;
  extra_frontend_args : string list;
  (* Non-secret, launcher-owned identity/context variables intended only for
     the remote Codex frontend.  Keep these out of the app-server process: the
     server needs only its capability-token hash. *)
  frontend_env : string list;
  resume_thread : string option;
}

let default_config ~instance_name ~instance_dir ~cwd =
  {
    cwd; codex_bin = "codex"; instance_name; alias = None; instance_dir;
    readiness_timeout_s = 30.0; reap_timeout_s = 5.0; min_codex_version = (0, 144, 0);
    extra_server_args = []; extra_frontend_args = []; frontend_env = [];
    resume_thread = None;
  }

(* --------------------------------------------------------------------------- *)
(* Persisted (non-secret) identity                                             *)
(* --------------------------------------------------------------------------- *)

type persisted = {
  unit_id : string;
  instance_name : string;
  alias : string option;
  codex_version : string;
  endpoint : endpoint;
  token_env_var : string;      (* NAME only — never the value *)
  token_sha256 : string;       (* digest only — reveals nothing *)
  server_pid : int option;
  frontend_pid : int option;
  thread_id : string option;   (* filled by T003/T006 once a thread is loaded; None here *)
  state : state;
  created_at : float;
  updated_at : float;
}

let persisted_to_json (p : persisted) : Yojson.Safe.t =
  `Assoc
    ([ ("unit_id", `String p.unit_id); ("instance_name", `String p.instance_name) ]
     @ (match p.alias with Some a -> [ ("alias", `String a) ] | None -> [])
     @ [ ("codex_version", `String p.codex_version)
       ; ("endpoint", endpoint_to_json p.endpoint)
       ; ("token_env_var", `String p.token_env_var)
       ; ("token_sha256", `String p.token_sha256) ]
     @ (match p.server_pid with Some x -> [ ("server_pid", `Int x) ] | None -> [])
     @ (match p.frontend_pid with Some x -> [ ("frontend_pid", `Int x) ] | None -> [])
     @ (match p.thread_id with Some x -> [ ("thread_id", `String x) ] | None -> [])
     @ [ ("state", `String (state_to_string p.state))
       ; ("created_at", `Float p.created_at); ("updated_at", `Float p.updated_at) ])

let persisted_of_json (j : Yojson.Safe.t) : persisted option =
  match j with
  | `Assoc a ->
      let s k = match List.assoc_opt k a with Some (`String v) -> Some v | _ -> None in
      let i k = match List.assoc_opt k a with Some (`Int v) -> Some v | _ -> None in
      let f k = match List.assoc_opt k a with
        | Some (`Float v) -> Some v | Some (`Int v) -> Some (float_of_int v) | _ -> None in
      let req_s k = match s k with Some v -> v | None -> raise Not_found in
      (try
         let endpoint = match List.assoc_opt "endpoint" a with
           | Some j -> (match endpoint_of_json j with Some e -> e | None -> raise Not_found)
           | None -> raise Not_found in
         Some {
           unit_id = req_s "unit_id"; instance_name = req_s "instance_name"; alias = s "alias";
           codex_version = req_s "codex_version"; endpoint;
           token_env_var = req_s "token_env_var"; token_sha256 = req_s "token_sha256";
           server_pid = i "server_pid"; frontend_pid = i "frontend_pid"; thread_id = s "thread_id";
           state = (match s "state" with Some v -> state_of_string v | None -> Offline);
           created_at = (match f "created_at" with Some v -> v | None -> 0.0);
           updated_at = (match f "updated_at" with Some v -> v | None -> 0.0);
         }
       with Not_found -> None)
  | _ -> None

let persisted_path ~(instance_dir : string) : string = instance_dir // "codex-app-server.json"

let write_persisted ~(instance_dir : string) (p : persisted) : (unit, string) result =
  (try if not (Sys.file_exists instance_dir) then Unix.mkdir instance_dir 0o700 with _ -> ());
  let path = persisted_path ~instance_dir in
  let content = Yojson.Safe.pretty_to_string (persisted_to_json p) ^ "\n" in
  C2c_io.write_file_atomic path content

let load_persisted ~(instance_dir : string) : persisted option =
  let path = persisted_path ~instance_dir in
  if not (Sys.file_exists path) then None
  else match C2c_io.read_json_opt path with Some j -> persisted_of_json j | None -> None

(* --------------------------------------------------------------------------- *)
(* Stale-state recovery                                                        *)
(* --------------------------------------------------------------------------- *)

(* A restart must NEVER silently attach to an endpoint whose ownership/credential
   cannot be verified. The raw capability token is memory-only, so a fresh
   process that loads {!persisted} does NOT possess it and cannot prove ownership
   of a still-running server. The only safe recovery is to start fresh (after
   best-effort reaping any recorded process we can positively identify as ours). *)
type recovery = Start_fresh of string

(* A recorded pid is only ours if it is alive AND its /proc cmdline still looks
   like the codex process we launched for THIS endpoint (guards against PID
   reuse killing an unrelated same-UID process — findings #2). *)
let recorded_pid_is_ours (p : persisted) ~(pid : int) : bool =
  pid > 1 && pid_alive pid
  && (match read_proc_cmdline pid with
      | Some cmd ->
          let has s =
            let nl = String.length s and hl = String.length cmd in
            if nl = 0 then true else
              let rec go i = if i + nl > hl then false
                else if String.sub cmd i nl = s then true else go (i + 1) in go 0
          in
          (* server: `codex ... app-server ... ws://127.0.0.1:<port>` ;
             frontend: `codex ... --remote ws://127.0.0.1:<port>` *)
          has "codex" && has (endpoint_uri p.endpoint)
      | None -> false)

let classify_persisted ?(reap_recorded = true) (p : persisted) : recovery =
  if reap_recorded then begin
    let try_kill = function
      | Some pid when recorded_pid_is_ours p ~pid -> (try Unix.kill pid Sys.sigterm with _ -> ())
      | _ -> ()
    in
    try_kill p.frontend_pid;   (* frontend before server *)
    try_kill p.server_pid
  end;
  Start_fresh
    "capability token is memory-only; a recovering process cannot verify \
     ownership/credential of the persisted endpoint — starting fresh"

(* --------------------------------------------------------------------------- *)
(* Handle                                                                      *)
(* --------------------------------------------------------------------------- *)

type handle = {
  cfg : config;
  bk : backend;
  h_unit_id : string;
  h_endpoint : endpoint;
  h_token_env_var : string;
  h_token_sha256 : string;
  mutable h_raw_token : string;    (* memory-only secret; scrubbed on stop *)
  mutable h_server : child option;
  mutable h_frontend : child option;
  mutable h_state : state;
  mutable h_lock_fd : Unix.file_descr option;
  h_codex_version : string;
  h_created_at : float;
}

let current_state (h : handle) = h.h_state
let endpoint_of (h : handle) = h.h_endpoint
let unit_id_of (h : handle) = h.h_unit_id
let token_env_var_of (h : handle) = h.h_token_env_var
let token_sha256_of (h : handle) = h.h_token_sha256

(* Memory-only capability token accessor. The raw token already lives ONLY in
   this launcher process's memory (see the auth-boundary contract at the top of
   this module); returning it to an IN-PROCESS caller (the B131 deliver loop that
   drives T003 ingress + T007 turns over the authenticated control seam) does not
   widen the boundary — the secret never touches argv, disk, logs, or the
   persisted/status JSON. Returns "" after {!stop} scrubs it. The caller must
   pull it per-use (via a token_provider thunk) and never persist it. *)
let raw_token_of (h : handle) : string = h.h_raw_token

let persisted_of (h : handle) : persisted =
  {
    unit_id = h.h_unit_id; instance_name = h.cfg.instance_name; alias = h.cfg.alias;
    codex_version = h.h_codex_version; endpoint = h.h_endpoint;
    token_env_var = h.h_token_env_var; token_sha256 = h.h_token_sha256;
    server_pid = Option.map (fun c -> c.child_id) h.h_server;
    frontend_pid = Option.map (fun c -> c.child_id) h.h_frontend;
    thread_id = None; state = h.h_state; created_at = h.h_created_at; updated_at = h.bk.now ();
  }

(* --------------------------------------------------------------------------- *)
(* argv / env construction                                                     *)
(* --------------------------------------------------------------------------- *)

(* Server argv carries ONLY the sha256 of the token — never the raw token. *)
let build_server_argv (cfg : config) (ep : endpoint) ~(sha256 : string) : string array =
  Array.of_list
    ([ cfg.codex_bin; "app-server"; "--listen"; endpoint_uri ep;
       "--ws-auth"; "capability-token"; "--ws-token-sha256"; sha256 ]
     @ cfg.extra_server_args)

(* Frontend argv carries ONLY the env-var NAME — the raw token is passed via the
   child environment (see {!build_frontend_env}), never argv. *)
let build_frontend_argv (cfg : config) (ep : endpoint) ~(token_env_var : string) : string array =
  let command = match cfg.resume_thread with
    | Some thread when String.trim thread <> "" -> [ cfg.codex_bin; "resume"; thread ]
    | _ -> [ cfg.codex_bin ]
  in
  Array.of_list
    (command @ [ "--remote"; endpoint_uri ep; "--remote-auth-token-env"; token_env_var ]
     @ cfg.extra_frontend_args)

(* Frontend env = current process env plus launcher-provided frontend-only
   overrides and the raw token.  Later values replace inherited values by key;
   this prevents an ambient parent C2C_MCP_SESSION_ID from stealing the managed
   frontend's identity.  The raw token remains frontend-only. *)
let build_frontend_env ~(extra_env : string list) ~(token_env_var : string) ~(raw_token : string)
    : string array =
  let key kv =
    match String.index_opt kv '=' with Some i -> String.sub kv 0 i | None -> kv
  in
  let overrides = extra_env @ [ Printf.sprintf "%s=%s" token_env_var raw_token ] in
  let overridden = List.map key overrides in
  let inherited =
    Unix.environment () |> Array.to_list
    |> List.filter (fun kv -> not (List.mem (key kv) overridden))
  in
  Array.of_list (inherited @ overrides)

let build_server_env () : string array = Unix.environment ()

(* --------------------------------------------------------------------------- *)
(* Cleanup helpers                                                             *)
(* --------------------------------------------------------------------------- *)

let scrub_token (h : handle) = h.h_raw_token <- ""

let release_lock (h : handle) =
  match h.h_lock_fd with
  | Some fd -> (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ()); (try Unix.close fd with _ -> ());
               h.h_lock_fd <- None
  | None -> ()

let persist_best_effort (h : handle) = ignore (write_persisted ~instance_dir:h.cfg.instance_dir (persisted_of h))

let reap_server (h : handle) =
  match h.h_server with Some c -> ignore (child_reap ~timeout:h.cfg.reap_timeout_s c) | None -> ()
let reap_frontend (h : handle) =
  match h.h_frontend with Some c -> ignore (child_reap ~timeout:h.cfg.reap_timeout_s c) | None -> ()

(* --------------------------------------------------------------------------- *)
(* start                                                                       *)
(* --------------------------------------------------------------------------- *)

let mk_diag ?codex_version ?min_codex_version code message =
  { code; message; codex_version; min_codex_version }

(* Wait until the authed handshake succeeds, the server child dies, or the
   readiness deadline passes. *)
let wait_ready (bk : backend) (ep : endpoint) ~(raw_token : string) ~(server : child)
    ~(timeout : float) : (unit, [ `Timeout | `Server_died | `Auth ]) result =
  let deadline = bk.now () +. timeout in
  let rec loop () =
    match child_poll server with
    | Exited _ | Signaled _ -> Error `Server_died
    | Running_ -> (
        match bk.probe_ready ep ~token:raw_token with
        | Ok () -> Ok ()
        | Error Re_unauthorized -> Error `Auth
        | Error (Re_not_yet | Re_server_gone) ->
            if bk.now () >= deadline then Error `Timeout else (bk.sleep 0.1; loop ()))
  in
  loop ()

let acquire_instance_lock (instance_dir : string) : Unix.file_descr option =
  (try if not (Sys.file_exists instance_dir) then Unix.mkdir instance_dir 0o700 with _ -> ());
  try
    let fd = Unix.openfile (instance_dir // "codex-app-server.lock")
               [ Unix.O_CREAT; Unix.O_RDWR; Unix.O_CLOEXEC ] 0o600 in
    (try Unix.lockf fd Unix.F_TLOCK 0; Some fd
     with _ -> (try Unix.close fd with _ -> ()); None)
  with _ -> None

let start ?(backend = real_backend ()) (cfg : config) : (handle, diagnostic) result =
  let bk = backend in
  let unit_id = Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ()) in
  let token_env_var = token_env_var_name unit_id in
  let created_at = bk.now () in
  let min_str = version_triple_to_string cfg.min_codex_version in
  let fail_early ?codex_version code msg = Error (mk_diag ?codex_version ~min_codex_version:min_str code msg) in
  (* Version gate FIRST — before any spawn. *)
  match bk.codex_version cfg.codex_bin with
  | Error e -> fail_early Codex_not_found (Printf.sprintf "could not run 'codex --version': %s" e)
  | Ok ver -> (
      match parse_version ver with
      | None -> fail_early ~codex_version:ver Codex_version_unsupported
                  (Printf.sprintf "could not parse codex version from %S" ver)
      | Some v when not (version_ge v cfg.min_codex_version) ->
          fail_early ~codex_version:ver Codex_version_unsupported
            (Printf.sprintf "codex %s is below the minimum supported %s" (version_triple_to_string v) min_str)
      | Some _ -> (
          (* Capability gate — the required flags must exist, else fail before spawn. *)
          match bk.capabilities cfg.codex_bin with
          | Error e -> fail_early ~codex_version:ver Codex_capability_unsupported e
          | Ok () -> (
              (* Recover any prior unit for this instance BEFORE we overwrite state.
                 A recovering process cannot re-authenticate, so classify_persisted
                 tears the old pair down (never attaches). *)
              (match load_persisted ~instance_dir:cfg.instance_dir with
               | Some prior -> ignore (classify_persisted prior)
               | None -> ());
              let lock = acquire_instance_lock cfg.instance_dir in
              match bk.alloc_port () with
              | Error e ->
                  (match lock with Some fd -> (try Unix.close fd with _ -> ()) | None -> ());
                  Error (mk_diag ~codex_version:ver ~min_codex_version:min_str Endpoint_alloc_failed
                           (Printf.sprintf "could not allocate a loopback port: %s" e))
              | Ok port -> (
                  let ep = { transport = "ws"; host = "127.0.0.1"; port } in
                  let raw_token = bk.gen_token () in
                  let sha256 = sha256_hex raw_token in
                  let h = {
                    cfg; bk; h_unit_id = unit_id; h_endpoint = ep;
                    h_token_env_var = token_env_var; h_token_sha256 = sha256;
                    h_raw_token = raw_token; h_server = None; h_frontend = None;
                    h_state = Allocating; h_lock_fd = lock; h_codex_version = ver;
                    h_created_at = created_at;
                  } in
                  let fail code msg =
                    h.h_state <- Failed; persist_best_effort h;
                    h.h_state <- Cleaning_up; reap_frontend h; reap_server h; scrub_token h;
                    h.h_state <- Offline; persist_best_effort h; release_lock h;
                    Error (mk_diag ~codex_version:ver ~min_codex_version:min_str code msg)
                  in
                  h.h_state <- Starting_server; persist_best_effort h;
                  let server_argv = build_server_argv cfg ep ~sha256 in
                  let server_env = build_server_env () in
                  let log_path = persisted_path ~instance_dir:cfg.instance_dir ^ ".appserver.log" in
                  match bk.spawn_server ~argv:server_argv ~env:server_env ~log_path with
                  | Error e -> fail Server_spawn_failed (Printf.sprintf "app-server spawn failed: %s" e)
                  | Ok server ->
                      h.h_server <- Some server; persist_best_effort h;
                      h.h_state <- Waiting_ready; persist_best_effort h;
                      (match wait_ready bk ep ~raw_token ~server ~timeout:cfg.readiness_timeout_s with
                       | Error `Timeout -> fail Readiness_timeout
                           (Printf.sprintf "app-server did not become ready within %.1fs" cfg.readiness_timeout_s)
                       | Error `Server_died -> fail Server_died_before_ready "app-server exited before becoming ready"
                       | Error `Auth -> fail Auth_setup_failed
                           "app-server rejected the launcher's own capability token (auth setup error)"
                       | Ok () ->
                           (* Startup-race gate: prove the listener is OUR server's
                              before handing the frontend the bearer token. Also
                              re-check the server is still alive. *)
                           if (match child_poll server with Running_ -> false | _ -> true) then
                             fail Server_died_before_ready "app-server exited immediately after readiness"
                           else if not (bk.verify_owner ep ~server_pid:server.child_id) then
                             fail Endpoint_ownership_unverified
                               "endpoint listener is not owned by the launched app-server (possible port race); refusing to attach frontend"
                           else begin
                             h.h_state <- Starting_frontend; persist_best_effort h;
                             let fe_argv = build_frontend_argv cfg ep ~token_env_var in
                             let fe_env =
                               build_frontend_env ~extra_env:cfg.frontend_env
                                 ~token_env_var ~raw_token
                             in
                             match bk.spawn_frontend ~argv:fe_argv ~env:fe_env with
                             | Error e -> fail Frontend_spawn_failed (Printf.sprintf "frontend spawn failed: %s" e)
                             | Ok frontend ->
                                 h.h_frontend <- Some frontend;
                                 h.h_state <- Running;
                                 (* The Running mapping is the durable record used
                                    for later orphan cleanup — it MUST persist. *)
                                 (match write_persisted ~instance_dir:cfg.instance_dir (persisted_of h) with
                                  | Ok () -> Ok h
                                  | Error e -> fail Persistence_failed
                                      (Printf.sprintf "could not persist running unit state: %s" e))
                           end)))))

(* --------------------------------------------------------------------------- *)
(* Supervision + stop                                                          *)
(* --------------------------------------------------------------------------- *)

type supervise_result = Sv_running | Sv_frontend_exited | Sv_server_died | Sv_offline

(* Bring the whole unit down: reap frontend then server, scrub the token, release
   the lock, mark Offline, persist. Idempotent — a second call is a no-op. *)
let stop (h : handle) : unit =
  match h.h_state with
  | Offline -> ()
  | _ ->
      h.h_state <- Stopping_server;
      reap_frontend h; reap_server h; scrub_token h;
      h.h_state <- Offline; persist_best_effort h; release_lock h

(* One nonblocking supervision step. T006 wires this (or {!supervise_until_exit})
   into its managed supervision loop and routes parent SIGTERM/SIGINT to {!stop}. *)
let supervise_step (h : handle) : supervise_result =
  match h.h_state with
  | Offline -> Sv_offline
  | Running -> (
      let fe_status = match h.h_frontend with Some c -> child_poll c | None -> Exited 0 in
      match fe_status with
      | Exited _ | Signaled _ ->
          h.h_state <- Frontend_exited;
          h.h_state <- Stopping_server; reap_server h; scrub_token h;
          h.h_state <- Offline; persist_best_effort h; release_lock h;
          Sv_frontend_exited
      | Running_ -> (
          let sv_status = match h.h_server with Some c -> child_poll c | None -> Exited 0 in
          match sv_status with
          | Exited _ | Signaled _ ->
              h.h_state <- Failed;
              h.h_state <- Cleaning_up; reap_frontend h; scrub_token h;
              h.h_state <- Offline; persist_best_effort h; release_lock h;
              Sv_server_died
          | Running_ -> Sv_running))
  | _ -> stop h; Sv_offline

(* Self-contained supervision loop: installs SIGTERM/SIGINT -> stop, then polls
   until the unit is terminal (frontend exit / server death) or [max_wall_s]
   passes. [on_transition] observes each non-running result. This makes the
   primitive self-contained for the dogfood and any simple caller; T006 may
   instead drive {!supervise_step} inside its own managed loop. *)
let supervise_until_exit ?(poll_interval_s = 0.5) ?(max_wall_s = infinity)
    ?(on_transition = fun _ -> ()) (h : handle) : supervise_result =
  let prev_term = Sys.signal Sys.sigterm (Sys.Signal_handle (fun _ -> stop h; exit 0)) in
  let prev_int = Sys.signal Sys.sigint (Sys.Signal_handle (fun _ -> stop h; exit 0)) in
  let restore () =
    (try Sys.set_signal Sys.sigterm prev_term with _ -> ());
    (try Sys.set_signal Sys.sigint prev_int with _ -> ())
  in
  Fun.protect ~finally:restore (fun () ->
      let deadline = h.bk.now () +. max_wall_s in
      let rec loop () =
        match supervise_step h with
        | Sv_running ->
            if h.bk.now () >= deadline then (stop h; Sv_offline)
            else (h.bk.sleep poll_interval_s; loop ())
        | other -> on_transition other; other
      in
      loop ())
