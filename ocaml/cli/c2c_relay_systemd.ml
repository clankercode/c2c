(* c2c_relay_systemd.ml — systemd --user boot supervision for the machine-wide
   relay connector (B296).

   The connector's exit-3 self-restart story previously terminated at
   [C2c_relay_managed.supervise]: a userland parent that dies at the first
   reboot, logout, or OOM (x-left was relay-dark 55 days because nothing
   restarted the supervisor). This module makes systemd the outer supervisor:
   Restart=always + StartLimitIntervalSec=0 so restart loops are never
   rate-limited into darkness, WantedBy=default.target so it starts at login.

   ExecStart runs the c2c SUPERVISOR in the foreground
   (`<abs> start relay-connect --foreground`), not the bare connector: the
   supervisor keeps the pidfile/`c2c stop` integration, restarts the connector
   child within 1s of an exit-3, and re-execs on c2c binary updates; systemd
   covers everything the supervisor cannot survive. The absolute path matters:
   non-login shells (and the user manager) lack ~/.local/bin on PATH.

   Machine mode: the connector serves ALL broker roots under ~/.c2c/repos.
   The unit clears the whole c2c env surface (B311): C2C_MCP_BROKER_ROOT
   (so an inherited value cannot scope the connector to one repo) plus the
   relay config/token/identity/instance-dir/session vars a user manager may
   have imported, any of which would silently redirect the machine
   connector; the relay URL is resolved from relay.json at every start
   (pinned into Environment= only when no durable machine config exists).

   B300 gating: the unit is installed+enabled ONLY when Relay_activation
   resolves Active — a local-only host must never get an enabled relay
   connector unit.

   systemctl is never executed under test: the default runner is inert under
   C2C_SYSTEMCTL_FIXTURE=1 (recording argv to C2C_SYSTEMCTL_CAPTURE_FILE when
   set), and every entry point accepts an injectable runner. *)

