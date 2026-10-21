(* User-systemd supervision for the native T3 connector.

   This module is intentionally independent of the service loop.  It owns the
   unit text and the small systemctl seam used by the CLI and fixture tests.
   Every path embedded in the unit is absolute; a user manager does not have
   the interactive shell's PATH or environment. *)

let ( // ) = Filename.concat
let home_dir () = try Sys.getenv "HOME" with Not_found -> "."

let unit_name = "c2c-t3.service"
let unit_marker = "# c2c-managed-unit: c2c-t3.service:v1"

let systemd_user_dir () =
  match Sys.getenv_opt "XDG_CONFIG_HOME" with
  | Some d when String.trim d <> "" -> String.trim d // "systemd" // "user"
  | _ -> home_dir () // ".config" // "systemd" // "user"

let unit_path () = systemd_user_dir () // unit_name

let state_dir () =
  match Sys.getenv_opt "C2C_T3_STATE_DIR" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ -> home_dir () // ".local" // "state" // "c2c" // "t3"

let config_dir () =
  match Sys.getenv_opt "C2C_T3_CONFIG_DIR" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ -> home_dir () // ".c2c" // "t3"

let t3_home () =
  match Sys.getenv_opt "T3CODE_HOME" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ -> (try Sys.getenv "HOME" with Not_found -> ".") // ".t3"

let c2c_path () =
  let installed = home_dir () // ".local" // "bin" // "c2c" in
  let path =
    if Sys.file_exists installed then installed
    else if Filename.is_relative Sys.executable_name then Sys.getcwd () // Sys.executable_name
    else Sys.executable_name
  in
  if Filename.is_relative path then Error "c2c executable path is not absolute"
  else if not (Sys.file_exists path) then Error ("c2c executable not found: " ^ path)
  else Ok path

let systemd_quote value =
  if String.for_all (fun ch ->
      (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
      || (ch >= '0' && ch <= '9') || List.mem ch [ '/'; '.'; '_'; '-'; ':' ]) value
  then value
  else
    "\"" ^ String.concat "" (List.map (function '"' -> "\\\"" | '\\' -> "\\\\" | ch -> String.make 1 ch) (List.of_seq (String.to_seq value))) ^ "\""

let unit_text ~c2c_path ~t3_home ~config_dir ~state_dir ?(interval = 60.) () =
  let c2c_path = if Filename.is_relative c2c_path then Sys.getcwd () // c2c_path else c2c_path in
  let t3_home = if Filename.is_relative t3_home then Sys.getcwd () // t3_home else t3_home in
  let config_dir = if Filename.is_relative config_dir then Sys.getcwd () // config_dir else config_dir in
  let state_dir = if Filename.is_relative state_dir then Sys.getcwd () // state_dir else state_dir in
  String.concat "\n"
    [ "# c2c-t3.service — native connector for one local T3 Code instance";
      unit_marker;
      "# Owned by c2c; service repair never replaces credentials or state.";
      "[Unit]";
      "Description=c2c T3 Code connector";
      "After=default.target";
      "StartLimitIntervalSec=0";
      "";
      "[Service]";
      Printf.sprintf "ExecStart=%s t3 service --foreground --interval %.0f" (systemd_quote c2c_path) interval;
      "Restart=always";
      "RestartSec=5";
      Printf.sprintf "Environment=T3CODE_HOME=%s" (systemd_quote t3_home);
      Printf.sprintf "Environment=C2C_T3_CONFIG_DIR=%s" (systemd_quote config_dir);
      Printf.sprintf "Environment=C2C_T3_STATE_DIR=%s" (systemd_quote state_dir);
      "UnsetEnvironment=C2C_MCP_SESSION_ID C2C_MCP_BROKER_ROOT C2C_MCP_AUTO_REGISTER_ALIAS";
      "";
      "[Install]";
      "WantedBy=default.target";
      "" ]

type systemctl_status = Systemctl_ok | Systemctl_failed of string
type systemctl_runner = string list -> systemctl_status
type systemctl_query = string list -> string option

let fixture_enabled () = Sys.getenv_opt "C2C_SYSTEMCTL_FIXTURE" = Some "1"

let run_systemctl_default args =
  if fixture_enabled () then begin
    let () = (match Sys.getenv_opt "C2C_SYSTEMCTL_CAPTURE_FILE" with
     | None -> ()
     | Some path ->
         (try
            let oc = open_out_gen [ Open_append; Open_creat ] 0o600 path in
            Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
              output_string oc ("systemctl " ^ String.concat " " args ^ "\n"))
          with _ -> ())) in
    Systemctl_ok
  end else
    let command = "systemctl " ^ String.concat " " (List.map Filename.quote args) ^ " 2>&1" in
    try
      let ic = Unix.open_process_in command in
      let lines = Buffer.create 256 in
      (try while true do Buffer.add_string lines (input_line ic); Buffer.add_char lines '\n' done
       with End_of_file -> ());
      let status = Unix.close_process_in ic in
      match status with
      | Unix.WEXITED 0 -> Systemctl_ok
      | Unix.WEXITED code ->
          Systemctl_failed (Printf.sprintf "systemctl exited %d: %s" code (Buffer.contents lines))
      | _ -> Systemctl_failed "systemctl was interrupted"
    with exn -> Systemctl_failed (Printexc.to_string exn)

let query_systemctl_default args =
  if fixture_enabled () then
    match Sys.getenv_opt "C2C_SYSTEMCTL_STATE_FILE" with
    | None -> None
    | Some path ->
        (try
           match Yojson.Safe.from_file path with
           | `Assoc fields ->
               let key =
                 if List.mem "is-active" args then "is-active"
                 else if List.mem "is-enabled" args then "is-enabled"
                 else if List.mem "MainPID" args then "main-pid"
                 else ""
               in
               (match List.assoc_opt key fields with Some (`String s) -> Some (String.trim s) | _ -> None)
           | _ -> None
         with _ -> None)
  else
    let command = "systemctl " ^ String.concat " " (List.map Filename.quote args) ^ " 2>/dev/null" in
    try
      let ic = Unix.open_process_in command in
      let output = try input_line ic with End_of_file -> "" in
      ignore (Unix.close_process_in ic);
      if String.trim output = "" then None else Some (String.trim output)
    with _ -> None

