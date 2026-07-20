(* Monitor self-stale detection (I013). See c2c_monitor_stale.mli. *)

type reason =
  | Binary_upgraded
  | Orphan

type action =
  | Continue
  | Exit_stale of reason

let default_check_interval_s = 60.0

let reason_label = function
  | Binary_upgraded -> "binary_upgraded"
  | Orphan -> "orphan"

(* Shell-quote for paste-safe relaunch lines. Unquoted when the token is a
   conservative safe subset (alnum + a few path/flag chars); otherwise
   POSIX single-quote with embedded-' escape. *)
let shell_quote s =
  let safe c =
    (c >= 'a' && c <= 'z')
    || (c >= 'A' && c <= 'Z')
    || (c >= '0' && c <= '9')
    || c = '-' || c = '_' || c = '.' || c = '/' || c = '=' || c = ','
    || c = ':' || c = '+' || c = '@' || c = '%'
  in
  if s <> "" && String.for_all safe s then s
  else "'" ^ String.concat "'\"'\"'" (String.split_on_char '\'' s) ^ "'"

let reconstruct_monitor_command ?(argv = Sys.argv) () =
  let parts = Array.to_list argv in
  match parts with
  | [] -> "c2c monitor"
  | _ -> String.concat " " (List.map shell_quote parts)

let file_is_regular path =
  try
    let st = Unix.stat path in
    st.Unix.st_kind = Unix.S_REG
  with _ -> false

let resolve_installed_exe ?(argv0 = Sys.argv.(0))
    ?(home = try Sys.getenv "HOME" with Not_found -> "") () =
  let abs_argv0 =
    if Filename.is_relative argv0 then
      Filename.concat (Sys.getcwd ()) argv0
    else argv0
  in
  let candidates =
    [ abs_argv0
    ; (try Sys.executable_name with _ -> "")
    ; (if home = "" then "" else Filename.concat home ".local/bin/c2c")
    ]
  in
  let rec find = function
    | [] -> None
    | "" :: rest -> find rest
    | p :: rest ->
        (* Never treat /proc/*/exe as the *installed* path — that is the
           running image under comparison. *)
        if
          (String.length p >= 6 && String.sub p 0 6 = "/proc/")
          || not (file_is_regular p)
        then find rest
        else Some p
  in
  find candidates

let decide_binary_verdict = function
  | C2c_stale.Stale -> Exit_stale Binary_upgraded
  | C2c_stale.Current | C2c_stale.Unknown _ -> Continue

let format_stale_exit ?(now_hms = "") ~reason ~relaunch_command () =
  let prefix = if now_hms = "" then "" else now_hms ^ " " in
  let why =
    match reason with
    | Binary_upgraded -> "binary upgraded (running image differs from installed)"
    | Orphan -> "parent process gone (orphan, ppid=1)"
  in
  Printf.sprintf
    "%sc2c monitor: stale (%s)\n\
     Relaunch with: %s\n\
     Exiting cleanly (exit 0) — do not auto-respawn.\n"
    prefix why relaunch_command

let stale_exit_json ~reason ~relaunch_command =
  let ts = Printf.sprintf "%.3f" (Unix.gettimeofday ()) in
  `Assoc
    [ ("event_type", `String "monitor.stale-exit")
    ; ("monitor_ts", `String ts)
    ; ("reason", `String (reason_label reason))
    ; ("relaunch_command", `String relaunch_command)
    ]
