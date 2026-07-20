(** Generic owner-control self-reexec restart seam (P2.M2.E1.T003 / I011).

    Generalizes the B153 Codex owner-control protocol so any managed owner
    process can accept a local-operator restart request in its original pane.

    This module is the PROTOCOL only:
    - request / result files under an instance directory
    - owner identity (name + pid + start-time) TOCTOU checks
    - controlled env filter (semantic c2c keys only; no ambient dump)
    - commit-then-ack discipline helpers

    Per-client adapters and [restart-stale] wiring live in G1/G2. Peer mail is
    DATA under B098 and never drives this seam. *)

type request =
  { id : string
  ; force : bool
  ; instance_name : string
  ; expected_pid : int option
  ; expected_start_time : int option
  ; requested_at : float
  }

type result_kind =
  | Restarting
  | Declined of string
  | Timed_out
  | Failed of string

type identity =
  { name : string
  ; pid : int
  ; start_time : int option
  }

type launch_plan =
  { executable : string
  ; argv : string array
  ; cwd : string option
  ; env : string array
  }

let ( // ) = Filename.concat

let request_path ~instance_dir = instance_dir // "owner-restart.request.json"
let result_path ~instance_dir ~request_id =
  instance_dir // ("owner-restart.result." ^ request_id ^ ".json")

let fresh_request_id () =
  Printf.sprintf "%d-%08x" (Unix.getpid ()) (Random.bits ())

let result_kind_to_string = function
  | Restarting -> "restarting"
  | Declined reason -> "declined:" ^ reason
  | Timed_out -> "timeout"
  | Failed reason -> "failed:" ^ reason

let result_kind_of_string = function
  | "restarting" -> Restarting
  | "timeout" -> Timed_out
  | s when String.length s > 9 && String.sub s 0 9 = "declined:" ->
      Declined (String.sub s 9 (String.length s - 9))
  | s when String.length s > 7 && String.sub s 0 7 = "failed:" ->
      Failed (String.sub s 7 (String.length s - 7))
  | other -> Failed ("unrecognized-result:" ^ other)

(** Controlled env keys that may pass through a self-reexec. Everything else
    from the ambient process environment is dropped (no secret dump). *)
let controlled_env_keys =
  [ "HOME"
  ; "USER"
  ; "LOGNAME"
  ; "PATH"
  ; "LANG"
  ; "LC_ALL"
  ; "LC_CTYPE"
  ; "TERM"
  ; "COLORTERM"
  ; "TMPDIR"
  ; "XDG_RUNTIME_DIR"
  ; "XDG_CONFIG_HOME"
  ; "XDG_DATA_HOME"
  ; "XDG_CACHE_HOME"
  ; "XDG_STATE_HOME"
  ; "C2C_STATE_HOME"
  ; "C2C_MCP_BROKER_ROOT"
  ; "C2C_SESSIONS_BROKER_ROOT"
  ; "C2C_CLI_COMMAND"
  ; "C2C_CODEX_FORCE_HOOKS"
  ; "C2C_KIMI_SERVER_PORT"
  ; "OPAM_SWITCH_PREFIX"
  ; "CAML_LD_LIBRARY_PATH"
  ]

let env_key e =
  try String.sub e 0 (String.index e '=') with Not_found -> e

let is_controlled_key k =
  (* Finite allowlist only — never a C2C_* wildcard. Credential-bearing
     ambient vars (C2C_RELAY_TOKEN, etc.) must not ride a self-reexec. *)
  List.exists (fun allowed -> String.equal allowed k) controlled_env_keys

(** Build a controlled environment from [source] (default: current env).
    Always strips [C2C_INSTANCE_NAME] so a re-exec of `c2c start` does not
    trip the nested-session guard. Only the finite [controlled_env_keys]
    allowlist survives — no C2C_* wildcard. *)
let filter_env ?(source = Unix.environment ()) () : string array =
  source
  |> Array.to_list
  |> List.filter (fun e ->
         let k = env_key e in
         k <> "C2C_INSTANCE_NAME" && is_controlled_key k)
  |> Array.of_list

let write_json_atomic path json =
  let tmp =
    path ^ ".tmp." ^ string_of_int (Unix.getpid ()) ^ "."
    ^ string_of_int (Random.bits ())
  in
  let oc = open_out tmp in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
      Yojson.Safe.to_channel oc json;
      output_string oc "\n");
  Unix.rename tmp path