let systemd_user_available ?(run = run_systemctl_default) () =
  match run [ "--version" ], run [ "--user"; "show-environment" ] with
  | Systemctl_ok, Systemctl_ok -> true
  | _ -> false

let unit_is_active ?(query = query_systemctl_default) () =
  match query [ "--user"; "is-active"; unit_name ] with
  | Some ("active" | "activating" | "reloading") -> true
  | _ -> false

let unit_is_enabled ?(query = query_systemctl_default) () =
  match query [ "--user"; "is-enabled"; unit_name ] with Some "enabled" -> true | _ -> false

let unit_main_pid ?(query = query_systemctl_default) () =
  match query [ "--user"; "show"; "-p"; "MainPID"; "--value"; unit_name ] with
  | Some value ->
      (match int_of_string_opt (String.trim value) with Some pid when pid > 0 -> Some pid | _ -> None)
  | None -> None

type install_result = Installed of string | Skipped of string | Failed of string

let mkdir_p path =
  let rec loop path =
    if path = "" || path = "." || path = "/" || Sys.file_exists path then ()
    else (loop (Filename.dirname path); try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  loop path

let private_mkdir_p path =
  let rec loop path =
    if path = "" || path = "." || path = "/" then ()
    else
      match Unix.lstat path with
      | { Unix.st_kind = Unix.S_DIR; _ } -> ()
      | _ -> raise (Unix.Unix_error (Unix.ENOTDIR, "mkdir", path))
      | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
          loop (Filename.dirname path);
          (try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  loop path

let unit_file_owned path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_REG; st_uid; _ } when st_uid = Unix.geteuid () ->
      (try
         let ic = open_in_bin path in
         Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
           let length = in_channel_length ic in
           let body = really_input_string ic length in
           String.contains body '#' &&
           let marker_len = String.length unit_marker in
           let rec find i =
             i + marker_len <= String.length body &&
             (String.sub body i marker_len = unit_marker || find (i + 1))
           in
           find 0)
       with _ -> false)
  | _ -> false

