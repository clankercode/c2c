(* c2c_codex_app_server — internal app-server-backed Codex session launcher
   primitive (backlog P1.M1.E1.T002).

   OWNS one `codex app-server` (headless, authenticated loopback WebSocket) plus
   one stock `codex --remote` frontend as a SINGLE managed unit: endpoint
   allocation, capability-token auth setup, child spawning, verified readiness,
   supervision, exit propagation, cleanup, and the minimal NON-SECRET persisted
   mapping later tasks resume/deliver against.

   ===================================================================== OWNERSHIP
   This module is the internal lifecycle PRIMITIVE + SECURITY BOUNDARY only. It is
   wired into the build but is NOT exposed as a new public CLI. Boundaries for the
   sibling tasks that consume it:

   - T006 (public grammar) owns `c2c start codex`/`codex`/`new`/`resume`, alias
     generation/override, generated-name UX, `--yolo`, and flag forwarding. T006
     calls {!start}/{!supervise_step}/{!stop} and reads {!persisted}; it must NOT
     re-implement spawning/auth here. `thread_id` in {!persisted} is the field
     T006/T003 fill once a thread is loaded (this task leaves it [None]).
   - T003 (passive ingress) owns `thread/inject_items` delivery over the authed
     control channel. It must persist-first to the broker inbox and NEVER call
     `turn/*`. This module deliberately opens NO control JSON-RPC session and
     performs NO delivery — it only verifies readiness via the WS handshake.
   - T007 (policy-driven turns) owns any `turn/start`. This module never starts a
     turn and never reads message content.

   ================================================================ AUTH BOUNDARY
   The T001 spike proved (receipt: .collab/research/2026-07-11-t001-...): a bare
   loopback/unix listener has ZERO same-UID boundary (an unrelated same-UID
   process can `turn/start`, `fs/readFile`, `fs/writeFile` with no credential).
   The ONLY proven boundary is launching the app-server with
   `--ws-auth capability-token --ws-token-sha256 <sha>`: an unauthenticated /
   wrong-token client is rejected with HTTP 401 at the WebSocket handshake; a
   correct `Authorization: Bearer <token>` grants access.

   Secret flow (never weakened):
   - A fresh capability token is generated per unit (256 bits CSPRNG, hex).
   - The server receives ONLY its sha256 hex on the command line (`--ws-token-sha256`).
   - The frontend receives the RAW token via an ENV VAR named on the command line
     (`--remote-auth-token-env <ENVVAR>`); the value is placed only in the
     frontend child's environment — never in argv.
   - The raw token lives ONLY in this launcher process's memory and the frontend
     child's environment: never on disk, never in argv, never in logs, never in
     {!persisted}/{!diagnostic} JSON.
   - Because the raw token is memory-only, a *different* process that loads
     {!persisted} cannot authenticate to the recorded endpoint — so resume can
     NEVER silently attach to an unverifiable endpoint (see {!classify_persisted}).

   No TCP/non-loopback listener is ever created. The endpoint is always
   `ws://127.0.0.1:<port>`.

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
  | Endpoint_alloc_failed
  | Server_spawn_failed
  | Readiness_timeout
  | Server_died_before_ready
  | Auth_setup_failed
  | Frontend_spawn_failed
  | Internal_error

let diag_code_to_string = function
  | Codex_not_found -> "codex_not_found"
  | Codex_version_unsupported -> "codex_version_unsupported"
  | Endpoint_alloc_failed -> "endpoint_alloc_failed"
  | Server_spawn_failed -> "server_spawn_failed"
  | Readiness_timeout -> "readiness_timeout"
  | Server_died_before_ready -> "server_died_before_ready"
  | Auth_setup_failed -> "auth_setup_failed"
  | Frontend_spawn_failed -> "frontend_spawn_failed"
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

(* Parse a codex version string like "codex-cli 0.144.1" or "0.144.1" into a
   (major, minor, patch) triple. Extra suffixes (e.g. "-rc1") on patch are
   truncated to the leading integer. Returns None if no dotted triple found. *)
let parse_version (s : string) : (int * int * int) option =
  let s = String.trim s in
  (* isolate the last whitespace-separated token that looks like a version *)
  let toks = String.split_on_char ' ' s |> List.filter (fun t -> t <> "") in
  let cand = match List.rev toks with t :: _ -> t | [] -> s in
  let cand =
    (* strip a leading 'v' if present *)
    if String.length cand > 0 && (cand.[0] = 'v' || cand.[0] = 'V')
    then String.sub cand 1 (String.length cand - 1) else cand
  in
  let leading_int t =
    let b = Buffer.create 8 in
    (try
       String.iter (fun c -> if c >= '0' && c <= '9' then Buffer.add_char b c else raise Exit) t
     with Exit -> ());
    match int_of_string_opt (Buffer.contents b) with Some n -> Some n | None -> None
  in
  match String.split_on_char '.' cand with
  | maj :: min :: patch :: _ ->
      (match int_of_string_opt (String.trim maj), int_of_string_opt (String.trim min), leading_int (String.trim patch) with
       | Some a, Some b, Some c -> Some (a, b, c)
       | _ -> None)
  | maj :: [ min ] ->
      (match int_of_string_opt (String.trim maj), leading_int (String.trim min) with
       | Some a, Some b -> Some (a, b, 0)
       | _ -> None)
  | _ -> None

let version_ge (a : int * int * int) (b : int * int * int) : bool =
  let a1, a2, a3 = a and b1, b2, b3 = b in
  if a1 <> b1 then a1 > b1
  else if a2 <> b2 then a2 > b2
  else a3 >= b3

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
  if not !rng_initialized then begin
    Mirage_crypto_rng_unix.use_default ();
    rng_initialized := true
  end

(* Env var name that carries the raw bearer token into the frontend child. Only
   the NAME is ever persisted / logged; the value is set only in the frontend
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
  reap_fn : float -> child_status;  (* SIGTERM -> wait(timeout) -> SIGKILL; idempotent *)
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

(* Perform one WebSocket-upgrade handshake against [ep], optionally presenting a
   bearer [token]. We only read the HTTP status line — auth is decided by the
   server at the handshake (101 vs 401), so we never complete the upgrade. This
   is the SAME boundary the T001 probe proved; it is reused for readiness polling
   AND for the auth-rejection test (call with [token:None]). *)
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
          (* First line: "HTTP/1.1 NNN reason" *)
          let line =
            match String.index_opt resp '\r' with
            | Some i -> String.sub resp 0 i
            | None -> resp
          in
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
  codex_version : string -> (string, string) result;   (* arg: codex_bin; returns raw --version stdout *)
  spawn_server : argv:string array -> env:string array -> log_path:string -> (child, string) result;
  spawn_frontend : argv:string array -> env:string array -> (child, string) result;
  probe_ready : endpoint -> token:string -> (unit, ready_error) result;
}

(* --------------------------------------------------------------------------- *)
(* Real backend                                                                *)
(* --------------------------------------------------------------------------- *)

let make_real_child (pid : int) : child =
  let status = ref None in
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
            (* Already reaped elsewhere; treat as a clean exit. *)
            let s = Exited 0 in status := Some s; s
        | exception _ -> Running_)
  in
  let signal_ s = match !status with Some _ -> () | None -> (try Unix.kill pid s with _ -> ()) in
  let reap timeout =
    match !status with
    | Some s -> s
    | None ->
        signal_ Sys.sigterm;
        let deadline = Unix.gettimeofday () +. timeout in
        let rec loop () =
          match poll () with
          | Running_ ->
              if Unix.gettimeofday () < deadline then (
                (try ignore (Unix.select [] [] [] 0.05) with _ -> ());
                loop ())
              else begin
                (* escalate *)
                (try Unix.kill pid Sys.sigkill with _ -> ());
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