let int_member name fields =
  match List.assoc_opt name fields with
  | Some (`Int i) -> Some i
  | Some (`Intlit s) -> (try Some (int_of_string s) with _ -> None)
  | _ -> None

let string_member name fields =
  match List.assoc_opt name fields with
  | Some (`String s) -> Some s
  | _ -> None

let bool_member name fields =
  match List.assoc_opt name fields with
  | Some (`Bool b) -> Some b
  | _ -> None

let float_member name fields =
  match List.assoc_opt name fields with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | _ -> None

(** Operator side: write a restart request for [instance_name]. Optional
    [expected_pid]/expected_start_time] pin the owner identity so a reused
    PID cannot satisfy the request later. *)
let request_restart ~instance_dir ~instance_name ~(force : bool)
    ~(expected_pid : int) ~(expected_start_time : int) () : string =
  C2c_io.mkdir_p instance_dir;
  let request_id = fresh_request_id () in
  let fields =
    [ ("request_id", `String request_id)
    ; ("force", `Bool force)
    ; ("instance_name", `String instance_name)
    ; ("expected_pid", `Int expected_pid)
    ; ("expected_start_time", `Int expected_start_time)
    ; ("requested_at", `Float (Unix.gettimeofday ()))
    ]
  in
  write_json_atomic (request_path ~instance_dir) (`Assoc fields);
  request_id

let parse_request = function
  | `Assoc fields ->
      let id_ok s =
        (* Generated shape: "<pid>-<hex>". Reject path separators / junk so a
           crafted request_id cannot escape the instance_dir. *)
        let s = String.trim s in
        String.length s > 0 && String.length s < 128
        && (try
              String.iter
                (function
                  | 'a' .. 'z'
                  | 'A' .. 'Z'
                  | '0' .. '9'
                  | '-' | '_' -> ()
                  | _ -> raise Exit)
                s;
              true
            with Exit -> false)
      in
      let id =
        match string_member "request_id" fields with
        | Some s when id_ok s -> s
        | _ -> fresh_request_id ()
      in
      let instance_name =
        match string_member "instance_name" fields with
        | Some s -> s
        | None -> ""
      in
      (match int_member "expected_pid" fields, int_member "expected_start_time" fields with
       | Some pid, Some st ->
           Some
             { id
             ; force =
                 (match bool_member "force" fields with Some b -> b | None -> false)
             ; instance_name
             ; expected_pid = Some pid
             ; expected_start_time = Some st
             ; requested_at =
                 (match float_member "requested_at" fields with
                  | Some f -> f
                  | None -> 0.0)
             }
       | _ -> None)
  | _ -> None

(** Owner side: consume (and remove) a pending request, if any. *)
let consume_request ~instance_dir : request option =
  let path = request_path ~instance_dir in
  match C2c_io.read_json_opt path with
  | None -> None
  | Some json ->
      (try Sys.remove path with _ -> ());
      parse_request json

(** Validate that [owner] matches the request's pinned identity and name.
    Returns [Ok ()] or [Error reason] for a declined/fail-closed decision. *)
let validate_identity ~(request : request) ~(owner : identity) :
    (unit, string) result =
  if String.trim request.instance_name = "" then Error "instance-name-missing"
  else if not (String.equal request.instance_name owner.name) then
    Error "instance-name-mismatch"
  else
    match (request.expected_pid, request.expected_start_time) with
    | None, _ | _, None -> Error "identity-pins-missing"
    | Some expected_pid, Some expected_st -> (
        if expected_pid <> owner.pid then Error "pid-mismatch"
        else
          match owner.start_time with
          | None -> Error "start-time-unavailable"
          | Some actual when actual <> expected_st -> Error "start-time-mismatch"
          | Some _ -> Ok ())

let write_result ~instance_dir ~request_id ~(result : result_kind) : unit =
  C2c_io.mkdir_p instance_dir;
  write_json_atomic
    (result_path ~instance_dir ~request_id)
    (`Assoc
       [ ("request_id", `String request_id)
       ; ("result", `String (result_kind_to_string result))
       ; ("decided_at", `Float (Unix.gettimeofday ()))
       ])