let unit_path_safety path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok `Missing
  | { Unix.st_kind = Unix.S_LNK; _ } -> Error (path ^ " is a symlink; refusing to follow it")
  | { Unix.st_kind = Unix.S_REG; _ } when unit_file_owned path -> Ok `Owned
  | { Unix.st_kind = Unix.S_REG; _ } -> Error (path ^ " is a foreign unit file; refusing to replace it")
  | _ -> Error (path ^ " is not a regular unit file")

external open_regular_nofollow : string -> Unix.file_descr
  = "caml_c2c_open_regular_nofollow"

let absolute path = if Filename.is_relative path then Sys.getcwd () // path else path

let read_owned_regular ?(private_mode = false) ~max_bytes path =
  try
    let fd = open_regular_nofollow path in
    Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
      let st = Unix.fstat fd in
      if st.Unix.st_uid <> Unix.geteuid () || st.Unix.st_nlink <> 1
         || st.Unix.st_size > max_bytes
         || (private_mode && st.Unix.st_perm land 0o077 <> 0) then
        Error (path ^ " has unsafe ownership, links, permissions or size")
      else
        let contents = Bytes.create st.Unix.st_size in
        let rec read offset =
          if offset = Bytes.length contents then Ok (Bytes.to_string contents)
          else match Unix.read fd contents offset (Bytes.length contents - offset) with
            | 0 -> Error (path ^ " changed while being read")
            | count -> read (offset + count)
        in read 0)
  with _ -> Error (path ^ " cannot be read safely")

(* An owned unit for another environment is not ours to repurpose. Missing or
   duplicate scope lines are ambiguous and require explicit operator action. *)
let unit_scope_matches ~contents ~t3_home ~config_dir ~state_dir =
  let lines = String.split_on_char '\n' contents in
  List.for_all (fun (key, value) ->
    let prefix = "Environment=" ^ key ^ "=" in
    let matches = List.filter (String.starts_with ~prefix) lines in
    matches = [ prefix ^ systemd_quote (absolute value) ])
    [ ("T3CODE_HOME", t3_home); ("C2C_T3_CONFIG_DIR", config_dir);
      ("C2C_T3_STATE_DIR", state_dir) ]

let unit_scope_safety ~t3_home ~config_dir ~state_dir () =
  match unit_path_safety (unit_path ()) with
  | Error _ as error -> error
  | Ok `Missing -> Ok `Missing
  | Ok `Owned ->
      (match read_owned_regular ~max_bytes:65536 (unit_path ()) with
       | Error _ as error -> error
       | Ok contents ->
           if not (List.mem unit_marker (String.split_on_char '\n' contents))
              || not (unit_scope_matches ~contents ~t3_home ~config_dir ~state_dir) then
             Error "T3 unit belongs to a different or ambiguous environment; preserve it and select its exact T3 home/config/state paths"
           else Ok `Owned)

(* Every c2c unit writer uses this stable lock inode. It is deliberately
   separate from connector state so installation never unlinks a live owner's
   singleton. Nonblocking acquisition keeps concurrent operations bounded. *)
