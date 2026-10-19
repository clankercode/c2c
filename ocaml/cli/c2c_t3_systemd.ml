(* User-systemd supervision for the native T3 connector.

   This module is intentionally independent of the service loop.  It owns the
   unit text and the small systemctl seam used by the CLI and fixture tests.
   Every path embedded in the unit is absolute; a user manager does not have
   the interactive shell's PATH or environment. *)

let ( // ) = Filename.concat
let home_dir () = try Sys.getenv "HOME" with Not_found -> "."

let unit_name = "c2c-t3.service"

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
  | Some value -> int_of_string_opt (String.trim value)
  | None -> None

type install_result = Installed of string | Skipped of string | Failed of string

let mkdir_p path =
  let rec loop path =
    if path = "" || path = "." || path = "/" || Sys.file_exists path then ()
    else (loop (Filename.dirname path); try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  loop path

let install ?(run = run_systemctl_default) ?(dry_run = false)
    ?(query = query_systemctl_default) ~c2c_path ~t3_home ~config_dir ~state_dir () =
  if not (systemd_user_available ~run ()) then
    Skipped "systemd --user is unavailable; run `c2c t3 service` in the foreground"
  else
    let path = unit_path () in
    if dry_run then Installed path
    else begin
      mkdir_p (Filename.dirname path);
      match C2c_io.write_file_atomic ~perm:0o644 path
              (unit_text ~c2c_path ~t3_home ~config_dir ~state_dir ()) with
      | Error e -> Failed (Printf.sprintf "could not write %s: %s" path e)
      | Ok () ->
          match run [ "--user"; "daemon-reload" ] with
          | Systemctl_failed e -> Failed e
          | Systemctl_ok ->
              (match run [ "--user"; "enable"; "--now"; unit_name ] with
               | Systemctl_ok ->
                   if unit_is_active ~query () then Installed path
                   else Failed ("systemd accepted enable --now but c2c-t3.service is not active")
               | Systemctl_failed e -> Failed e)
    end

let stop ?(run = run_systemctl_default) () = run [ "--user"; "disable"; "--now"; unit_name ]

let uninstall ?(run = run_systemctl_default) ?(dry_run = false) () =
  if not dry_run then begin
    ignore (run [ "--user"; "disable"; "--now"; unit_name ]);
    if Sys.file_exists (unit_path ()) then (try Unix.unlink (unit_path ()) with _ -> ());
    ignore (run [ "--user"; "daemon-reload" ])
  end