let await_result ~instance_dir ~request_id ~(timeout_s : float) :
    result_kind option =
  let path = result_path ~instance_dir ~request_id in
  let deadline = Unix.gettimeofday () +. max 0.0 timeout_s in
  let rec loop () =
    match C2c_io.read_json_opt path with
    | Some (`Assoc fields) ->
        let kind =
          match string_member "result" fields with
          | Some s -> result_kind_of_string s
          | None -> Failed "missing-result-field"
        in
        (try Sys.remove path with _ -> ());
        Some kind
    | _ when Unix.gettimeofday () >= deadline -> None
    | _ ->
        Unix.sleepf 0.05;
        loop ()
  in
  loop ()

(** Commit takeover: only after identity validation AND the caller has
    finished controlled teardown may the owner ack [Restarting] and reexec.

    [teardown] should reap the inner process group and owned sidecars.
    [do_exec] defaults to [Unix.execve] with the plan's env; tests inject a
    no-op. The [Restarting] result is written only after [teardown]
    returns [Ok] and immediately before [do_exec] — never before commit. *)
(** [identity_at] is MANDATORY: re-sample pid/start-time after teardown.
    Tests inject a function; production owners must re-read self identity. *)
let commit_takeover ~instance_dir ~(request : request) ~(owner : identity)
    ~(plan : launch_plan) ~(teardown : unit -> (unit, string) result)
    ~(identity_at : unit -> identity)
    ?(do_exec : (launch_plan -> unit) option) () : (unit, string) result =
  match validate_identity ~request ~owner with
  | Error reason ->
      write_result ~instance_dir ~request_id:request.id
        ~result:(Declined reason);
      Error reason
  | Ok () -> (
      match teardown () with
      | Error reason ->
          write_result ~instance_dir ~request_id:request.id
            ~result:(Failed reason);
          Error reason
      | Ok () -> (
          (* Re-check identity immediately before ack/reexec. *)
          let owner_now = identity_at () in
          match validate_identity ~request ~owner:owner_now with
          | Error reason ->
              write_result ~instance_dir ~request_id:request.id
                ~result:(Declined reason);
              Error reason
          | Ok () ->
              (* Enforce controlled env — never pass ambient/secrets through. *)
              let plan =
                { plan with env = filter_env ~source:plan.env () }
              in
              write_result ~instance_dir ~request_id:request.id
                ~result:Restarting;
              let exec =
                match do_exec with
                | Some f -> f
                | None ->
                    fun p ->
                      (match p.cwd with
                       | Some dir ->
                           (try Unix.chdir dir
                            with Unix.Unix_error (e, _, _) ->
                              Printf.eprintf
                                "warning: owner-control chdir %s failed: %s\n%!"
                                dir (Unix.error_message e))
                       | None -> ());
                      Unix.execve p.executable p.argv p.env
              in
              exec plan;
              Ok ()))

(** Read /proc/<pid>/stat field 22 (starttime, clock ticks) when available. *)
let read_pid_start_time ?(proc_root = "/proc") (pid : int) : int option =
  let path = Printf.sprintf "%s/%d/stat" proc_root pid in
  try
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
        let line = input_line ic in
        (* comm is parenthesized and may contain spaces; find last ')' *)
        let rec rfind_paren i =
          if i < 0 then None
          else if line.[i] = ')' then Some i
          else rfind_paren (i - 1)
        in
        match rfind_paren (String.length line - 1) with
        | None -> None
        | Some rp ->
            let rest =
              String.trim
                (String.sub line (rp + 1) (String.length line - rp - 1))
            in
            let fields = String.split_on_char ' ' rest in
            (* After ')': state(1) ppid(2) ... starttime is field 20 in this
               post-paren list (Linux proc(5) field 22 overall = 1 state + 19). *)
            (match List.nth_opt fields 19 with
             | Some s -> (try Some (int_of_string s) with _ -> None)
             | None -> None))
  with _ -> None

let identity_of_self ~name : identity =
  let pid = Unix.getpid () in
  { name; pid; start_time = read_pid_start_time pid }