let with_unit_lock ~dry_run f =
  if dry_run then Ok (f ())
  else
    try
      private_mkdir_p (systemd_user_dir ());
      let path = unit_path () ^ ".lock" in
      let before = try Some (Unix.lstat path) with Unix.Unix_error (Unix.ENOENT, _, _) -> None in
      let fd = match before with
        | None -> Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ] 0o600
        | Some st when st.Unix.st_kind = Unix.S_REG && st.Unix.st_uid = Unix.geteuid () && st.Unix.st_nlink = 1 ->
            Unix.openfile path [ Unix.O_RDWR; Unix.O_NONBLOCK; Unix.O_CLOEXEC ] 0
        | Some _ -> failwith "unsafe unit lock" in
      Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
        let actual = Unix.fstat fd and current = Unix.lstat path in
        let same a b = a.Unix.st_dev = b.Unix.st_dev && a.Unix.st_ino = b.Unix.st_ino in
        if actual.Unix.st_kind <> Unix.S_REG || actual.Unix.st_uid <> Unix.geteuid ()
           || actual.Unix.st_nlink <> 1 || not (same actual current)
           || (match before with Some before -> not (same before actual) | None -> false) then
          Error "unit lock ownership changed; no unit action was performed"
        else
          try Unix.lockf fd Unix.F_TLOCK 0; Unix.fchmod fd 0o600; Ok (f ())
          with Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES), _, _) ->
            Error "another c2c unit operation owns the lock; retry after it completes")
    with _ -> Error "unit operation could not acquire its owned lock safely"

let unit_plan ~c2c_path ~t3_home ~config_dir ~state_dir () =
  match unit_scope_safety ~t3_home ~config_dir ~state_dir () with
  | Error _ as error -> error
  | Ok `Missing -> Ok `Missing
  | Ok `Owned ->
      (match read_owned_regular ~max_bytes:65536 (unit_path ()) with
       | Error _ as error -> error
       | Ok contents ->
           if not (unit_scope_matches ~contents ~t3_home ~config_dir ~state_dir) then
             Error "owned T3 unit has different or ambiguous environment paths; preserve it and select the matching T3 environment"
           else if contents = unit_text ~c2c_path ~t3_home ~config_dir ~state_dir () then Ok `Current
           else Ok `Drifted)

let read_bounded path max_bytes =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
    let buffer = Buffer.create 256 in
    let bytes = Bytes.create 4096 in
    let rec loop remaining =
      let count = input ic bytes 0 (min remaining (Bytes.length bytes)) in
      if count = 0 then Buffer.contents buffer
      else if remaining <= count then failwith "bounded process record exceeded"
      else (Buffer.add_subbytes buffer bytes 0 count; loop (remaining - count))
    in loop (max_bytes + 1))

let environment_id home =
  let home = try Unix.realpath home with _ -> home in
  "t3-env-" ^ String.sub Digestif.SHA256.(to_hex (digest_string ("t3-home:" ^ home))) 0 32

let foreground_arguments args =
  (* Plain [t3 service] is the documented foreground default too. A one-shot
     or management subcommand cannot attest a periodic monitor owner. *)
  let rec options = function
    | [] | [ "" ] -> true
    | ("--foreground" | "--cross-repo") :: rest -> options rest
    | ("--interval" | "--mode" | "--recovery") :: _value :: rest -> options rest
    | value :: rest when List.exists (fun prefix -> String.starts_with ~prefix value)
          [ "--interval="; "--mode="; "--recovery=" ] -> options rest
    | _ -> false
  in
  match args with _ :: "t3" :: "service" :: rest -> options rest | _ -> false

let check_process ?(proc_root = "/proc")
    ?(generation = C2c_pid_identity.read_pid_generation)
    ~pid ~c2c_path ~t3_home ~config_dir ~state_dir () =
  try
    let before = generation pid in
    let proc = proc_root // string_of_int pid in
    let owner = Unix.stat proc in
    let expected = Unix.stat c2c_path in
    let executable = Unix.stat (proc // "exe") in
    let args = String.split_on_char '\000' (read_bounded (proc // "cmdline") 65536) in
    let env = String.split_on_char '\000' (read_bounded (proc // "environ") 262144) in
    if owner.Unix.st_uid <> Unix.geteuid ()
       || expected.Unix.st_dev <> executable.Unix.st_dev
       || expected.Unix.st_ino <> executable.Unix.st_ino then
      Error "T3 connector MainPID is not running the expected owned executable; run c2c t3 service install after stopping the owned connector"
    else if not (foreground_arguments args)
            || not (List.for_all (fun (key, value) ->
                List.filter (String.starts_with ~prefix:(key ^ "=")) env
                = [ key ^ "=" ^ absolute value ])
                [ ("T3CODE_HOME", t3_home); ("C2C_T3_CONFIG_DIR", config_dir);
                  ("C2C_T3_STATE_DIR", state_dir) ]) then
      Error "T3 connector MainPID has the wrong command or environment paths"
    else match before, generation pid with
      | C2c_pid_identity.Generation a, C2c_pid_identity.Generation b when a = b -> Ok a
      | _ -> Error "T3 connector MainPID generation is unavailable or changed"
  with _ -> Error "T3 connector MainPID identity cannot be verified"

let check_monitor ?(clock = Unix.gettimeofday) ~pid ~generation ~t3_home ~state_dir () =
  match read_owned_regular ~private_mode:true ~max_bytes:65536 (state_dir // "service-status.json") with
  | Error _ as error -> error
  | Ok text ->
      try
        let fields = match Yojson.Safe.from_string text with `Assoc fields -> fields | _ -> [] in
        let at key = match List.assoc_opt key fields with
          | Some (`Float at) -> Some at | Some (`Int at) -> Some (float_of_int at) | _ -> None in
        let fresh = match at "completedAt", at "intervalSeconds" with
          | Some completed, Some interval -> Float.is_finite completed && Float.is_finite interval
              && interval >= 1. && completed <= clock () +. 5.
              && clock () -. completed <= max 180. (min 600. (interval *. 2. +. 60.))
          | _ -> false in
        if List.assoc_opt "environmentId" fields <> Some (`String (environment_id t3_home))
           || List.assoc_opt "pid" fields <> Some (`Int pid)
           || List.assoc_opt "pidGeneration" fields <> Some (`Int generation)
           || List.assoc_opt "healthy" fields <> Some (`Bool true) || not fresh then
          Error "T3 connector has no fresh healthy completed owner sweep; inspect c2c t3 service doctor --json"
        else Ok ()
      with _ -> Error "T3 connector monitor status is malformed"