let real_codex_version (codex_bin : string) : (string, string) result =
  try
    let ic = Unix.open_process_in (Filename.quote codex_bin ^ " --version 2>/dev/null") in
    let line = try input_line ic with End_of_file -> "" in
    (match Unix.close_process_in ic with
     | Unix.WEXITED 0 when String.trim line <> "" -> Ok (String.trim line)
     | Unix.WEXITED 0 -> Error "codex --version produced no output"
     | _ -> Error "codex --version exited non-zero")
  with e -> Error (Printexc.to_string e)

let devnull_fd () = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0o600

let real_spawn_server ~(argv : string array) ~(env : string array) ~(log_path : string) :
    (child, string) result =
  try
    let din = devnull_fd () in
    let logfd = Unix.openfile log_path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
    let pid = Unix.create_process_env argv.(0) argv env din logfd logfd in
    (try Unix.close din with _ -> ());
    (try Unix.close logfd with _ -> ());
    Ok (make_real_child pid)
  with e -> Error (Printexc.to_string e)

let real_spawn_frontend ~(argv : string array) ~(env : string array) : (child, string) result =
  try
    (* Frontend inherits the launcher's stdio so the TUI attaches to the
       controlling terminal / tmux pane. *)
    let pid = Unix.create_process_env argv.(0) argv env Unix.stdin Unix.stdout Unix.stderr in
    Ok (make_real_child pid)
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
    spawn_server = real_spawn_server;
    spawn_frontend = real_spawn_frontend;
    probe_ready = real_probe_ready;
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
    ([ ("unit_id", `String p.unit_id)
     ; ("instance_name", `String p.instance_name) ]
     @ (match p.alias with Some a -> [ ("alias", `String a) ] | None -> [])
     @ [ ("codex_version", `String p.codex_version)
       ; ("endpoint", endpoint_to_json p.endpoint)
       ; ("token_env_var", `String p.token_env_var)
       ; ("token_sha256", `String p.token_sha256) ]
     @ (match p.server_pid with Some x -> [ ("server_pid", `Int x) ] | None -> [])
     @ (match p.frontend_pid with Some x -> [ ("frontend_pid", `Int x) ] | None -> [])
     @ (match p.thread_id with Some x -> [ ("thread_id", `String x) ] | None -> [])
     @ [ ("state", `String (state_to_string p.state))
       ; ("created_at", `Float p.created_at)
       ; ("updated_at", `Float p.updated_at) ])

let persisted_of_json (j : Yojson.Safe.t) : persisted option =
  match j with
  | `Assoc a ->
      let s k = match List.assoc_opt k a with Some (`String v) -> Some v | _ -> None in
      let i k = match List.assoc_opt k a with Some (`Int v) -> Some v | _ -> None in
      let f k =
        match List.assoc_opt k a with
        | Some (`Float v) -> Some v
        | Some (`Int v) -> Some (float_of_int v)
        | _ -> None
      in
      let req_s k = match s k with Some v -> v | None -> raise Not_found in
      (try
         let endpoint =
           match List.assoc_opt "endpoint" a with
           | Some j -> (match endpoint_of_json j with Some e -> e | None -> raise Not_found)
           | None -> raise Not_found
         in
         Some
           {
             unit_id = req_s "unit_id";
             instance_name = req_s "instance_name";
             alias = s "alias";
             codex_version = req_s "codex_version";
             endpoint;
             token_env_var = req_s "token_env_var";
             token_sha256 = req_s "token_sha256";
             server_pid = i "server_pid";
             frontend_pid = i "frontend_pid";
             thread_id = s "thread_id";
             state = (match s "state" with Some v -> state_of_string v | None -> Offline);
             created_at = (match f "created_at" with Some v -> v | None -> 0.0);
             updated_at = (match f "updated_at" with Some v -> v | None -> 0.0);
           }
       with Not_found -> None)
  | _ -> None

(* State file lives beside the managed instance config. *)
let persisted_path ~(instance_dir : string) : string =
  instance_dir // "codex-app-server.json"

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
   process that loads {!persisted} does NOT possess it and therefore CANNOT prove
   ownership of a still-running server. The only safe recovery is to start fresh
   (after best-effort reaping any recorded processes we can prove are ours). *)
type recovery =
  | Start_fresh of string   (* reason *)

let pid_alive (pid : int) : bool =
  try Unix.kill pid 0; true
  with Unix.Unix_error (Unix.ESRCH, _, _) -> false | _ -> false

(* Classify a loaded persisted record. Always returns Start_fresh: a recovering
   process cannot re-authenticate the old endpoint. [reap_recorded] best-effort
   terminates recorded pids that are still alive so we do not leak an orphaned,
   now-unowned app-server. *)
let classify_persisted ?(reap_recorded = true) (p : persisted) : recovery =
  if reap_recorded then begin
    let try_kill = function
      | Some pid when pid > 1 && pid_alive pid ->
          (try Unix.kill pid Sys.sigterm with _ -> ())
      | _ -> ()
    in
    (* Kill frontend before server so the frontend does not race a reconnect. *)
    try_kill p.frontend_pid;
    try_kill p.server_pid
  end;
  Start_fresh
    "capability token is memory-only; a recovering process cannot verify \
     ownership/credential of the persisted endpoint — starting fresh"

(* --------------------------------------------------------------------------- *)
(* Config + handle                                                             *)
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
}

let default_config ~instance_name ~instance_dir ~cwd =
  {
    cwd;
    codex_bin = "codex";
    instance_name;
    alias = None;
    instance_dir;
    readiness_timeout_s = 30.0;
    reap_timeout_s = 5.0;
    min_codex_version = (0, 144, 0);
    extra_server_args = [];
    extra_frontend_args = [];
  }

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
  h_created_at : float;
}

let current_state (h : handle) = h.h_state
let endpoint_of (h : handle) = h.h_endpoint
let unit_id_of (h : handle) = h.h_unit_id
let token_env_var_of (h : handle) = h.h_token_env_var
let token_sha256_of (h : handle) = h.h_token_sha256

let persisted_of (h : handle) : persisted =
  {
    unit_id = h.h_unit_id;
    instance_name = h.cfg.instance_name;
    alias = h.cfg.alias;
    codex_version = "";  (* overwritten by start with the probed version *)
    endpoint = h.h_endpoint;
    token_env_var = h.h_token_env_var;
    token_sha256 = h.h_token_sha256;
    server_pid = Option.map (fun c -> c.child_id) h.h_server;
    frontend_pid = Option.map (fun c -> c.child_id) h.h_frontend;
    thread_id = None;
    state = h.h_state;
    created_at = h.h_created_at;
    updated_at = h.bk.now ();
  }

(* --------------------------------------------------------------------------- *)
(* Server / frontend argv construction                                         *)
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
  Array.of_list
    ([ cfg.codex_bin; "--remote"; endpoint_uri ep;
       "--remote-auth-token-env"; token_env_var ]
     @ cfg.extra_frontend_args)

(* Frontend env = current process env + the raw token under [token_env_var]. This
   is the ONLY place the raw token is written outside launcher memory. *)
let build_frontend_env ~(token_env_var : string) ~(raw_token : string) : string array =
  let base = Unix.environment () in
  Array.append base [| Printf.sprintf "%s=%s" token_env_var raw_token |]

(* Server env is just the inherited environment; it needs no secret. *)
let build_server_env () : string array = Unix.environment ()

(* --------------------------------------------------------------------------- *)
(* Cleanup helpers                                                             *)
(* --------------------------------------------------------------------------- *)

let scrub_token (h : handle) = h.h_raw_token <- ""

let persist_state (h : handle) (v : string) =
  (* [v] is the codex version string to record (may be "" if unknown). *)
  let p = { (persisted_of h) with codex_version = v } in
  ignore (write_persisted ~instance_dir:h.cfg.instance_dir p)

(* Reap the app-server child if present. Idempotent. *)
let reap_server (h : handle) =
  (match h.h_server with Some c -> ignore (child_reap ~timeout:h.cfg.reap_timeout_s c) | None -> ())

let reap_frontend (h : handle) =
  (match h.h_frontend with Some c -> ignore (child_reap ~timeout:h.cfg.reap_timeout_s c) | None -> ())

(* --------------------------------------------------------------------------- *)
(* start                                                                       *)
(* --------------------------------------------------------------------------- *)

let mk_diag ?codex_version ?min_codex_version code message =
  { code; message; codex_version; min_codex_version }

(* Wait until the authed handshake succeeds (server up + our token accepted), the
   server child dies, or the readiness deadline passes. *)
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
            if bk.now () >= deadline then Error `Timeout
            else (bk.sleep 0.1; loop ()))
  in
  loop ()

let start ?(backend = real_backend ()) (cfg : config) : (handle, diagnostic) result =
  let bk = backend in
  let unit_id = Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ()) in
  let token_env_var = token_env_var_name unit_id in
  let created_at = bk.now () in
  (* State: Allocating — version gate FIRST, before any spawn. *)
  let fail_early code msg codex_version =
    Error (mk_diag ?codex_version
             ~min_codex_version:(version_triple_to_string cfg.min_codex_version) code msg)
  in
  match bk.codex_version cfg.codex_bin with
  | Error e -> fail_early Codex_not_found (Printf.sprintf "could not run 'codex --version': %s" e) None
  | Ok ver -> (
      match parse_version ver with
      | None ->
          fail_early Codex_version_unsupported
            (Printf.sprintf "could not parse codex version from %S" ver) (Some ver)
      | Some v when not (version_ge v cfg.min_codex_version) ->
          fail_early Codex_version_unsupported
            (Printf.sprintf "codex %s is below the minimum supported %s for the app-server launcher"
               (version_triple_to_string v) (version_triple_to_string cfg.min_codex_version))
            (Some ver)
      | Some _ -> (
          (* Allocate endpoint + auth material. *)
          match bk.alloc_port () with
          | Error e ->
              Error (mk_diag ~codex_version:ver Endpoint_alloc_failed
                       (Printf.sprintf "could not allocate a loopback port: %s" e))
          | Ok port -> (
              let ep = { transport = "ws"; host = "127.0.0.1"; port } in
              let raw_token = bk.gen_token () in
              let sha256 = sha256_hex raw_token in
              let h =
                {
                  cfg; bk; h_unit_id = unit_id; h_endpoint = ep;
                  h_token_env_var = token_env_var; h_token_sha256 = sha256;
                  h_raw_token = raw_token; h_server = None; h_frontend = None;
                  h_state = Allocating; h_created_at = created_at;
                }
              in
              (* Failure path shared by every post-alloc error: reap the server if
                 spawned, scrub the token, mark Offline, return a diagnostic. *)
              let fail code msg =
                h.h_state <- Failed;
                persist_state h ver;
                h.h_state <- Cleaning_up;
                reap_frontend h;
                reap_server h;
                scrub_token h;
                h.h_state <- Offline;
                persist_state h ver;
                Error (mk_diag ~codex_version:ver
                         ~min_codex_version:(version_triple_to_string cfg.min_codex_version) code msg)
              in
              (* Starting_server. *)
              h.h_state <- Starting_server;
              persist_state h ver;
              let server_argv = build_server_argv cfg ep ~sha256 in
              let server_env = build_server_env () in
              let log_path = persisted_path ~instance_dir:cfg.instance_dir ^ ".appserver.log" in
              (try if not (Sys.file_exists cfg.instance_dir) then Unix.mkdir cfg.instance_dir 0o700
               with _ -> ());
              match bk.spawn_server ~argv:server_argv ~env:server_env ~log_path with
              | Error e -> fail Server_spawn_failed (Printf.sprintf "app-server spawn failed: %s" e)
              | Ok server ->
                  h.h_server <- Some server;
                  persist_state h ver;
                  (* Waiting_ready. *)
                  h.h_state <- Waiting_ready;
                  persist_state h ver;
                  (match wait_ready bk ep ~raw_token ~server ~timeout:cfg.readiness_timeout_s with
                   | Error `Timeout ->
                       fail Readiness_timeout
                         (Printf.sprintf "app-server did not become ready within %.1fs" cfg.readiness_timeout_s)
                   | Error `Server_died ->
                       fail Server_died_before_ready "app-server exited before becoming ready"
                   | Error `Auth ->
                       fail Auth_setup_failed
                         "app-server rejected the launcher's own capability token (auth setup error)"
                   | Ok () ->
                       (* Starting_frontend. *)
                       h.h_state <- Starting_frontend;
                       persist_state h ver;
                       let fe_argv = build_frontend_argv cfg ep ~token_env_var in
                       let fe_env = build_frontend_env ~token_env_var ~raw_token in
                       (match bk.spawn_frontend ~argv:fe_argv ~env:fe_env with
                        | Error e ->
                            fail Frontend_spawn_failed (Printf.sprintf "frontend spawn failed: %s" e)
                        | Ok frontend ->
                            h.h_frontend <- Some frontend;
                            h.h_state <- Running;
                            persist_state h ver;
                            Ok h)))))

(* --------------------------------------------------------------------------- *)
(* Supervision + stop                                                          *)
(* --------------------------------------------------------------------------- *)

type supervise_result =
  | Sv_running
  | Sv_frontend_exited     (* frontend exited normally/by signal → unit stopped *)
  | Sv_server_died         (* app-server died while frontend ran → unit stopped *)
  | Sv_offline             (* already terminal *)

(* Bring the whole unit down: reap frontend then server, scrub the token, mark
   Offline, persist. Idempotent — a second call is a no-op. *)
let stop (h : handle) : unit =
  match h.h_state with
  | Offline -> ()
  | _ ->
      h.h_state <- Stopping_server;
      reap_frontend h;
      reap_server h;
      scrub_token h;
      h.h_state <- Offline;
      persist_state h ""

(* One nonblocking supervision step. T006 wires this into its managed supervision
   loop and routes parent SIGTERM/SIGINT to {!stop}. *)
let supervise_step (h : handle) : supervise_result =
  match h.h_state with
  | Offline -> Sv_offline
  | Running -> (
      let fe_status = match h.h_frontend with Some c -> child_poll c | None -> Exited 0 in
      match fe_status with
      | Exited _ | Signaled _ ->
          (* Frontend exit MUST always stop the server. *)
          h.h_state <- Frontend_exited;
          h.h_state <- Stopping_server;
          reap_server h;
          scrub_token h;
          h.h_state <- Offline;
          persist_state h "";
          Sv_frontend_exited
      | Running_ -> (
          let sv_status = match h.h_server with Some c -> child_poll c | None -> Exited 0 in
          match sv_status with
          | Exited _ | Signaled _ ->
              (* App-server death while the frontend runs terminates the unit. *)
              h.h_state <- Failed;
              h.h_state <- Cleaning_up;
              reap_frontend h;
              scrub_token h;
              h.h_state <- Offline;
              persist_state h "";
              Sv_server_died
          | Running_ -> Sv_running))
  | _ ->
      (* Any non-Running, non-Offline state under supervision: finish shutdown. *)
      stop h;
      Sv_offline