let ( // ) = Filename.concat

let unit_name = "c2c-relay-connect.service"

(* systemd --user unit search path: $XDG_CONFIG_HOME/systemd/user, else
   ~/.config/systemd/user (what `systemctl --user link/enable` reads). *)
let systemd_user_dir () =
  match Sys.getenv_opt "XDG_CONFIG_HOME" with
  | Some d when String.trim d <> "" ->
      String.trim d // "systemd" // "user"
  | _ ->
      (try Sys.getenv "HOME" with Not_found -> ".") // ".config" // "systemd"
      // "user"

let unit_path () = systemd_user_dir () // unit_name

(* The machine-wide relay config the unit's supervisor resolves at start.
   Deliberately NOT Relay_activation.config_path (): that honors
   C2C_RELAY_CONFIG / C2C_MCP_BROKER_ROOT, which the unit's environment
   (cleared above) will not have. *)
let machine_relay_config_path () =
  (try Sys.getenv "HOME" with Not_found -> ".") // ".config" // "c2c"
  // "relay.json"

(* Can the unit resolve a relay URL on its own (durable machine relay.json
   with a url and not enabled:false)? When true, no Environment= pin is
   written, so `c2c relay enable --url <other>` re-points the connector
   without rewriting the unit. *)
let machine_relay_config_has_url () =
  match (try Some (Yojson.Safe.from_file (machine_relay_config_path ())) with _ -> None) with
  | Some (`Assoc fields) ->
      (match List.assoc_opt "enabled" fields with
       | Some (`Bool false) -> false
       | _ ->
           (match List.assoc_opt "url" fields with
            | Some (`String u) -> String.trim u <> ""
            | _ -> false))
  | _ -> false

(* Pin C2C_RELAY_URL into the unit only when activation came from a source
   the unit cannot re-read at start (env / flag / repo-local config). *)
let relay_url_env_for_unit () =
  match Relay_activation.resolve () with
  | Relay_activation.Relay_active (url, _) when not (machine_relay_config_has_url ()) ->
      Some url
  | _ -> None

(* Parameterized unit literal (B296 decision: embedded, no codegen step). *)
let unit_text ~c2c_path ?relay_url_env () : string =
  let env_lines =
    match relay_url_env with
    | Some u ->
        [ "# Activation source was env/flag/repo-local, not machine relay.json;";
          "# pinned here so the unit can resolve it at boot."
        ; Printf.sprintf "Environment=C2C_RELAY_URL=%s" u ]
    | None ->
        [ "# Relay URL: resolved from relay.json at every start"
        ; "# (c2c relay enable re-points the connector without a unit rewrite)." ]
  in
  String.concat "\n"
    ([ "# c2c-relay-connect.service — machine-wide c2c relay connector (B296)."
     ; "# Installed by `c2c relay enable` / `c2c install self` on"
     ; "# relay-activated hosts only. Stop+disable: c2c relay disable."
     ; "# Remove: c2c uninstall self."
     ; "[Unit]"
     ; "Description=c2c relay connector (machine-wide; syncs every broker root)"
     ; "StartLimitIntervalSec=0"
     ; ""
     ; "[Service]"
     ; Printf.sprintf "ExecStart=%s start relay-connect --foreground" c2c_path
     ; "Restart=always"
     ; "RestartSec=5"
     ; "# Foreground supervisor: restarts the connector child on exit-3"
     ; "# crashes and c2c binary updates; systemd restarts it across"
     ; "# reboot/logout/OOM (Restart=always, never rate-limited)."
     ; "# Machine mode: the connector serves ALL broker roots"
     ; "# (~/.c2c/repos/*); inherited c2c env (broker root, relay"
     ; "# config/token/identity, instance dir, session ids) is cleared"
     ; "# (B311) — any of it would silently redirect the machine"
     ; "# connector."
     ; "UnsetEnvironment=C2C_MCP_BROKER_ROOT C2C_RELAY_CONFIG \
        C2C_INSTANCES_DIR C2C_RELAY_TOKEN C2C_RELAY_IDENTITY_PATH \
        C2C_RELAY_NODE_ID C2C_RELAY_SESSION_ID C2C_MCP_SESSION_ID" ]
    @ env_lines
    @ [ ""; "[Install]"; "WantedBy=default.target" ])

(* -------------------------------------------------------------------------- *)
(* systemctl runner (injectable; fixture-gated default)                        *)
(* -------------------------------------------------------------------------- *)

type systemctl_status =
  | Systemctl_ok
  | Systemctl_failed of string

type systemctl_runner = string list -> systemctl_status

let fixture_enabled () = Sys.getenv_opt "C2C_SYSTEMCTL_FIXTURE" = Some "1"

(* Repo fixture convention (C2C_*_FIXTURE): under C2C_SYSTEMCTL_FIXTURE=1 the
   default runner NEVER executes systemctl — tests must not touch host state —
   and optionally records argv to C2C_SYSTEMCTL_CAPTURE_FILE for assertions. *)
let run_systemctl_default args =
  if fixture_enabled () then begin
    (match Sys.getenv_opt "C2C_SYSTEMCTL_CAPTURE_FILE" with
     | Some f ->
         (try
            let oc = open_out_gen [ Open_append; Open_creat ] 0o600 f in
            Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
                output_string oc ("systemctl " ^ String.concat " " args ^ "\n"))
          with _ -> ())
     | None -> ());
    Systemctl_ok
  end
  else
    let cmd =
      "systemctl " ^ String.concat " " (List.map Filename.quote args) ^ " 2>&1"
    in
    try
      let ic = Unix.open_process_in cmd in
      let out = Buffer.create 256 in
      (try
         while true do
           Buffer.add_string out (input_line ic);
           Buffer.add_char out '\n'
         done
       with End_of_file -> ());
      let status = Unix.close_process_in ic in
      let code = match status with Unix.WEXITED c -> c | _ -> 1 in
      if code = 0 then Systemctl_ok
      else
        Systemctl_failed
          (Printf.sprintf "systemctl %s exited %d: %s"
             (String.concat " " args) code
             (String.sub (Buffer.contents out) 0
                (min 200 (Buffer.length out))))
    with _ -> Systemctl_failed "could not run systemctl"

(* Is a systemd --user session usable here? systemctl present AND the user
   manager answers. Hosts without it skip the unit with an informational
   message — never an install failure. *)
let systemd_user_available ?(run = run_systemctl_default) () =
  match run [ "--version" ] with
  | Systemctl_failed _ -> false
  | Systemctl_ok ->
      (match run [ "--user"; "show-environment" ] with
       | Systemctl_ok -> true
       | Systemctl_failed _ -> false)

(* -------------------------------------------------------------------------- *)
(* B302: output-carrying query seam (unit ownership detection)                 *)
(* -------------------------------------------------------------------------- *)

(* A query returns trimmed stdout on exit 0, None otherwise. Under
   C2C_SYSTEMCTL_FIXTURE=1 the default query NEVER executes systemctl: the
   answers come from C2C_SYSTEMCTL_STATE_FILE (JSON:
   {"is-active": "active", "is-enabled": "enabled", "main-pid": "12345"}),
   and a missing file or key means "no such unit" (None → no-unit → legacy
   direct path). Outside the fixture it runs the real `systemctl --user`.
   Queries are read-only and deliberately NOT recorded in
   C2C_SYSTEMCTL_CAPTURE_FILE — that file stays "would-be mutating
   invocations" only. *)
type systemctl_query = string list -> string option

let state_key_of_query_args (args : string list) : string option =
  if List.mem "is-active" args then Some "is-active"
  else if List.mem "is-enabled" args then Some "is-enabled"
  else if List.mem "MainPID" args then Some "main-pid"
  else None

let query_systemctl_default : systemctl_query =
 fun args ->
  if fixture_enabled () then begin
    match state_key_of_query_args args with
    | None -> None
    | Some key -> (
        match Sys.getenv_opt "C2C_SYSTEMCTL_STATE_FILE" with
        | None -> None
        | Some f -> (
            match (try Some (Yojson.Safe.from_file f) with _ -> None) with
            | Some (`Assoc fields) -> (
                match List.assoc_opt key fields with
                | Some (`String s) when String.trim s <> "" ->
                    Some (String.trim s)
                | _ -> None)
            | _ -> None))
  end
  else
    let cmd =
      "systemctl " ^ String.concat " " (List.map Filename.quote args)
      ^ " 2>/dev/null"
    in
    try
      let ic = Unix.open_process_in cmd in
      let buf = Buffer.create 64 in
      (try
         while true do
           Buffer.add_string buf (input_line ic);
           Buffer.add_char buf '\n'
         done
       with End_of_file -> ());
      let status = Unix.close_process_in ic in
      match status with
      | Unix.WEXITED 0 -> Some (String.trim (Buffer.contents buf))
      | _ -> None
    with _ -> None

(* True while the unit is running or systemd is auto-restarting it. *)
let unit_is_active ?(query = query_systemctl_default) () : bool =
  match query [ "--user"; "is-active"; unit_name ] with
  | Some ("active" | "activating" | "reloading") -> true
  | _ -> false

(* MainPID of the unit; None or 0 when there is no live main process (e.g.
   the auto-restart window between two Restart=always attempts). Accepts both
   `--value` output ("12345") and the `MainPID=12345` form older systemctl
   prints without --value — a parse failure here would misread a healthy unit
   as unsupervised (B302). *)
let unit_main_pid ?(query = query_systemctl_default) () : int option =
  match query [ "--user"; "show"; "-p"; "MainPID"; "--value"; unit_name ] with
  | Some out ->
      let s = String.trim out in
      match int_of_string_opt s with
      | Some pid -> Some pid
      | None ->
          (match String.rindex_opt s '=' with
           | Some i -> int_of_string_opt (String.trim (String.sub s (i + 1) (String.length s - i - 1)))
           | None -> None)
  | None -> None

let unit_is_enabled ?(query = query_systemctl_default) () : bool =
  match query [ "--user"; "is-enabled"; unit_name ] with
  | Some s -> String.trim s = "enabled"
  | None -> false

(* B302 delegation verbs — the only sanctioned way to stop/restart a
   connector the unit owns; routed through the same injectable runner seam
   as install/enable, so the fixture records them without executing. *)
let unit_stop ?(run = run_systemctl_default) () =
  run [ "--user"; "stop"; unit_name ]

let unit_restart ?(run = run_systemctl_default) () =
  run [ "--user"; "restart"; unit_name ]

(* -------------------------------------------------------------------------- *)
(* install / enable / disable / remove                                        *)
(* -------------------------------------------------------------------------- *)

type install_status =
  | Unit_enabled of string  (* unit path *)
  | Unit_skipped of string  (* informational reason: no systemd --user session *)
  | Unit_error of string  (* unexpected failure; non-fatal at every call site *)
  | Unit_not_activated  (* B300: relay not active — nothing installed *)

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" || Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

(* The absolute c2c path for ExecStart. Prefers the canonical install
   location (~/.local/bin/c2c) when it exists: `c2c relay enable` run from a
   dev checkout must not pin a _build path into a boot unit. Falls back to
   this process's argv[0], made absolute. *)
let c2c_binary_for_unit () =
  let installed =
    (try Sys.getenv "HOME" with Not_found -> ".") // ".local" // "bin" // "c2c"
  in
  if Sys.file_exists installed then installed
  else begin
    let exe = Sys.executable_name in
    if Filename.is_relative exe then Sys.getcwd () // exe else exe
  end

(* B300 gate for `c2c install self`: the unit exists only on relay-activated
   hosts. Local-only installs never get an enabled connector unit. *)
let should_install_for_self () =
  match Relay_activation.resolve () with
  | Relay_activation.Relay_active _ -> true
  | Relay_inactive | Relay_disabled _ -> false

(* Write the unit, reload, and enable+start it. [pre_start] runs after the
   unit file is in place but before systemctl starts it — used by
   `c2c relay enable` to hand a running non-systemd supervisor over to
   systemd (otherwise the singleton lock makes the unit start fail). *)
let install_and_enable ?(run = run_systemctl_default) ?(dry_run = false)
  ?pre_start ~c2c_path ?relay_url_env () : install_status =
  if not (systemd_user_available ~run ()) then
    Unit_skipped
      "no systemd --user session on this host — connector boot supervision \
       not installed (`c2c start relay-connect` still supervises while it runs)"
  else begin
    let path = unit_path () in
    if dry_run then Unit_enabled path
    else begin
      mkdir_p (Filename.dirname path);
      match C2c_io.write_file_atomic ~perm:0o644 path (unit_text ~c2c_path ?relay_url_env ()) with
      | Error e -> Unit_error (Printf.sprintf "could not write %s: %s" path e)
      | Ok () ->
          (match run [ "--user"; "daemon-reload" ] with
           | Systemctl_failed err ->
               Unit_error (Printf.sprintf "systemctl --user daemon-reload failed: %s" err)
           | Systemctl_ok ->
               (match pre_start with Some f -> f () | None -> ());
               (match run [ "--user"; "enable"; "--now"; unit_name ] with
                | Systemctl_ok -> Unit_enabled path
                | Systemctl_failed err ->
                    Unit_error
                      (Printf.sprintf
                         "systemctl --user enable --now %s failed: %s\n\
                          \  (a connector may already be running: c2c stop \
                           relay-connect, then systemctl --user start %s)"
                         unit_name err unit_name)))
    end
  end

(* B300-gated entry point for every installer surface. *)
let install_and_enable_if_active ?run ?dry_run ?pre_start ~c2c_path
  ?relay_url_env () : install_status =
  if not (should_install_for_self ()) then Unit_not_activated
  else
    let relay_url_env =
      match relay_url_env with Some _ as v -> v | None -> relay_url_env_for_unit ()
    in
    install_and_enable ?run ?dry_run ?pre_start ~c2c_path ?relay_url_env ()

(* Stop + disable, keep the unit file: `c2c relay disable` parks boot
   supervision so re-enable is one `c2c relay enable` away. *)
let stop_and_disable ?(run = run_systemctl_default) ?(dry_run = false) () =
  if not dry_run then ignore (run [ "--user"; "disable"; "--now"; unit_name ])

(* Disable + remove: `c2c uninstall self`. Only churns systemctl when a unit
   file is actually present. *)
let disable_and_remove ?(run = run_systemctl_default) ?(dry_run = false) () =
  let path = unit_path () in
  let existed = Sys.file_exists path in
  if dry_run || not existed then ()
  else begin
    ignore (run [ "--user"; "disable"; "--now"; unit_name ]);
    (try Unix.unlink path with _ -> ());
    ignore (run [ "--user"; "daemon-reload" ])
  end

(* Uninstall-manifest artifact (owned file — c2c writes and owns it). *)
let self_artifact () = C2c_install_manifest.owned_file (unit_path ())