let native_readiness ~c2c_path ~t3_home ~config_dir ~state_dir ~pid () =
  let ( let* ) = Result.bind in
  let* generation = check_process ~pid ~c2c_path ~t3_home ~config_dir ~state_dir () in
  let* () = check_monitor ~pid ~generation ~t3_home ~state_dir () in
  let limits = { C2c_t3_client.default_limits with request_timeout_s = 3. } in
  let* client, _ = C2c_t3_client.authorize ~limits ~config_dir ~t3_home ()
    |> Result.map_error C2c_t3_client.error_to_string in
  let* () =
    try Lwt_main.run
        (let open Lwt.Infix in
         C2c_t3_client.initialize client >>= function
         | Error error -> Lwt.return (Error (C2c_t3_client.error_to_string error))
         | Ok () -> C2c_t3_client.capabilities client >|= Result.map (fun _ -> ())
             >|= Result.map_error C2c_t3_client.error_to_string)
    with _ -> Error "T3 connector API readiness check failed"
  in
  match check_process ~pid ~c2c_path ~t3_home ~config_dir ~state_dir () with
  | Ok current when current = generation -> Ok ()
  | _ -> Error "T3 connector changed during API readiness check"

let await_readiness ?(clock = Unix.gettimeofday)
    ?(pause = fun () -> ignore (Unix.select [] [] [] 1.))
    ?(timeout = 30.) ~query ~readiness () =
  let deadline = clock () +. timeout in
  let rec loop remaining =
    let result = match unit_main_pid ~query () with
      | None -> Error "T3 connector MainPID is unavailable"
      | Some pid -> readiness ~pid () in
    match result with
    | Ok () -> Ok ()
    | Error reason when remaining <= 0 || clock () >= deadline -> Error reason
    | Error _ -> pause (); loop (remaining - 1)
  in loop 30

let install ?(run = run_systemctl_default) ?(dry_run = false)
    ?(query = query_systemctl_default) ?readiness ?pause ?clock ?timeout
    ~c2c_path ~t3_home ~config_dir ~state_dir () =
  let operation () =
    if not (systemd_user_available ~run ()) then
      Skipped "systemd --user is unavailable; run `c2c t3 service` in the foreground"
    else
    let path = unit_path () in
    let scope = unit_plan ~c2c_path ~t3_home ~config_dir ~state_dir () in
    if Result.is_error scope then
      (match scope with Error reason -> Skipped reason | _ -> assert false)
    else if dry_run then Installed path
    else begin
      (match unit_scope_safety ~t3_home ~config_dir ~state_dir () with
       | Error reason -> Skipped reason
       | Ok _ ->
      private_mkdir_p (Filename.dirname path);
      match C2c_io.write_file_atomic ~perm:0o644 path
              (unit_text ~c2c_path ~t3_home ~config_dir ~state_dir ()) with
      | Error e -> Failed (Printf.sprintf "could not write %s: %s" path e)
      | Ok () ->
          match run [ "--user"; "daemon-reload" ] with
          | Systemctl_failed e -> Failed e
          | Systemctl_ok ->
              (match unit_scope_safety ~t3_home ~config_dir ~state_dir () with
               | Error reason -> Failed reason
               | Ok `Missing -> Failed "owned unit disappeared before enable; no enable was attempted"
               | Ok `Owned ->
              (match run [ "--user"; "enable"; "--now"; unit_name ] with
               | Systemctl_ok ->
                   if unit_scope_safety ~t3_home ~config_dir ~state_dir () <> Ok `Owned then
                     Failed "unit scope changed during enable; readiness is not claimed"
                   else if unit_is_active ~query () then
                     let readiness = Option.value readiness
                         ~default:(native_readiness ~c2c_path ~t3_home ~config_dir ~state_dir) in
                     (match await_readiness ?pause ?clock ?timeout ~query ~readiness () with
                      | Ok () -> Installed path
                      | Error reason -> Failed ("T3 unit started but readiness is incomplete: " ^ reason))
                   else Failed ("systemd accepted enable --now but c2c-t3.service is not active")
               | Systemctl_failed e -> Failed e)))
    end
  in
  match with_unit_lock ~dry_run operation with
  | Ok result -> result | Error reason -> Failed reason

let stop ?(run = run_systemctl_default) ?(dry_run = false)
    ?(t3_home = t3_home ()) ?(config_dir = config_dir ()) ?(state_dir = state_dir ()) () =
  let operation () = match unit_scope_safety ~t3_home ~config_dir ~state_dir () with
  | Error reason -> Systemctl_failed reason
  | Ok `Missing -> Systemctl_ok
  | Ok `Owned ->
      if dry_run then Systemctl_ok else run [ "--user"; "disable"; "--now"; unit_name ]
  in
  match with_unit_lock ~dry_run operation with
  | Ok result -> result | Error reason -> Systemctl_failed reason

let uninstall ?(run = run_systemctl_default) ?(dry_run = false)
    ?(t3_home = t3_home ()) ?(config_dir = config_dir ()) ?(state_dir = state_dir ()) () =
    (* Never disable a foreign or symlinked unit merely because it shares our
       conventional name.  Ownership is established from the regular-file
       marker before any systemd mutation, then the same check guards unlink.
    *)
    let operation () = match unit_scope_safety ~t3_home ~config_dir ~state_dir () with
    | Error reason -> Systemctl_failed reason
    | Ok `Missing -> Systemctl_ok
    | Ok `Owned when dry_run -> Systemctl_ok
    | Ok `Owned ->
        (match run [ "--user"; "disable"; "--now"; unit_name ] with
         | Systemctl_failed _ as error -> error
         | Systemctl_ok ->
             (match unit_scope_safety ~t3_home ~config_dir ~state_dir () with
              | Ok `Owned ->
                  (try Unix.unlink (unit_path ()); run [ "--user"; "daemon-reload" ]
                   with _ -> Systemctl_failed "owned unit could not be removed safely")
              | _ -> Systemctl_failed "unit scope changed during uninstall; preserve it"))
    in
    match with_unit_lock ~dry_run operation with
    | Ok result -> result | Error reason -> Systemctl_failed reason
